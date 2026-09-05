local M = {}

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function command_ok(status)
  return status == true or status == 0
end

local function run(command)
  local loaded, nixio = pcall(require, "nixio")
  if not loaded or not nixio or type(nixio.pipe) ~= "function" or
      type(nixio.fork) ~= "function" or type(nixio.waitpid) ~= "function" or
      type(nixio.exec) ~= "function" or type(nixio.dup) ~= "function" then
    return nil, "nixio process APIs unavailable"
  end

  local read_pipe, write_pipe, pipe_err = nixio.pipe()
  if not read_pipe then return nil, pipe_err or "unable to create command pipe" end
  local pid, fork_err = nixio.fork()
  if not pid then
    read_pipe:close()
    write_pipe:close()
    return nil, fork_err or "unable to fork command"
  end

  if pid == 0 then
    read_pipe:close()
    nixio.stdout:close()
    local duplicated = nixio.dup(write_pipe)
    write_pipe:close()
    if not duplicated or duplicated:fileno() ~= 1 then os.exit(127) end
    nixio.exec("/bin/sh", "-c", command .. " 2>&1")
    os.exit(127)
  end

  write_pipe:close()
  local chunks = {}
  while true do
    local chunk = read_pipe:read(4096)
    if not chunk or chunk == "" then break end
    chunks[#chunks + 1] = chunk
  end
  read_pipe:close()

  local waited, why, status = nixio.waitpid(pid)
  if not waited then return nil, status or why or "unable to wait for command" end
  local output = table.concat(chunks)
  if why == "exited" then return tonumber(status) or 1, output end
  if why == "signaled" then return 128 + (tonumber(status) or 0), output end
  return nil, "unknown command wait status"
end

M._run = run

local function chmod(path, permissions)
  local status = os.execute("chmod " .. permissions:sub(2) .. " " .. shell_quote(path))
  return command_ok(status), "chmod failed"
end

local default_fs = {
  open = io.open,
  rename = os.rename,
  remove = os.remove,
  chmod = chmod
}

local function close_file(file)
  local ok, err = file:close()
  if not ok then return nil, err or "file close failed" end
  return true
end

local function write_protected(fs, path, data)
  local file, open_err = fs.open(path, "wb")
  if not file then return nil, open_err or "unable to create temporary file" end

  local mode_ok, mode_err = fs.chmod(path, "0600")
  if not mode_ok then
    file:close()
    fs.remove(path)
    return nil, mode_err or "unable to protect temporary file"
  end

  local wrote, write_err = file:write(data)
  if not wrote then
    file:close()
    fs.remove(path)
    return nil, write_err or "unable to write temporary file"
  end
  local flushed, flush_err = file:flush()
  if not flushed then
    file:close()
    fs.remove(path)
    return nil, flush_err or "unable to flush temporary file"
  end
  local closed, close_err = close_file(file)
  if not closed then
    fs.remove(path)
    return nil, close_err
  end
  return true
end

local function read_all(fs, path)
  local file, open_err = fs.open(path, "rb")
  if not file then return nil, open_err end
  local data, read_err = file:read("*a")
  local closed, close_err = close_file(file)
  if not data then return nil, read_err or "unable to read file" end
  if not closed then return nil, close_err end
  return data
end

local function current_pid()
  local loaded, nixio = pcall(require, "nixio")
  if loaded and nixio and type(nixio.getpid) == "function" then
    local pid = nixio.getpid()
    if tostring(pid):match("^[0-9]+$") then return tostring(pid) end
  end
  local pipe = io.popen("echo $$")
  if not pipe then return nil, "unable to determine process id" end
  local pid = pipe:read("*l")
  pipe:close()
  if not pid or not pid:match("^[0-9]+$") then return nil, "invalid process id" end
  return pid
end

function M.validate_credentials(token, chat_id)
  if type(token) ~= "string" or not token:match("^[0-9]+:[A-Za-z0-9_-]+$") then
    return nil, "invalid Telegram bot token"
  end
  if type(chat_id) ~= "string" or
      (not chat_id:match("^-?[0-9]+$") and not chat_id:match("^@[A-Za-z0-9_]+$")) then
    return nil, "invalid Telegram chat id"
  end
  return true
end

function M.route_allowed(route_output, allowed_device, core)
  if type(route_output) ~= "string" or type(allowed_device) ~= "string" or
      not allowed_device:match("^[A-Za-z0-9_.:-]+$") or type(core) ~= "table" or
      type(core.route_device) ~= "function" then
    return nil, "invalid route check"
  end
  if core.route_device(route_output) ~= allowed_device then
    return nil, "default route is not on the allowed device"
  end
  return true
end

local function valid_digest(digest)
  return type(digest) == "string" and #digest == 64 and digest:match("^[0-9a-f]+$") ~= nil
end

local function default_sha256(path)
  local status, output = run("sha256sum " .. shell_quote(path))
  if not command_ok(status) then return nil, "sha256sum failed" end
  return output:match("^([0-9a-fA-F]+)%s")
end

function M.fingerprint(message, sha256_fn)
  if type(message) ~= "table" or type(message.sender) ~= "string" or
      type(message.timestamp) ~= "string" or type(message.body) ~= "string" or
      message.index == nil then
    return nil, "invalid message fingerprint input"
  end
  local pid, pid_err = current_pid()
  if not pid then return nil, pid_err end
  local path = "/tmp/sms2telegram." .. pid .. ".fingerprint"
  local canonical = table.concat({
    tostring(message.index),
    tostring(#message.sender), message.sender,
    tostring(#message.timestamp), message.timestamp,
    tostring(#message.body), message.body
  }, "\0")
  local wrote, write_err = write_protected(default_fs, path, canonical)
  if not wrote then return nil, write_err end
  local hasher = sha256_fn or default_sha256
  local called, digest, hash_err = pcall(hasher, path)
  default_fs.remove(path)
  if not called then return nil, "sha256sum failed" end
  if not digest then return nil, hash_err or "sha256sum failed" end
  digest = tostring(digest):lower()
  if not valid_digest(digest) then return nil, "invalid sha256 digest" end
  return digest
end

local Ledger = {}
Ledger.__index = Ledger

local function valid_index(index)
  return tostring(index):match("^[1-9][0-9]*$") ~= nil
end

local function parse_ledger(data)
  local records = {}
  if data == "" then return records end
  if data:sub(-1) ~= "\n" then return nil, "corrupt confirmation ledger" end
  for line in data:gmatch("([^\n]*)\n") do
    local index, digest = line:match("^([^\t]*)\t([^\t]*)$")
    if not index or not valid_index(index) or not valid_digest(digest) then
      return nil, "corrupt confirmation ledger"
    end
    if records[index] then return nil, "corrupt confirmation ledger" end
    records[index] = digest
  end
  return records
end

function Ledger.new(path, fs)
  if type(path) ~= "string" or path == "" then return nil, "invalid ledger path" end
  fs = fs or default_fs
  if type(fs.open) ~= "function" or type(fs.rename) ~= "function" or
      type(fs.remove) ~= "function" or type(fs.chmod) ~= "function" then
    return nil, "invalid ledger filesystem"
  end
  local data, read_err = read_all(fs, path)
  if not data then
    if read_err and not tostring(read_err):match("[Nn]o such file") then return nil, read_err end
    data = ""
  end
  local records, parse_err = parse_ledger(data)
  if not records then return nil, parse_err end
  return setmetatable({ path = path, fs = fs, records = records }, Ledger)
end

function Ledger:contains(index, digest)
  return self.records[tostring(index)] == digest
end

function Ledger:add(index, digest)
  index = tostring(index)
  if not valid_index(index) or not valid_digest(digest) then return nil, "invalid confirmation record" end
  self.records[index] = digest
  return true
end

function Ledger:remove(index, digest)
  index = tostring(index)
  if self.records[index] ~= digest then return nil, "confirmation record does not match" end
  self.records[index] = nil
  return true
end

function Ledger:save_atomic()
  local keys = {}
  for index in pairs(self.records) do keys[#keys + 1] = index end
  table.sort(keys, function(left, right) return tonumber(left) < tonumber(right) end)
  local lines = {}
  for _, index in ipairs(keys) do lines[#lines + 1] = index .. "\t" .. self.records[index] .. "\n" end
  local temporary = self.path .. ".tmp"
  local wrote, write_err = write_protected(self.fs, temporary, table.concat(lines))
  if not wrote then return nil, write_err end
  local renamed, rename_err = self.fs.rename(temporary, self.path)
  if not renamed then
    self.fs.remove(temporary)
    return nil, rename_err or "unable to save confirmation ledger"
  end
  return true
end

M.Ledger = Ledger

local Sender = {}
Sender.__index = Sender

local function temporary_path(pid, kind)
  if kind ~= "message" and kind ~= "response" then return nil end
  local path = "/tmp/sms2telegram." .. pid .. "." .. kind
  if not path:match("^/tmp/sms2telegram%.[0-9]+%." .. kind .. "$") then return nil end
  return path
end

local function trim(value)
  if type(value) ~= "string" then return "" end
  return value:match("^%s*(.-)%s*$")
end

function Sender.new(adapters, options)
  adapters, options = adapters or {}, options or {}
  local fs = adapters.fs or default_fs
  local pid = tostring(options.pid or (type(adapters.pid) == "function" and adapters.pid() or ""))
  local message_path = temporary_path(pid, "message")
  local response_path = temporary_path(pid, "response")
  return setmetatable({
    fs = fs,
    exec = adapters.exec or run,
    message_path = message_path,
    response_path = response_path
  }, Sender)
end

function Sender:send_parts(token, chat_id, parts)
  local credentials_ok, credentials_err = M.validate_credentials(token, chat_id)
  if not credentials_ok then return nil, credentials_err end
  if not self.message_path or not self.response_path then return nil, "invalid delivery temporary path" end
  if type(parts) ~= "table" then return nil, "invalid Telegram message parts" end

  for _, part in ipairs(parts) do
    if type(part) ~= "string" then return nil, "invalid Telegram message part" end
    local wrote, write_err = write_protected(self.fs, self.message_path, part)
    if not wrote then return nil, write_err end
    local response_ready, response_err = write_protected(self.fs, self.response_path, "")
    if not response_ready then
      self.fs.remove(self.message_path)
      return nil, response_err
    end

    local curl_command = "curl --silent --show-error --connect-timeout 10 --max-time 30" ..
      " --output " .. shell_quote(self.response_path) ..
      " --write-out '%{http_code}'" ..
      " --data-urlencode " .. shell_quote("chat_id=" .. chat_id) ..
      " --data-urlencode " .. shell_quote("text@" .. self.message_path) ..
      " " .. shell_quote("https://api.telegram.org/bot" .. token .. "/sendMessage")
    local curl_status, curl_output = self.exec(curl_command)
    if not command_ok(curl_status) or trim(curl_output) ~= "200" then
      self.fs.remove(self.message_path)
      self.fs.remove(self.response_path)
      return nil, "Telegram HTTP request failed"
    end

    local json_command = "jsonfilter -i " .. shell_quote(self.response_path) .. " -e '@.ok'"
    local json_status, json_output = self.exec(json_command)
    self.fs.remove(self.message_path)
    self.fs.remove(self.response_path)
    if not command_ok(json_status) or trim(json_output) ~= "true" then
      return nil, "Telegram response was not ok"
    end
  end
  return true
end

M.Sender = Sender

return M

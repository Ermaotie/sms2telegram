local M = {}

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function command_ok(result)
  return result == true or result == 0
end

local function default_chmod(path, permissions)
  return command_ok(os.execute("chmod " .. permissions:sub(2) .. " " .. shell_quote(path)))
end

local default_fs = {
  open = io.open,
  rename = os.rename,
  remove = os.remove,
  chmod = default_chmod
}

local function missing(err)
  return err == nil or tostring(err):match("[Nn]o such file") ~= nil
end

local function valid_path(path)
  return type(path) == "string" and path ~= "" and not path:find("\n", 1, true)
end

local function write_atomic(self, path, data)
  local temporary = path .. ".tmp"
  local file, open_err = self.fs.open(temporary, "wb")
  if not file then return nil, open_err or "unable to create temporary store" end
  if not self.fs.chmod(temporary, "0600") then
    file:close(); self.fs.remove(temporary)
    return nil, "unable to protect temporary store"
  end
  local wrote, write_err = file:write(data)
  local flushed, flush_err = wrote and file:flush()
  local closed, close_err = file:close()
  if not wrote or not flushed or not closed then
    self.fs.remove(temporary)
    return nil, write_err or flush_err or close_err or "unable to write store"
  end
  local renamed, rename_err = self.fs.rename(temporary, path)
  if not renamed then
    self.fs.remove(temporary)
    return nil, rename_err or "unable to replace store"
  end
  return true
end

local Store = {}
Store.__index = Store

function Store.new(options)
  options = options or {}
  if not valid_path(options.path) or not valid_path(options.cycle_path) or
      type(options.encode) ~= "function" or type(options.decode) ~= "function" then
    return nil, "invalid message store options"
  end
  local self = setmetatable({
    path = options.path,
    cycle_path = options.cycle_path,
    encode = options.encode,
    decode = options.decode,
    now = options.now or os.time,
    fs = options.fs or default_fs,
    cycle_days = nil
  }, Store)
  local file = self.fs.open(self.cycle_path, "rb")
  if file then
    local value = file:read("*a")
    file:close()
    local days = value and tonumber(value:match("^([0-9]+)\n$")) or nil
    if days and days >= 1 and days <= 3650 then self.cycle_days = days end
  end
  return self
end

function Store:cycle()
  return self.cycle_days
end

function Store:records(keyword)
  keyword = type(keyword) == "string" and keyword:match("^%s*(.-)%s*$") or ""
  local needle = keyword:lower()
  local file, open_err = self.fs.open(self.path, "rb")
  if not file then
    if missing(open_err) then return {} end
    return nil, open_err
  end
  local records = {}
  for line in file:lines() do
    local ok, record = pcall(self.decode, line)
    if ok and type(record) == "table" and type(record.number) == "string" and
        type(record.text) == "string" and type(record.timestamp) == "string" and
        type(record.stored_at) == "number" then
      local haystack = (record.number .. "\n" .. record.timestamp .. "\n" .. record.text):lower()
      if needle == "" or haystack:find(needle, 1, true) then
        records[#records + 1] = record
      end
    end
  end
  local closed, close_err = file:close()
  if not closed then return nil, close_err end
  return records
end

function Store:count()
  local records, err = self:records()
  return records and #records or nil, err
end

function Store:prune()
  if not self.cycle_days then return true, 0 end
  local records, read_err = self:records()
  if not records then return nil, read_err end
  local cutoff, kept = self.now() - self.cycle_days * 86400, {}
  for _, record in ipairs(records) do
    if record.stored_at >= cutoff then kept[#kept + 1] = record end
  end
  local removed = #records - #kept
  if removed == 0 then return true, 0 end
  local lines = {}
  for _, record in ipairs(kept) do lines[#lines + 1] = self.encode(record) end
  local data = #lines > 0 and table.concat(lines, "\n") .. "\n" or ""
  local saved, save_err = write_atomic(self, self.path, data)
  if not saved then return nil, save_err end
  return true, removed
end

function Store:append(message)
  if type(message) ~= "table" or type(message.number) ~= "string" or
      type(message.text) ~= "string" or type(message.timestamp) ~= "string" then
    return nil, "invalid SMS message"
  end
  local record = {
    number = message.number,
    text = message.text,
    timestamp = message.timestamp,
    message_id = message.message_id,
    stored_at = self.now()
  }
  local ok, encoded = pcall(self.encode, record)
  if not ok or type(encoded) ~= "string" or encoded:find("\n", 1, true) then
    return nil, "unable to encode SMS message"
  end
  local file, open_err = self.fs.open(self.path, "ab")
  if not file then return nil, open_err or "unable to open message store" end
  if not self.fs.chmod(self.path, "0600") then
    file:close()
    return nil, "unable to protect message store"
  end
  local wrote, write_err = file:write(encoded .. "\n")
  local flushed, flush_err = wrote and file:flush()
  local closed, close_err = file:close()
  if not wrote or not flushed or not closed then
    return nil, write_err or flush_err or close_err or "unable to persist SMS message"
  end
  local pruned, prune_err = self:prune()
  if not pruned then return nil, prune_err end
  return true
end

function Store:clear()
  local count, count_err = self:count()
  if count == nil then return nil, count_err end
  local removed, remove_err = self.fs.remove(self.path)
  if not removed and not missing(remove_err) then return nil, remove_err end
  return count
end

function Store:set_cycle(value)
  local days
  if value ~= "off" then
    days = tonumber(value)
    if not days or days % 1 ~= 0 or days < 1 or days > 3650 then
      return nil, "保留天数必须是 1 到 3650，或使用 off"
    end
  end
  local saved, save_err = write_atomic(self, self.cycle_path,
    days and string.format("%d\n", days) or "off\n")
  if not saved then return nil, save_err end
  self.cycle_days = days
  local pruned, prune_err = self:prune()
  if not pruned then return nil, prune_err end
  return true
end

M.new = Store.new
return M

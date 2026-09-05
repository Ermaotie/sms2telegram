local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local nixio = require "nixio"
local core = dofile(root .. "/usr/lib/sms2telegram/core.lua")
local delivery = dofile(root .. "/usr/lib/sms2telegram/delivery.lua")
local run = assert(delivery._run, "default runner test hook required")

local function quote(value)
  return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function shell_status(command)
  local a, b, c = os.execute(command)
  if type(a) == "number" then return a end
  if a then return 0 end
  return c or 1
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local data = file:read("*a")
  file:close()
  return data
end

local function mode(path)
  local metadata = nixio.fs.stat(path)
  return metadata and tostring(metadata.modedec)
end

local function process_id()
  local pipe = assert(io.popen("echo $$"))
  local value = assert(pipe:read("*l"))
  pipe:close()
  assert(value:match("^[0-9]+$"))
  return value
end

local test_dir = "/tmp/sms2telegram-test-" .. process_id()
assert(shell_status("mkdir -p " .. quote(test_dir)) == 0)
local ledger_path = test_dir .. "/ledger"
os.remove(ledger_path)
os.remove(ledger_path .. ".tmp")

local exit_status, exit_output = run("printf 200; exit 28")
t.eq("default runner preserves exit 28", tostring(exit_status), "28")
t.eq("default runner preserves failed output", exit_output, "200")
local success_status, success_output = run("printf 200; exit 0")
t.eq("default runner preserves exit 0", tostring(success_status), "0")
t.eq("default runner preserves successful output", success_output, "200")

-- These assertions fail if token/chat validation is relaxed or if route
-- selection accepts a SIM interface instead of the exact permitted device.
t.eq("accept bot token", delivery.validate_credentials("123456:Abc_def-XYZ", "-1001234567890"), true)
t.eq("accept channel username", delivery.validate_credentials("123456:Abc_def-XYZ", "@alerts_1"), true)
t.eq("reject shell token", delivery.validate_credentials("123;reboot", "1"), nil)
t.eq("reject invalid chat", delivery.validate_credentials("123456:Abc_def-XYZ", "-100;reboot"), nil)
t.eq("allow exact eth0", delivery.route_allowed("1.1.1.1 dev eth0 src 192.168.1.2", "eth0", core), true)
t.eq("deny SIM eth2", delivery.route_allowed("1.1.1.1 dev eth2 src 10.0.0.2", "eth0", core), nil)

-- The expected canonical string is hand-written so this catches omitted
-- delimiters and field-boundary collisions in the fingerprint implementation.
local hashed_path, hashed_mode, canonical
local digest = assert(delivery.fingerprint({
  index = 7,
  sender = "+8613800000000",
  timestamp = "26/09/05,14:30:00+32",
  body = "hello"
}, function(path)
  hashed_path = path
  hashed_mode = mode(path)
  canonical = assert(read_file(path))
  return string.rep("a", 64)
end))
t.eq("fingerprint digest", digest, string.rep("a", 64))
t.eq("fingerprint canonical", canonical,
  "7\0" .. tostring(#"+8613800000000") .. "\0+8613800000000\0" ..
  tostring(#"26/09/05,14:30:00+32") .. "\0" .. "26/09/05,14:30:00+32\0" ..
  tostring(#"hello") .. "\0hello")
t.eq("fingerprint temporary mode", hashed_mode, "600")
t.eq("fingerprint temporary cleanup", read_file(hashed_path), nil)

local fs = {
  open = io.open,
  rename = os.rename,
  remove = os.remove,
  chmod = function(path, permissions)
    return shell_status("chmod " .. tostring(permissions) .. " " .. quote(path)) == 0
  end
}

-- These are real filesystem metadata checks, including the temporary ledger
-- before its atomic rename.
local corrupt = assert(io.open(ledger_path, "wb"))
corrupt:write("7\tshort-digest\n")
corrupt:close()
local corrupt_ledger, corrupt_err = delivery.Ledger.new(ledger_path, fs)
t.eq("reject corrupt ledger", corrupt_ledger, nil)
t.truthy("corrupt ledger error", corrupt_err)
os.remove(ledger_path)
local ledger = assert(delivery.Ledger.new(ledger_path, fs))
assert(ledger:add(7, string.rep("a", 64)))
local saved_temporary_mode
local original_rename = fs.rename
fs.rename = function(source, destination)
  saved_temporary_mode = mode(source)
  return original_rename(source, destination)
end
assert(ledger:save_atomic())
fs.rename = original_rename
t.eq("ledger mode", mode(ledger_path), "600")
t.eq("ledger temporary mode", saved_temporary_mode, "600")
local reloaded = assert(delivery.Ledger.new(ledger_path, fs))
t.eq("ledger reload matching fingerprint", reloaded:contains(7, string.rep("a", 64)), true)
t.eq("ledger does not match changed fingerprint", reloaded:contains(7, string.rep("d", 64)), false)
assert(reloaded:remove(7, string.rep("a", 64)))
assert(reloaded:save_atomic())
t.eq("ledger saved empty after removal", read_file(ledger_path), "")

local pid = process_id()
local message_path = "/tmp/sms2telegram." .. pid .. ".message"
local response_path = "/tmp/sms2telegram." .. pid .. ".response"
os.remove(message_path)
os.remove(response_path)

local function sender_case(name, curl_exit, http_code, json_exit, json_value)
  local commands, request_modes = {}, {}
  local sender_fs = {
    open = io.open,
    rename = os.rename,
    remove = os.remove,
    chmod = function(path, permissions)
      return shell_status("chmod " .. tostring(permissions) .. " " .. quote(path)) == 0
    end
  }
  local sender = delivery.Sender.new({
    fs = sender_fs,
    exec = function(command)
      commands[#commands + 1] = command
      if command:match("^curl ") then
        request_modes[message_path] = mode(message_path)
        request_modes[response_path] = mode(response_path)
        local response = assert(io.open(response_path, "wb"))
        response:write('{"ok":true}')
        response:close()
        return curl_exit, http_code
      end
      if command:match("^jsonfilter ") then return json_exit, json_value end
      error("unexpected command")
    end
  }, { pid = pid })
  local ok, err = sender:send_parts("123456:Abc_def-XYZ", "-1001234567890", { "secret SMS body; $(not-a-command)" })
  local want = curl_exit == 0 and http_code == "200" and json_exit == 0 and json_value == "true\n" and true or nil
  t.eq(name .. " result", tostring(ok), tostring(want))
  if ok == nil then t.truthy(name .. " error", err) end
  t.eq(name .. " message cleanup", read_file(message_path), nil)
  t.eq(name .. " response cleanup", read_file(response_path), nil)
  t.eq(name .. " message mode", request_modes[message_path], "600")
  t.eq(name .. " response mode", request_modes[response_path], "600")
  return commands
end

local success_commands = sender_case("successful send", 0, "200", 0, "true\n")
t.truthy("curl names request file", success_commands[1] and success_commands[1]:find(message_path, 1, true))
t.eq("curl never interpolates SMS body", success_commands[1] and success_commands[1]:find("secret SMS body", 1, true), nil)
sender_case("HTTP 401", 0, "401", 0, "true\n")
sender_case("curl timeout", 28, "", 0, "true\n")
sender_case("malformed JSON", 0, "200", 1, "parse error\n")
sender_case("Telegram ok false", 0, "200", 0, "false\n")

os.remove(ledger_path)
os.remove(ledger_path .. ".tmp")
shell_status("rmdir " .. quote(test_dir))
t.finish()

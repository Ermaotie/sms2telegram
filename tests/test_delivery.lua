local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local core = dofile(root .. "/usr/lib/sms2telegram/core.lua")
local delivery = dofile(root .. "/usr/lib/sms2telegram/delivery.lua")

t.eq("accept bot token", delivery.validate_credentials("123456:Abc_def-XYZ", "-1001234567890"), true)
t.eq("reject shell token", delivery.validate_credentials("123;reboot", "1"), nil)
t.eq("allow exact eth0", delivery.route_allowed("1.1.1.1 dev eth0", "eth0", core), true)
t.eq("deny SIM eth2", delivery.route_allowed("1.1.1.1 dev eth2", "eth0", core), nil)
t.eq("never permit configured SIM", delivery.route_allowed("1.1.1.1 dev eth2", "eth2", core), nil)

local removed, commands = {}, {}
local files = {}
local fs = {
  open = function(path, mode)
    if mode == "wb" then
      local value = ""
      return {
        write = function(_, data) value = value .. data; files[path] = value; return true end,
        flush = function() return true end,
        close = function() return true end
      }
    end
  end,
  chmod = function() return true end,
  remove = function(path) removed[path] = true; files[path] = nil; return true end
}
local sender = delivery.Sender.new({
  fs = fs,
  exec = function(command)
    commands[#commands + 1] = command
    if command:match("^curl ") then return 0, "200" end
    return 0, "true\n"
  end
}, { pid = 123 })
t.eq("Telegram send", sender:send_parts("123456:Abc_def-XYZ", "-1001234567890", { "secret body" }), true)
t.eq("SMS body not interpolated into shell", commands[1]:find("secret body", 1, true), nil)
t.truthy("temporary message removed", removed["/tmp/sms2telegram.123.message"])
t.truthy("temporary response removed", removed["/tmp/sms2telegram.123.response"])
t.finish()

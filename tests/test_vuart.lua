local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local vuart = dofile(root .. "/usr/lib/sms2telegram/vuart.lua")

local decode = function(line)
  if line:find('"type":"ready"', 1, true) then
    return { type = "ready", project = "sms_gateway", version = "1.0.0" }
  end
  if line:find('"type":"sms"', 1, true) then
    if not line:find('"text"', 1, true) then return { type = "sms", number = "10086" } end
    return { type = "sms", number = "+86100", text = "测试\n123",
      timestamp = "2026-09-30 21:30:00", message_id = "x" }
  end
  if line == "{bad json" then error("invalid JSON") end
  return { type = "at" }
end
local ready = assert(vuart.decode_line('{"type":"ready","project":"sms_gateway","version":"1.0.0"}', decode))
t.eq("ready event", ready.type, "ready")
local sms = assert(vuart.decode_line('{"type":"sms","number":"+86100","text":"测试\\n123","timestamp":"2026-09-30 21:30:00","message_id":"x"}', decode))
t.eq("number unchanged", sms.number, "+86100")
t.eq("escaped newline decoded", sms.text, "测试\n123")
t.eq("empty line ignored", vuart.decode_line("  ", decode), false)
t.eq("bad JSON rejected", vuart.decode_line("{bad json", decode), nil)
t.eq("unknown type rejected", vuart.decode_line('{"type":"at"}', decode), nil)
t.eq("missing SMS field rejected", vuart.decode_line('{"type":"sms","number":"10086"}', decode), nil)
t.finish()

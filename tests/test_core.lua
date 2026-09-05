local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local core = dofile(root .. "/usr/lib/sms2telegram/core.lua")

t.eq("UCS2 Chinese", assert(core.ucs2_to_utf8("77ED4FE1")), "短信")
t.eq("UCS2 phone", assert(core.ucs2_to_utf8("002B0038003600310033")), "+8613")
local value, err = core.ucs2_to_utf8("D800")
t.eq("reject surrogate", value, nil)
t.truthy("surrogate error", err and err:match("surrogate"))
t.eq("UTF-8 length", core.utf8_length("A短信🙂"), 4)
local head, tail = core.utf8_prefix("A短信🙂B", 3)
t.eq("UTF-8 prefix", head, "A短信")
t.eq("UTF-8 remainder", tail, "🙂B")

local function rejects_invalid_utf8(name, text)
  local ok = pcall(function() core.utf8_length(text) end)
  t.eq(name, tostring(ok), "false")
end
rejects_invalid_utf8("invalid continuation", string.char(0xC2, 0x41))
rejects_invalid_utf8("truncated sequence", string.char(0xE2, 0x82))
rejects_invalid_utf8("overlong encoding", string.char(0xE0, 0x80, 0x80))
rejects_invalid_utf8("encoded surrogate", string.char(0xED, 0xA0, 0x80))
rejects_invalid_utf8("codepoint above Unicode", string.char(0xF4, 0x90, 0x80, 0x80))

local response = table.concat({
  '+CMGL: 7,"REC READ","002B0038003600310033003800300030003000300030003000300030",,"26/09/05,14:30:00+32"',
  '77ED4FE1000A7B2C4E8C884C',
  'OK',
  ''
}, '\r\n')
local messages = assert(core.parse_cmgl(response))
t.eq("one CMGL record", #messages, 1)
t.eq("CMGL index", messages[1].index, 7)
t.eq("decoded sender", messages[1].sender, "+8613800000000")
t.eq("decoded multiline body", messages[1].body, "短信\n第二行")

local parts = core.format_parts(messages[1], 4096)
t.eq("short SMS one part", #parts, 1)
t.eq("body precedes metadata", parts[1], "短信\n第二行\n\n📩 短信信息\n来自：+8613800000000\n时间：26/09/05,14:30:00+32")
t.eq("route eth0", core.route_device("1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.2\n"), "eth0")
t.eq("route eth2", core.route_device("1.1.1.1 dev eth2 src 10.0.0.2\n"), "eth2")
t.eq("missing route", core.route_device("RTNETLINK answers: Network unreachable\n"), nil)
t.eq("backoff starts", core.next_backoff(nil, 15, 300), 15)
t.eq("backoff doubles", core.next_backoff(60, 15, 300), 120)
t.eq("backoff caps", core.next_backoff(240, 15, 300), 300)

local long_message = {
  sender = "+8613800000000",
  timestamp = "26/09/05,14:30:00+32",
  body = string.rep("A", 4200)
}
local long_parts = core.format_parts(long_message, 4096)
local long_metadata = "📩 短信信息\n来自：+8613800000000\n时间：26/09/05,14:30:00+32"
t.truthy("long SMS splits", #long_parts > 1)
for i, part in ipairs(long_parts) do
  t.truthy("long part fits " .. i, core.utf8_length(part) <= 4096)
  t.eq("long part starts with body " .. i, part:sub(1, 1), "A")
  t.truthy("long part repeats metadata " .. i, part:find(long_metadata, 1, true))
end
t.finish()

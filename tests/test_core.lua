local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local core = dofile(root .. "/usr/lib/sms2telegram/core.lua")

t.eq("UTF-8 length", core.utf8_length("测试abc"), 5)
local parts = assert(core.format_parts({
  sender = "+8613800000000", timestamp = "2026-09-30 21:30:00", body = "验证码 123456"
}, 4096))
t.eq("short SMS one Telegram part", #parts, 1)
t.truthy("body preserved", parts[1]:find("验证码 123456", 1, true))
t.truthy("sender preserved", parts[1]:find("+8613800000000", 1, true))
local long = assert(core.format_parts({ sender = "10086", timestamp = "2026-09-30 21:30:00",
  body = string.rep("中", 200) }, 80))
t.truthy("long SMS split for Telegram", #long > 1)
t.eq("route device", core.route_device("1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.2"), "eth0")
t.eq("backoff starts", core.next_backoff(nil, 15, 300), 15)
t.eq("backoff caps", core.next_backoff(240, 15, 300), 300)
t.eq("PDU decoder removed", core.decode_sms_pdu, nil)
t.eq("CMGL parser removed", core.parse_cmgl, nil)
t.finish()

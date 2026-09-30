local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local core = dofile(root .. "/usr/lib/sms2telegram/core.lua")
local delivery = dofile(root .. "/usr/lib/sms2telegram/delivery.lua")
local worker = dofile(root .. "/usr/lib/sms2telegram/worker.lua")

local sends, route = {}, "eth0"
local instance = worker.new({
  core = core, delivery = delivery,
  route = function() return "1.1.1.1 dev " .. route end,
  sender = { send_parts = function(_, _, _, parts)
    sends[#sends + 1] = parts[1]
    return true
  end }
}, {
  bot_token = "123456:Abc_def-XYZ", chat_id = "-1001234567890",
  allowed_wan_device = "eth0", telegram_limit = 4096
})
local sms = { type = "sms", number = "+8613800000000", text = "测试\n123",
  timestamp = "2026-09-30 21:30:00", message_id = "id-1" }
t.eq("enqueue SMS", instance:enqueue(sms), true)
t.eq("pending count", instance:pending_count(), 1)
local sent, category, _, delivered = instance:process_next()
t.eq("forward succeeds", sent, true)
t.eq("forward category", category, nil)
t.eq("delivered identity", delivered.message_id, "id-1")
t.eq("one Telegram request", #sends, 1)
t.eq("duplicate content ignored", instance:enqueue({ type = "sms", number = sms.number,
  text = sms.text, timestamp = sms.timestamp, message_id = "different-id" }), false)

local retry = { type = "sms", number = "10086", text = "retry",
  timestamp = "2026-09-30 21:31:00", message_id = "id-2" }
assert(instance:enqueue(retry))
route = "eth2"
local blocked, blocked_category = instance:process_next()
t.eq("blocked route fails", blocked, nil)
t.eq("blocked route category", blocked_category, "route")
t.eq("failed send remains queued", instance:pending_count(), 1)
route = "eth0"
t.eq("queued SMS retries", instance:process_next(), true)
t.eq("queue drains", instance:pending_count(), 0)
t.finish()

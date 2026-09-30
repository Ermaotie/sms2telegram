local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local core = dofile(root .. "/usr/lib/sms2telegram/core.lua")
local delivery = dofile(root .. "/usr/lib/sms2telegram/delivery.lua")
local status = dofile(root .. "/usr/lib/sms2telegram/status.lua")

local function process_id()
  local pipe = assert(io.popen("echo $$"))
  local value = assert(pipe:read("*l"))
  pipe:close()
  return value
end

local function mode(path)
  local pipe = assert(io.popen("stat -f '%Lp' '" .. path .. "' 2>/dev/null || stat -c '%a' '" .. path .. "'"))
  local value = pipe:read("*l")
  pipe:close()
  return value
end

t.eq("status command", status.parse_command("/status"), "status")
local command, argument = status.parse_command("/list 验证码")
t.eq("list command", command, "list")
t.eq("list keyword", argument, "验证码")
t.eq("plain list command", status.parse_command("/list"), "list")
t.eq("clear command", status.parse_command("/clear"), "clear")
command, argument = status.parse_command("/cycle 30")
t.eq("cycle command", command, "cycle")
t.eq("cycle days", argument, "30")
command, argument = status.parse_command("/cycle OFF")
t.eq("cycle off command", command, "cycle")
t.eq("cycle off normalized", argument, "off")
t.eq("unknown command ignored", status.parse_command("/status now"), nil)

local authorized = {
  update_id = 1, message = { chat = { id = -1001234567890 }, text = "/clear" }
}
t.eq("configured chat may issue commands",
  status.command_for(authorized, "-1001234567890"), "clear")
t.eq("different chat cannot issue commands",
  status.command_for(authorized, "987654321"), nil)

local report = status.format_report({
  version = "2.1.0", uptime_seconds = 3661,
  sms_connected = true, sms_ready = true,
  sms_device = "/dev/ttyACM2", sms_device_available = true,
  route_device = "eth0", allowed_device = "eth0",
  persisted_count = 12, retention_days = 30,
  last_scan = "正常", last_scan_at = "2026-10-01 00:00:00"
})
t.truthy("healthy report starts green", report:match("^🟢"))
t.truthy("status shows persisted count", report:find("已保存短信：12 条", 1, true))
t.truthy("status shows retention", report:find("保留策略：30 天", 1, true))
t.eq("status omits AT diagnostics", report:find("AT 诊断", 1, true), nil)
t.eq("status omits signal", report:find("信号：", 1, true), nil)
t.eq("status omits cellular registration", report:find("蜂窝注册", 1, true), nil)
t.truthy("list formats sender", status.format_list({ {
  timestamp = "2026-10-01 00:00:00", number = "10086", text = "余额提醒"
} }):find("来自：10086", 1, true))

local offset_path = "/tmp/sms2telegram-status-offset-" .. process_id()
os.remove(offset_path); os.remove(offset_path .. ".tmp")
local offset_store = assert(status.OffsetStore.new(offset_path))
t.eq("empty offset is nil", offset_store:get(), nil)
t.eq("offset saves atomically", offset_store:save(44), true)
t.eq("offset file is private", mode(offset_path), "600")
t.eq("offset survives restart", assert(status.OffsetStore.new(offset_path)):get(), 44)
os.remove(offset_path); os.remove(offset_path .. ".tmp")

local bot_pid = process_id()
local bot_offset_path = "/tmp/sms2telegram-status-bot-offset-" .. bot_pid
local response_path = "/tmp/sms2telegram." .. bot_pid .. ".updates"
os.remove(bot_offset_path); os.remove(bot_offset_path .. ".tmp"); os.remove(response_path)
local bot_store = assert(status.OffsetStore.new(bot_offset_path))
local sent, cycle_days, cleared, list_keyword = {}, nil, false, nil
local message_store = {
  prune = function() return true end,
  records = function(_, keyword)
    list_keyword = keyword
    return { { timestamp = "2026-10-01 00:00:00", number = "10086",
      text = string.rep("验", 80) } }
  end,
  clear = function() cleared = true; return 1 end,
  cycle = function() return cycle_days end,
  set_cycle = function(_, value)
    if value == "off" then cycle_days = nil else cycle_days = tonumber(value) end
    return true
  end
}
local bot = assert(status.Bot.new({
  delivery = delivery,
  core = core,
  route = function() return "1.1.1.1 dev eth0 src 192.168.1.2" end,
  exec = function()
    local response = assert(io.open(response_path, "wb"))
    response:write('{"ok":true,"result":[]}')
    response:close()
    return 0, "200"
  end,
  decode_json = function()
    return { ok = true, result = {
      { update_id = 10, message = { chat = { id = 1 }, text = "/clear" } },
      { update_id = 11, message = { chat = { id = -1001234567890 }, text = "/status" } },
      { update_id = 12, message = { chat = { id = -1001234567890 }, text = "/list 验" } },
      { update_id = 13, message = { chat = { id = -1001234567890 }, text = "/cycle 30" } },
      { update_id = 14, message = { chat = { id = -1001234567890 }, text = "/cycle off" } },
      { update_id = 15, message = { chat = { id = -1001234567890 }, text = "/clear" } }
    } }
  end,
  sender = { send_parts = function(_, _, chat_id, parts)
    sent[#sent + 1] = { chat_id = chat_id, parts = parts }
    return true
  end },
  offset_store = bot_store,
  store = message_store
}, { pid = bot_pid }))

local ok, err = bot:poll({
  bot_token = "123456:Abc_def-XYZ", chat_id = "-1001234567890",
  allowed_wan_device = "eth0", telegram_limit = 100
}, {
  version = "2.1.0", uptime_seconds = 10,
  sms_connected = true, sms_ready = true,
  sms_device = "/dev/ttyACM2", sms_device_available = true,
  route_device = "eth0", allowed_device = "eth0", persisted_count = 1
})
t.eq("command poll succeeds", ok, true, err)
t.eq("only authorized commands reply", #sent, 5)
t.eq("list keyword reaches store", list_keyword, "验")
t.truthy("long list reply is split", #sent[2].parts > 1)
t.truthy("cycle command confirms days", sent[3].parts[1]:find("30 天", 1, true))
t.truthy("cycle off confirms full retention", sent[4].parts[1]:find("保留全部", 1, true))
t.eq("clear reaches store", cleared, true)
t.eq("all updates advance offset", bot_store:get(), 16)
t.eq("temporary response is removed", io.open(response_path, "rb"), nil)

os.remove(bot_offset_path); os.remove(bot_offset_path .. ".tmp"); os.remove(response_path)
t.finish()

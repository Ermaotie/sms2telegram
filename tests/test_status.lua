local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local nixio = require "nixio"
local core = dofile(root .. "/usr/lib/sms2telegram/core.lua")
local delivery = dofile(root .. "/usr/lib/sms2telegram/delivery.lua")

local function process_id()
  local pipe = assert(io.popen("echo $$"))
  local value = assert(pipe:read("*l"))
  pipe:close()
  return value
end

local function mode(path)
  local metadata = nixio.fs.stat(path)
  return metadata and tostring(metadata.modedec)
end

local loaded, status = pcall(dofile, root .. "/usr/lib/sms2telegram/status.lua")
local recognized = loaded and status.is_status_command and status.is_status_command("/status")
t.eq("plain status command is recognized", recognized, true)
t.eq("status command with arguments is ignored", status.is_status_command("/status now"), false)

local authorized = status.should_reply and status.should_reply({
  update_id = 41,
  message = { chat = { id = -1001234567890 }, text = "/status" }
}, "-1001234567890")
t.eq("configured chat may request status", authorized, true)
t.eq("different chat cannot request status", status.should_reply and status.should_reply({
  update_id = 42,
  message = { chat = { id = 987654321 }, text = "/status" }
}, "-1001234567890"), false)
t.eq("non-message update cannot request status", status.should_reply and status.should_reply({
  update_id = 43,
  callback_query = {}
}, "-1001234567890"), false)
t.eq("update offset is scoped to bot identity", status.offset_path and status.offset_path(
  "/etc/sms2telegram/telegram_update_offset", "123456:Abc_def-XYZ"),
  "/etc/sms2telegram/telegram_update_offset.123456")
t.eq("invalid bot token cannot form offset path", status.offset_path and status.offset_path(
  "/etc/sms2telegram/telegram_update_offset", "123456;reboot"), nil)

local healthy_report = status.format_report and status.format_report({
  version = "1.2.0",
  uptime_seconds = 3661,
  modem_connected = true,
  device = "/dev/ttyACM0",
  device_available = true,
  route_device = "eth0",
  allowed_device = "eth0",
  signal_rssi = 22,
  registration_status = 5,
  sms_used = 0,
  sms_total = 10,
  retain_count = 3,
  last_scan = "正常",
  last_scan_at = "2026-09-06 23:10:00",
  bot_token = "must-not-leak",
  chat_id = "must-not-leak"
})
t.truthy("healthy report starts green", healthy_report and healthy_report:match("^🟢"))
t.truthy("healthy report includes version", healthy_report and healthy_report:find("版本：1.2.0", 1, true))
t.truthy("healthy report includes service uptime", healthy_report and healthy_report:find("运行时长：1小时 1分钟", 1, true))
t.truthy("healthy report includes modem state", healthy_report and healthy_report:find("短信模块：已连接", 1, true))
t.truthy("healthy report includes allowed route", healthy_report and healthy_report:find("网络出口：eth0（允许）", 1, true))
t.truthy("healthy report names configured allowed route", healthy_report and healthy_report:find("允许出口：eth0", 1, true))
t.truthy("healthy report includes signal", healthy_report and healthy_report:find("信号：很强（22/31，约 -69 dBm）", 1, true))
t.truthy("healthy report includes registration", healthy_report and healthy_report:find("蜂窝注册：已注册（漫游）", 1, true))
t.truthy("healthy report includes SMS storage", healthy_report and healthy_report:find("短信存储：0/10（保留上限 3）", 1, true))
t.truthy("healthy report includes last scan", healthy_report and healthy_report:find("最近扫描：正常（2026-09-06 23:10:00）", 1, true))
t.eq("healthy report excludes token", healthy_report and healthy_report:find("must-not-leak", 1, true), nil)

local unhealthy_report = status.format_report and status.format_report({
  version = "1.2.0",
  uptime_seconds = 5,
  modem_connected = false,
  device = "/dev/ttyACM0",
  device_available = false,
  route_device = "eth2",
  allowed_device = "eth0",
  last_scan = "串口异常",
  last_scan_at = "2026-09-06 23:11:00"
})
t.truthy("unhealthy report starts warning", unhealthy_report and unhealthy_report:match("^🟠"))
t.truthy("unhealthy report shows disconnected modem", unhealthy_report and unhealthy_report:find("短信模块：未连接", 1, true))
t.truthy("unhealthy report shows blocked SIM route", unhealthy_report and unhealthy_report:find("网络出口：eth2（已阻止）", 1, true))
t.truthy("unhealthy report shows unknown signal", unhealthy_report and unhealthy_report:find("信号：未知", 1, true))

local partial_report = status.format_report({
  modem_connected = true, device_available = true,
  route_device = "eth0", allowed_device = "eth0",
  signal_rssi = 22, registration_status = 5,
  last_scan = "已保留 1 条无法解析短信，其他短信正常处理", last_scan_ok = false,
  anomaly_report = "已汇报 1 条异常记录（已去重）"
})
t.truthy("partial decode shows warning", partial_report:match("^🟠"))
t.truthy("partial decode does not claim modem disconnected", partial_report:find("短信模块：已连接", 1, true))
t.truthy("partial decode explains retained record", partial_report:find("已保留 1 条无法解析短信", 1, true))
t.truthy("status reports anomaly notification state", partial_report:find("异常汇报：已汇报 1 条异常记录（已去重）", 1, true))

local offset_path = "/tmp/sms2telegram-status-offset-" .. process_id()
os.remove(offset_path)
os.remove(offset_path .. ".tmp")
local offset_store, offset_err
if status.OffsetStore then offset_store, offset_err = status.OffsetStore.new(offset_path) end
t.truthy("missing offset file starts empty", offset_store, offset_err)
t.eq("empty offset is nil", offset_store and offset_store:get(), nil)
t.eq("valid offset saves atomically", offset_store and offset_store:save(44), true)
t.eq("offset file is private", mode(offset_path), "600")
local reloaded_store = status.OffsetStore and status.OffsetStore.new(offset_path)
t.eq("saved offset survives restart", reloaded_store and reloaded_store:get(), 44)
local corrupt_file = assert(io.open(offset_path, "wb"))
corrupt_file:write("not-an-offset\n")
corrupt_file:close()
local corrupt_store, corrupt_err
if status.OffsetStore then corrupt_store, corrupt_err = status.OffsetStore.new(offset_path) end
t.eq("corrupt offset fails closed", corrupt_store, nil)
t.truthy("corrupt offset reports error", corrupt_err)
os.remove(offset_path)
os.remove(offset_path .. ".tmp")

local bot_pid = process_id()
local bot_offset_path = "/tmp/sms2telegram-status-bot-offset-" .. bot_pid
local response_path = "/tmp/sms2telegram." .. bot_pid .. ".updates"
os.remove(bot_offset_path)
os.remove(bot_offset_path .. ".tmp")
os.remove(response_path)
local bot_store = assert(status.OffsetStore.new(bot_offset_path))
local bot_events, sent_parts, curl_command = {}, {}
local bot = status.Bot and status.Bot.new({
  delivery = delivery,
  core = core,
  route = function()
    bot_events[#bot_events + 1] = "route"
    return "1.1.1.1 dev eth0 src 192.168.1.2"
  end,
  exec = function(command)
    bot_events[#bot_events + 1] = "curl"
    curl_command = command
    local response = assert(io.open(response_path, "wb"))
    response:write('{"ok":true,"result":[]}')
    response:close()
    return 0, "200"
  end,
  decode_json = function()
    return {
      ok = true,
      result = {
        { update_id = 41, message = { chat = { id = 987654321 }, text = "/status" } },
        { update_id = 42, message = { chat = { id = -1001234567890 }, text = "hello" } },
        { update_id = 43, message = { chat = { id = -1001234567890 }, text = "/status" } }
      }
    }
  end,
  sender = {
    send_parts = function(_, token, chat_id, parts)
      bot_events[#bot_events + 1] = "send"
      sent_parts[#sent_parts + 1] = { token = token, chat_id = chat_id, body = parts[1] }
      return true
    end
  },
  offset_store = bot_store
}, { pid = bot_pid })
local bot_ok, bot_err = bot and bot:poll({
  bot_token = "123456:Abc_def-XYZ",
  chat_id = "-1001234567890",
  allowed_wan_device = "eth0"
}, {
  version = "1.2.0", uptime_seconds = 10, modem_connected = true,
  device = "/dev/ttyACM0", device_available = true,
  route_device = "eth0", allowed_device = "eth0", last_scan = "正常"
})
t.eq("authorized status poll succeeds", bot_ok, true)
t.eq("status poll checks route before fetch and reply", table.concat(bot_events, ","), "route,curl,route,send")
t.eq("status poll replies exactly once", #sent_parts, 1)
t.eq("status reply targets configured chat", sent_parts[1] and sent_parts[1].chat_id, "-1001234567890")
t.truthy("status reply contains service state", sent_parts[1] and sent_parts[1].body:find("服务正常", 1, true))
t.truthy("getUpdates request is used", curl_command and curl_command:find("/getUpdates", 1, true))
t.truthy("getUpdates explicitly requests message updates", curl_command and
  curl_command:find('allowed_updates=["message"]', 1, true))
t.eq("processed updates advance persistent offset", bot_store:get(), 44)
t.eq("getUpdates response is removed", io.open(response_path, "rb"), nil)
os.remove(bot_offset_path)
os.remove(bot_offset_path .. ".tmp")
os.remove(response_path)

local failing_pid = process_id()
local failing_response_path = "/tmp/sms2telegram." .. failing_pid .. ".updates"
local failing_events = {}
local failing_bot = assert(status.Bot.new({
  delivery = delivery,
  core = core,
  route = function()
    failing_events[#failing_events + 1] = "route"
    return "1.1.1.1 dev eth0 src 192.168.1.2"
  end,
  exec = function()
    failing_events[#failing_events + 1] = "curl"
    local response = assert(io.open(failing_response_path, "wb"))
    response:write('{"ok":true,"result":[]}')
    response:close()
    return 0, "200"
  end,
  decode_json = function()
    return { ok = true, result = {
      { update_id = 70, message = { chat = { id = -1001234567890 }, text = "/status" } }
    } }
  end,
  sender = { send_parts = function()
    failing_events[#failing_events + 1] = "send"
    return true
  end },
  offset_store = {
    get = function() return nil end,
    save = function()
      failing_events[#failing_events + 1] = "save"
      return nil, "read-only filesystem"
    end
  }
}, { pid = failing_pid }))
local failing_ok, failing_err = failing_bot:poll({
  bot_token = "123456:Abc_def-XYZ", chat_id = "-1001234567890",
  allowed_wan_device = "eth0"
}, {
  version = "1.2.0", uptime_seconds = 10, modem_connected = true,
  device = "/dev/ttyACM0", device_available = true,
  route_device = "eth0", allowed_device = "eth0", last_scan = "正常"
})
t.eq("offset failure rejects status command", failing_ok, nil)
t.truthy("offset failure is reported", failing_err and failing_err:find("read-only", 1, true))
t.eq("offset is persisted before any reply", table.concat(failing_events, ","),
  "route,curl,route,save")
os.remove(failing_response_path)

t.finish()

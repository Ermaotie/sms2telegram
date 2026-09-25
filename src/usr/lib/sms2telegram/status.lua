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

function M.is_status_command(text)
  return text == "/status"
end

local function chat_id_string(value)
  if type(value) == "number" then return string.format("%.0f", value) end
  if type(value) == "string" then return value end
end

function M.should_reply(update, configured_chat_id)
  if type(update) ~= "table" or type(update.message) ~= "table" or
      type(update.message.chat) ~= "table" then
    return false
  end
  local incoming_chat_id = chat_id_string(update.message.chat.id)
  return incoming_chat_id ~= nil and incoming_chat_id == configured_chat_id and
    M.is_status_command(update.message.text)
end

function M.offset_path(base_path, token)
  if type(base_path) ~= "string" or base_path == "" or base_path:find("\n", 1, true) then
    return nil
  end
  local bot_id = type(token) == "string" and
    token:match("^([0-9]+):[A-Za-z0-9_-]+$") or nil
  if not bot_id then return nil end
  return base_path .. "." .. bot_id, bot_id
end

local function format_uptime(value)
  local seconds = math.max(0, math.floor(tonumber(value) or 0))
  local days = math.floor(seconds / 86400)
  local hours = math.floor(seconds % 86400 / 3600)
  local minutes = math.floor(seconds % 3600 / 60)
  local parts = {}
  if days > 0 then parts[#parts + 1] = days .. "天" end
  if hours > 0 then parts[#parts + 1] = hours .. "小时" end
  if minutes > 0 then parts[#parts + 1] = minutes .. "分钟" end
  if #parts == 0 then parts[1] = (seconds % 60) .. "秒" end
  return table.concat(parts, " ")
end

local function format_signal(rssi)
  rssi = tonumber(rssi)
  if not rssi or rssi < 0 or rssi > 31 or rssi % 1 ~= 0 then return "未知" end
  local quality
  if rssi <= 9 then
    quality = "较弱"
  elseif rssi <= 14 then
    quality = "一般"
  elseif rssi <= 19 then
    quality = "良好"
  else
    quality = "很强"
  end
  return string.format("%s（%d/31，约 %d dBm）", quality, rssi, -113 + 2 * rssi)
end

local registration_labels = {
  [0] = "未注册",
  [1] = "已注册（本地）",
  [2] = "正在搜索",
  [3] = "注册被拒绝",
  [4] = "未知",
  [5] = "已注册（漫游）"
}

local function format_registration(status)
  return registration_labels[tonumber(status)] or "未知"
end

local function format_storage(snapshot)
  local used, total = tonumber(snapshot.sms_used), tonumber(snapshot.sms_total)
  if not used or not total or used < 0 or total < 0 or used > total then return "未知" end
  local text = string.format("%d/%d", used, total)
  local retain_count = tonumber(snapshot.retain_count)
  if retain_count and retain_count >= 0 and retain_count % 1 == 0 then
    text = text .. string.format("（保留上限 %d）", retain_count)
  end
  return text
end

function M.format_report(snapshot)
  snapshot = type(snapshot) == "table" and snapshot or {}
  local route_allowed = snapshot.route_device ~= nil and
    snapshot.route_device == snapshot.allowed_device
  local healthy = snapshot.modem_connected == true and
    snapshot.device_available == true and route_allowed and
    snapshot.last_scan_ok ~= false and
    (snapshot.registration_status == nil or snapshot.registration_status == 1 or
      snapshot.registration_status == 5)
  local header = healthy and "🟢 sms2telegram 服务正常" or
    "🟠 sms2telegram 服务运行中，但存在异常"
  local modem = snapshot.modem_connected and "已连接" or "未连接"
  local device = tostring(snapshot.device or "未知") ..
    (snapshot.device_available and "（可用）" or "（不可用）")
  local route = tostring(snapshot.route_device or "未知") ..
    (route_allowed and "（允许）" or "（已阻止）")
  local last_scan = tostring(snapshot.last_scan or "等待首次扫描")
  if snapshot.last_scan_at and snapshot.last_scan_at ~= "" then
    last_scan = last_scan .. "（" .. tostring(snapshot.last_scan_at) .. "）"
  end
  return table.concat({
    header,
    "版本：" .. tostring(snapshot.version or "未知"),
    "运行时长：" .. format_uptime(snapshot.uptime_seconds),
    "短信模块：" .. modem,
    "串口：" .. device,
    "网络出口：" .. route,
    "允许出口：" .. tostring(snapshot.allowed_device or "未知"),
    "信号：" .. format_signal(snapshot.signal_rssi),
    "蜂窝注册：" .. format_registration(snapshot.registration_status),
    "短信存储：" .. format_storage(snapshot),
    "异常汇报：" .. tostring(snapshot.anomaly_report or "等待扫描"),
    "最近扫描：" .. last_scan
  }, "\n")
end

local OffsetStore = {}
OffsetStore.__index = OffsetStore

local function valid_offset(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0 and
    value <= 9007199254740991
end

function OffsetStore.new(path, fs)
  if type(path) ~= "string" or path == "" or path:find("\n", 1, true) then
    return nil, "invalid Telegram update offset path"
  end
  fs = fs or default_fs
  if type(fs.open) ~= "function" or type(fs.rename) ~= "function" or
      type(fs.remove) ~= "function" or type(fs.chmod) ~= "function" then
    return nil, "invalid Telegram update offset filesystem"
  end
  local file, open_err = fs.open(path, "rb")
  local offset
  if file then
    local data, read_err = file:read("*a")
    local closed, close_err = file:close()
    if not data then return nil, read_err or "unable to read Telegram update offset" end
    if not closed then return nil, close_err or "unable to close Telegram update offset" end
    local digits = data:match("^([0-9]+)\n$")
    offset = digits and tonumber(digits) or nil
    if not valid_offset(offset) then return nil, "corrupt Telegram update offset" end
  elseif open_err and not tostring(open_err):match("[Nn]o such file") then
    return nil, open_err
  end
  return setmetatable({ path = path, fs = fs, offset = offset }, OffsetStore)
end

function OffsetStore:get()
  return self.offset
end

function OffsetStore:save(offset)
  if not valid_offset(offset) then return nil, "invalid Telegram update offset" end
  local temporary = self.path .. ".tmp"
  local file, open_err = self.fs.open(temporary, "wb")
  if not file then return nil, open_err or "unable to create Telegram update offset" end
  if not self.fs.chmod(temporary, "0600") then
    file:close()
    self.fs.remove(temporary)
    return nil, "unable to protect Telegram update offset"
  end
  local wrote, write_err = file:write(string.format("%.0f\n", offset))
  if not wrote then
    file:close()
    self.fs.remove(temporary)
    return nil, write_err or "unable to write Telegram update offset"
  end
  local flushed, flush_err = file:flush()
  local closed, close_err = file:close()
  if not flushed or not closed then
    self.fs.remove(temporary)
    return nil, flush_err or close_err or "unable to save Telegram update offset"
  end
  local renamed, rename_err = self.fs.rename(temporary, self.path)
  if not renamed then
    self.fs.remove(temporary)
    return nil, rename_err or "unable to replace Telegram update offset"
  end
  self.offset = offset
  return true
end

M.OffsetStore = OffsetStore

local function trim(value)
  if type(value) ~= "string" then return "" end
  return value:match("^%s*(.-)%s*$")
end

local function read_all(fs, path)
  local file, open_err = fs.open(path, "rb")
  if not file then return nil, open_err or "unable to read Telegram updates" end
  local data, read_err = file:read("*a")
  local closed, close_err = file:close()
  if not data then return nil, read_err or "unable to read Telegram updates" end
  if not closed then return nil, close_err or "unable to close Telegram updates" end
  return data
end

local function prepare_response(fs, path)
  local file, open_err = fs.open(path, "wb")
  if not file then return nil, open_err or "unable to create Telegram updates response" end
  if not fs.chmod(path, "0600") then
    file:close()
    fs.remove(path)
    return nil, "unable to protect Telegram updates response"
  end
  local closed, close_err = file:close()
  if not closed then
    fs.remove(path)
    return nil, close_err or "unable to close Telegram updates response"
  end
  return true
end

local function default_json_decode(data)
  local loaded, json = pcall(require, "luci.jsonc")
  if not loaded or type(json) ~= "table" or type(json.parse) ~= "function" then
    return nil, "Telegram JSON decoder unavailable"
  end
  return json.parse(data)
end

local Bot = {}
Bot.__index = Bot

function Bot.new(deps, options)
  deps, options = deps or {}, options or {}
  local pid = tostring(options.pid or "")
  local response_path = pid:match("^[0-9]+$") and
    ("/tmp/sms2telegram." .. pid .. ".updates") or nil
  if type(deps.delivery) ~= "table" or type(deps.core) ~= "table" or
      type(deps.route) ~= "function" or type(deps.exec) ~= "function" or
      type(deps.sender) ~= "table" or type(deps.offset_store) ~= "table" then
    return nil, "invalid status bot dependencies"
  end
  return setmetatable({
    delivery = deps.delivery,
    core = deps.core,
    route = deps.route,
    exec = deps.exec,
    sender = deps.sender,
    offset_store = deps.offset_store,
    decode_json = deps.decode_json or default_json_decode,
    fs = deps.fs or default_fs,
    response_path = response_path
  }, Bot)
end

function Bot:poll(config, snapshot)
  if not self.response_path then return nil, "invalid Telegram updates temporary path" end
  if type(config) ~= "table" then return nil, "invalid status bot config" end
  local credentials_ok, credentials_err = self.delivery.validate_credentials(
    config.bot_token, config.chat_id)
  if not credentials_ok then return nil, credentials_err end
  local route_ok, route_err = self.delivery.route_allowed(
    self.route(), config.allowed_wan_device, self.core)
  if not route_ok then return nil, route_err end

  local response_ready, response_err = prepare_response(self.fs, self.response_path)
  if not response_ready then return nil, response_err end
  local command = "curl --silent --show-error --connect-timeout 5 --max-time 10" ..
    " --output " .. shell_quote(self.response_path) ..
    " --write-out '%{http_code}' --get" ..
    " --data-urlencode " .. shell_quote("timeout=0") ..
    " --data-urlencode " .. shell_quote("limit=100") ..
    " --data-urlencode " .. shell_quote('allowed_updates=["message"]')
  local offset = self.offset_store:get()
  if offset ~= nil then
    command = command .. " --data-urlencode " .. shell_quote(string.format("offset=%.0f", offset))
  end
  command = command .. " " ..
    shell_quote("https://api.telegram.org/bot" .. config.bot_token .. "/getUpdates")
  local curl_status, curl_output = self.exec(command)
  if not command_ok(curl_status) or trim(curl_output) ~= "200" then
    self.fs.remove(self.response_path)
    return nil, "Telegram getUpdates HTTP request failed"
  end
  local body, read_err = read_all(self.fs, self.response_path)
  self.fs.remove(self.response_path)
  if not body then return nil, read_err end
  local decoded_ok, decoded, decode_err = pcall(self.decode_json, body)
  if not decoded_ok then return nil, "invalid Telegram getUpdates response" end
  if type(decoded) ~= "table" or decoded.ok ~= true or type(decoded.result) ~= "table" then
    return nil, decode_err or "Telegram getUpdates response was not ok"
  end

  local next_offset = offset
  for _, update in ipairs(decoded.result) do
    local update_id = type(update) == "table" and update.update_id or nil
    if not valid_offset(update_id) then return nil, "invalid Telegram update id" end
    if next_offset == nil or update_id >= next_offset then
      local reply = M.should_reply(update, config.chat_id)
      if reply then
        local reply_route_ok, reply_route_err = self.delivery.route_allowed(
          self.route(), config.allowed_wan_device, self.core)
        if not reply_route_ok then return nil, reply_route_err end
      end
      next_offset = update_id + 1
      local saved, save_err = self.offset_store:save(next_offset)
      if not saved then return nil, save_err end
      if reply then
        local sent, send_err = self.sender:send_parts(config.bot_token, config.chat_id,
          { M.format_report(snapshot) })
        if not sent then return nil, send_err or "Telegram status reply failed" end
      end
    end
  end
  return true
end

M.Bot = Bot

return M

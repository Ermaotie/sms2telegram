local M = {}
local Client = {}
Client.__index = Client

local function terminal_line(frame)
  local normalized = frame:gsub("\r\n", "\n"):gsub("\r", "\n")
  local terminal
  for line in (normalized .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then terminal = line end
  end
  return normalized, terminal
end

local function allowed_prefixes(command)
  if command == "AT+CSQ" then return { "+CSQ:" } end
  if command == "AT+CEREG?" then return { "+CEREG:", "+CGREG:" } end
  return {}
end

function Client.new(transport, options)
  options = options or {}
  return setmetatable({
    transport = assert(transport, "transport required"),
    timeout_ms = options.timeout_ms or 3000
  }, Client)
end

function Client:command(text)
  local ok, write_err, remaining = self.transport:write_all(text .. "\r", self.timeout_ms)
  if not ok then return nil, write_err or "AT write failed" end
  local frame, read_err = self.transport:read_result(
    remaining or self.timeout_ms, allowed_prefixes(text))
  if not frame then return nil, read_err or "AT command timed out" end
  local normalized, terminal = terminal_line(frame)
  if terminal == "OK" then return normalized end
  if terminal == "ERROR" or (terminal and terminal:match("^%+CM[ES] ERROR")) then
    return nil, terminal
  end
  return nil, "AT command returned no terminal status"
end

function Client:initialize()
  for _, command in ipairs({ "AT", "ATE0", "AT+CMEE=2" }) do
    local result, err = self:command(command)
    if not result then return nil, err end
  end
  return true
end

function Client:signal_quality()
  local response, err = self:command("AT+CSQ")
  if not response then return nil, err end
  local rssi, ber = response:match("%+CSQ:%s*(%d+)%s*,%s*(%d+)")
  rssi, ber = tonumber(rssi), tonumber(ber)
  if not rssi or not ber or (rssi > 31 and rssi ~= 99) or (ber > 7 and ber ~= 99) then
    return nil, "invalid CSQ response"
  end
  return rssi, ber
end

function Client:registration_status()
  local response, err = self:command("AT+CEREG?")
  if not response then return nil, err end
  local payload = response:match("%+CEREG:%s*([^\r\n]+)") or
    response:match("%+CGREG:%s*([012]%s*,%s*%d+[^\r\n]*)")
  if not payload then return nil, "invalid CEREG response" end
  local _, second = payload:match("^%s*(%d+)%s*,%s*(%d+)")
  local status = tonumber(second or payload:match("^%s*(%d+)%s*$"))
  if not status or status < 0 or status > 5 then return nil, "invalid CEREG response" end
  return status
end

M.Client = Client
return M

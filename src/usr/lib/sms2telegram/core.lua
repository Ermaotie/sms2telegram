local M = {}

local function utf8_width(text, pos)
  local byte = text:byte(pos)
  if not byte then return nil end
  if byte < 0x80 then return 1 end
  if byte >= 0xC2 and byte <= 0xDF then return 2 end
  if byte >= 0xE0 and byte <= 0xEF then return 3 end
  if byte >= 0xF0 and byte <= 0xF4 then return 4 end
  error("invalid UTF-8")
end

local function next_utf8(text, pos)
  local width = utf8_width(text, pos)
  if not width then return nil end
  if pos + width - 1 > #text then error("truncated UTF-8") end
  for offset = 1, width - 1 do
    local byte = text:byte(pos + offset)
    if not byte or byte < 0x80 or byte > 0xBF then error("invalid UTF-8 continuation") end
  end
  local first, second = text:byte(pos), text:byte(pos + 1)
  if width == 3 and ((first == 0xE0 and second < 0xA0) or
      (first == 0xED and second >= 0xA0)) then error("invalid UTF-8 codepoint") end
  if width == 4 and ((first == 0xF0 and second < 0x90) or
      (first == 0xF4 and second >= 0x90)) then error("invalid UTF-8 codepoint") end
  return pos + width
end

function M.utf8_length(text)
  if type(text) ~= "string" then error("text must be a string") end
  local count, pos = 0, 1
  while pos <= #text do
    pos = next_utf8(text, pos)
    count = count + 1
  end
  return count
end

function M.utf8_prefix(text, max_chars)
  local pos, count = 1, 0
  while pos <= #text and count < max_chars do
    pos = next_utf8(text, pos)
    count = count + 1
  end
  return text:sub(1, pos - 1), text:sub(pos)
end

local function metadata_for(message)
  return "📩 短信信息\n来自：" .. message.sender .. "\n时间：" .. message.timestamp
end

local function split_body(body, limit, metadata, count)
  local count_text = tostring(count)
  local suffix = "\n\n[" .. string.rep("9", #count_text) .. "/" .. count_text .. "]\n" .. metadata
  local available = limit - M.utf8_length(suffix)
  if available < 1 then error("Telegram limit is too small for SMS metadata") end
  local parts, remaining = {}, body
  while #remaining > 0 do
    local prefix
    prefix, remaining = M.utf8_prefix(remaining, available)
    parts[#parts + 1] = prefix
  end
  return parts
end

function M.format_parts(message, limit)
  if type(message) ~= "table" or type(message.sender) ~= "string" or
      type(message.timestamp) ~= "string" or type(message.body) ~= "string" then
    return nil, "invalid SMS message"
  end
  local ok = pcall(M.utf8_length, message.sender .. message.timestamp .. message.body)
  if not ok then return nil, "SMS is not valid UTF-8" end
  local metadata = metadata_for(message)
  if M.utf8_length(message.body .. "\n\n" .. metadata) <= limit then
    return { message.body .. "\n\n" .. metadata }
  end
  local count, bodies = 1
  while true do
    bodies = split_body(message.body, limit, metadata, count)
    if #tostring(#bodies) == #tostring(count) then break end
    count = #bodies
  end
  local parts = {}
  for index, body in ipairs(bodies) do
    parts[index] = body .. "\n\n[" .. index .. "/" .. #bodies .. "]\n" .. metadata
  end
  return parts
end

function M.route_device(route_output)
  local previous
  for token in tostring(route_output or ""):gmatch("%S+") do
    if previous == "dev" then return token end
    previous = token
  end
end

function M.next_backoff(current, initial, maximum)
  if not current then return initial end
  return math.min(current * 2, maximum)
end

return M

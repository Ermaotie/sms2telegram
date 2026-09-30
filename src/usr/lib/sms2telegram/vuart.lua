local M = {}

local function nonempty(value, maximum)
  return type(value) == "string" and value ~= "" and #value <= maximum
end

function M.decode_line(line, decode_json)
  if type(line) ~= "string" then return nil, "line is not a string" end
  if line:match("^%s*$") then return false end
  if #line > 65536 then return nil, "JSON line is too long" end
  local called, message = pcall(decode_json, line)
  if not called or type(message) ~= "table" then return nil, "invalid JSON" end
  if message.type == "ready" then
    if message.project ~= nil and not nonempty(message.project, 128) then
      return nil, "invalid ready event"
    end
    return message
  end
  if message.type ~= "sms" then return nil, "unknown event type" end
  if not nonempty(message.number, 128) or type(message.text) ~= "string" or
      #message.text > 65536 or not nonempty(message.timestamp, 64) or
      not nonempty(message.message_id, 256) then
    return nil, "invalid SMS event"
  end
  return message
end

return M

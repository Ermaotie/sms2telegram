local M = {}

local function encode_codepoint(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64))
  end
  return string.char(
    0xE0 + math.floor(cp / 4096),
    0x80 + (math.floor(cp / 64) % 64),
    0x80 + (cp % 64)
  )
end

function M.ucs2_to_utf8(hex)
  if type(hex) ~= "string" or #hex % 4 ~= 0 or hex:find("[^0-9A-Fa-f]") then
    return nil, "invalid UCS2 hexadecimal input"
  end
  local out = {}
  for pos = 1, #hex, 4 do
    local cp = tonumber(hex:sub(pos, pos + 3), 16)
    if cp >= 0xD800 and cp <= 0xDFFF then
      return nil, "UCS2 surrogate is invalid"
    end
    out[#out + 1] = encode_codepoint(cp)
  end
  return table.concat(out)
end

local function utf8_width(text, pos)
  local first = text:byte(pos)
  if not first then return nil end
  if first < 0x80 then return 1 end
  if first >= 0xC2 and first <= 0xDF then return 2 end
  if first >= 0xE0 and first <= 0xEF then return 3 end
  if first >= 0xF0 and first <= 0xF4 then return 4 end
  error("invalid UTF-8 leading byte")
end

local function next_utf8(text, pos)
  local width = utf8_width(text, pos)
  if not width then return nil end
  if pos + width - 1 > #text then error("truncated UTF-8 sequence") end
  local second = text:byte(pos + 1)
  if width == 3 and ((text:byte(pos) == 0xE0 and second < 0xA0) or
      (text:byte(pos) == 0xED and second > 0x9F)) then
    error("invalid UTF-8 codepoint")
  end
  if width == 4 and ((text:byte(pos) == 0xF0 and second < 0x90) or
      (text:byte(pos) == 0xF4 and second > 0x8F)) then
    error("invalid UTF-8 codepoint")
  end
  for i = pos + 1, pos + width - 1 do
    local byte = text:byte(i)
    if byte < 0x80 or byte > 0xBF then error("invalid UTF-8 continuation byte") end
  end
  return pos + width
end

function M.utf8_length(text)
  local count, pos = 0, 1
  while pos <= #text do
    pos = next_utf8(text, pos)
    count = count + 1
  end
  return count
end

function M.utf8_prefix(text, max_chars)
  local count, pos = 0, 1
  while pos <= #text and count < max_chars do
    pos = next_utf8(text, pos)
    count = count + 1
  end
  return text:sub(1, pos - 1), text:sub(pos)
end

local function is_ucs2_hex(value)
  return type(value) == "string" and #value > 0 and #value % 4 == 0 and
    not value:find("[^0-9A-Fa-f]")
end

local function decode_text(value)
  if not is_ucs2_hex(value) then return value end
  return M.ucs2_to_utf8(value)
end

local function csv_fields(line)
  local fields, pos = {}, 1
  while true do
    if pos > #line then
      fields[#fields + 1] = ""
      return fields
    end

    local field = {}
    if line:sub(pos, pos) == '"' then
      pos = pos + 1
      while true do
        local byte = line:sub(pos, pos)
        if byte == "" then return nil, "unterminated quoted CMGL field" end
        if byte == '"' then
          if line:sub(pos + 1, pos + 1) == '"' then
            field[#field + 1] = '"'
            pos = pos + 2
          else
            pos = pos + 1
            if pos <= #line and line:sub(pos, pos) ~= "," then
              return nil, "invalid quoted CMGL field"
            end
            break
          end
        else
          field[#field + 1] = byte
          pos = pos + 1
        end
      end
    else
      local start = pos
      while pos <= #line and line:sub(pos, pos) ~= "," do
        if line:sub(pos, pos) == '"' then return nil, "invalid CMGL field" end
        pos = pos + 1
      end
      field[#field + 1] = line:sub(start, pos - 1)
    end

    fields[#fields + 1] = table.concat(field)
    if pos > #line then return fields end
    pos = pos + 1
  end
end

local function decode_body(lines)
  local joined = table.concat(lines)
  if is_ucs2_hex(joined) then return M.ucs2_to_utf8(joined) end

  local decoded = {}
  for i, line in ipairs(lines) do
    local text, err = decode_text(line)
    if not text then return nil, err end
    decoded[i] = text
  end
  return table.concat(decoded, "\n")
end

function M.parse_cmgl(response)
  if type(response) ~= "string" then return nil, "CMGL response must be a string" end
  response = response:gsub("\r\n", "\n"):gsub("\r", "\n")

  local lines = {}
  for line in (response .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  local terminal_index
  for i = #lines, 1, -1 do
    if lines[i] ~= "" then
      if lines[i] == "OK" then terminal_index = i end
      break
    end
  end

  local messages, current, terminal = {}, nil, false
  local function finish_record()
    if not current then return true end
    local sender, sender_err = decode_text(current.fields[3])
    if not sender then return nil, sender_err end
    local body, body_err = decode_body(current.body_lines)
    if not body then return nil, body_err end
    local fields = current.fields
    if #fields < 5 or not tonumber(fields[1]) then
      return nil, "malformed CMGL header"
    end
    messages[#messages + 1] = {
      index = assert(tonumber(fields[1])),
      status = fields[2],
      sender = sender,
      timestamp = fields[5] or "",
      body = body
    }
    current = nil
    return true
  end

  for i, line in ipairs(lines) do
    local header = line:match("^%+CMGL:%s*(.*)$")
    if header then
      local ok, err = finish_record()
      if not ok then return nil, err end
      local fields, fields_err = csv_fields(header)
      if not fields or #fields < 5 or not tonumber(fields[1]) then
        return nil, fields_err or "malformed CMGL header"
      end
      current = { fields = fields, body_lines = {} }
    elseif i == terminal_index then
      local ok, err = finish_record()
      if not ok then return nil, err end
      terminal = true
    elseif line:match("^ERROR$") or line:match("^%+CMS ERROR") then
      return nil, "CMGL command failed"
    elseif current then
      current.body_lines[#current.body_lines + 1] = line
    elseif terminal and line ~= "" then
      return nil, "unexpected data after CMGL terminal status"
    end
  end

  if not terminal then return nil, "missing CMGL terminal status" end
  return messages
end

local function metadata_for(message)
  return "📩 短信信息\n来自：" .. message.sender .. "\n时间：" .. message.timestamp
end

local function split_body(body, limit, metadata, count)
  local count_text = tostring(count)
  local widest_index = string.rep("9", #count_text)
  local suffix = "\n\n[" .. widest_index .. "/" .. count_text .. "]\n" .. metadata
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
  local metadata = metadata_for(message)
  local body = message.body
  if M.utf8_length(body .. "\n\n" .. metadata) <= limit then
    return { body .. "\n\n" .. metadata }
  end

  local count = 1
  local bodies
  while true do
    bodies = split_body(body, limit, metadata, count)
    local final_count = #bodies
    if #tostring(final_count) == #tostring(count) then break end
    count = final_count
  end
  local parts = {}
  for i, part in ipairs(bodies) do
    parts[i] = part .. "\n\n[" .. i .. "/" .. #bodies .. "]\n" .. metadata
  end
  return parts
end

function M.route_device(route_output)
  local previous
  for token in route_output:gmatch("%S+") do
    if previous == "dev" then return token end
    previous = token
  end
  return nil
end

function M.next_backoff(current, initial, maximum)
  if not current then return initial end
  return math.min(current * 2, maximum)
end

return M

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
  if not is_ucs2_hex(value) then
    local ok, err = pcall(M.utf8_length, value)
    if not ok then return nil, "invalid UTF-8 text: " .. tostring(err) end
    return value
  end
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
  local decoded = {}
  for i, line in ipairs(lines) do
    local ok, err = pcall(M.utf8_length, line)
    if not ok then return nil, "invalid UTF-8 text: " .. tostring(err) end
    decoded[i] = line
  end
  return table.concat(decoded, "\n")
end

local function sms_timestamp(value)
  return value and value:match("^%d%d/%d%d/%d%d,%d%d:%d%d:%d%d ?[+-]%d%d$")
end

local function valid_index(value)
  return value == "0" or (type(value) == "string" and value:match("^[1-9][0-9]*$"))
end

local function hex_bytes(hex)
  if type(hex) ~= "string" or #hex % 2 ~= 0 or hex:find("[^0-9A-Fa-f]") then
    return nil, "invalid PDU hexadecimal input"
  end
  local bytes = {}
  for pos = 1, #hex, 2 do bytes[#bytes + 1] = tonumber(hex:sub(pos, pos + 1), 16) end
  return bytes
end

local function swapped_digits(bytes, pos, octets, digits)
  local out = {}
  for offset = 0, octets - 1 do
    local byte = bytes[pos + offset]
    if not byte then return nil, "truncated PDU address" end
    out[#out + 1] = string.format("%X%X", byte % 16, math.floor(byte / 16))
  end
  return table.concat(out):sub(1, digits)
end

local gsm_special = {
  [0] = "@", [1] = "£", [2] = "$", [3] = "¥", [4] = "è", [5] = "é",
  [6] = "ù", [7] = "ì", [8] = "ò", [9] = "Ç", [10] = "\n", [11] = "Ø",
  [12] = "ø", [13] = "\r", [14] = "Å", [15] = "å", [16] = "Δ", [17] = "_",
  [18] = "Φ", [19] = "Γ", [20] = "Λ", [21] = "Ω", [22] = "Π", [23] = "Ψ",
  [24] = "Σ", [25] = "Θ", [26] = "Ξ", [28] = "Æ", [29] = "æ", [30] = "ß",
  [31] = "É", [36] = "¤", [64] = "¡", [91] = "Ä", [92] = "Ö", [93] = "Ñ",
  [94] = "Ü", [95] = "§", [96] = "¿", [123] = "ä", [124] = "ö", [125] = "ñ",
  [126] = "ü", [127] = "à"
}
local gsm_extension = {
  [10] = "\f", [20] = "^", [40] = "{", [41] = "}", [47] = "\\",
  [60] = "[", [61] = "~", [62] = "]", [64] = "|", [101] = "€"
}

local function gsm_char(value)
  if gsm_special[value] then return gsm_special[value] end
  if (value >= 32 and value <= 35) or (value >= 37 and value <= 63) or
      (value >= 65 and value <= 90) or (value >= 97 and value <= 122) then
    return string.char(value)
  end
  return "�"
end

local function decode_gsm7(bytes, septets, start_septet, bit_offset)
  local out, escaped = {}, false
  start_septet = start_septet or 0
  bit_offset = bit_offset or 0
  for number = start_septet, start_septet + septets - 1 do
    local bit = bit_offset + number * 7
    local index = math.floor(bit / 8) + 1
    local shift = bit % 8
    if not bytes[index] then return nil, "truncated GSM7 user data" end
    local value = math.floor(bytes[index] / (2 ^ shift))
    if shift > 1 then
      if not bytes[index + 1] then return nil, "truncated GSM7 user data" end
      value = value + bytes[index + 1] * (2 ^ (8 - shift))
    end
    value = value % 128
    if escaped then
      out[#out + 1] = gsm_extension[value] or "�"
      escaped = false
    elseif value == 27 then
      escaped = true
    else
      out[#out + 1] = gsm_char(value)
    end
  end
  if escaped then return nil, "truncated GSM7 escape" end
  return table.concat(out)
end

local function decode_shifted_gsm7(bytes, udl)
  local best, best_score
  for bit_offset = 0, 6 do
    local available = math.floor((#bytes * 8 - bit_offset) / 7)
    local septets = math.min(udl, available)
    if septets > 0 then
      local candidate = decode_gsm7(bytes, septets, 0, bit_offset)
      if candidate then
        candidate = candidate:gsub("@+$", "")
        local good, visible, bad = 0, 0, 0
        for index = 1, #candidate do
          local byte = candidate:byte(index)
          if byte == 9 or byte == 10 or byte == 13 or (byte >= 32 and byte <= 126) then
            good = good + 1
            if byte >= 33 and byte <= 126 then visible = visible + 1 end
          else
            bad = bad + 1
          end
        end
        local otp_like = false
        for digits in candidate:gmatch("%d+") do
          if #digits >= 4 and #digits <= 8 then otp_like = true; break end
        end
        local has_link = candidate:find("http://", 1, true) or
          candidate:find("https://", 1, true)
        local has_words = candidate:match("%a+%s+%a+") ~= nil
        local score = good - bad * 4
        if otp_like then score = score + 40 end
        if has_link then score = score + 20 end
        if has_words then score = score + 10 end
        if candidate:find("\n", 1, true) then score = score + 5 end
        local strong_evidence = has_link or (otp_like and has_words)
        if strong_evidence and visible >= 4 and good >= bad * 3 and
            (not best_score or score > best_score) then
          best, best_score = candidate, score
        end
      end
    end
  end
  return best
end

local function decode_timestamp(bytes, pos)
  for offset = 0, 6 do
    if not bytes[pos + offset] then return nil, "truncated PDU timestamp" end
  end
  local function pair_value(byte, signed)
    local low, high = byte % 16, math.floor(byte / 16)
    if signed and low >= 8 then low = low - 8 end
    if low > 9 or high > 9 then return nil end
    return low * 10 + high
  end
  local values = {}
  for offset = 0, 5 do values[offset + 1] = pair_value(bytes[pos + offset]) end
  local timezone_value = pair_value(bytes[pos + 6], true)
  if not values[1] or not values[2] or not values[3] or not values[4] or
      not values[5] or not values[6] or not timezone_value or
      values[2] < 1 or values[2] > 12 or values[3] < 1 or values[3] > 31 or
      values[4] > 23 or values[5] > 59 or values[6] > 59 or timezone_value > 96 then
    return nil, "invalid PDU timestamp"
  end
  local function pair(byte) return string.format("%X%X", byte % 16, math.floor(byte / 16)) end
  local timezone = bytes[pos + 6]
  local low, high = timezone % 16, math.floor(timezone / 16)
  local sign = "+"
  if low >= 8 then sign, low = "-", low - 8 end
  return table.concat({
    pair(bytes[pos]), "/", pair(bytes[pos + 1]), "/", pair(bytes[pos + 2]), ",",
    pair(bytes[pos + 3]), ":", pair(bytes[pos + 4]), ":", pair(bytes[pos + 5]),
    sign, string.format("%X%X", low, high)
  })
end

local function pdu_alphabet(dcs)
  local group = math.floor(dcs / 16)
  if group <= 3 then
    if math.floor(dcs / 32) % 2 == 1 then return nil, "compressed PDU is unsupported" end
    local alphabet = math.floor(dcs / 4) % 4
    if alphabet == 3 then return nil, "reserved PDU data coding scheme" end
    return alphabet
  end
  if group == 12 or group == 13 then return 0 end
  if group == 14 then return 2 end
  if group == 15 then return math.floor(dcs / 4) % 2 end
  return nil, "unsupported PDU data coding scheme"
end

function M.pdu_matches_length(pdu, tpdu_length)
  local bytes = hex_bytes(pdu)
  local length = tonumber(tpdu_length)
  if not bytes or not length or length < 1 or length % 1 ~= 0 or not bytes[1] then return false end
  return #bytes == 1 + bytes[1] + length
end

function M.decode_sms_pdu(pdu)
  local bytes, bytes_err = hex_bytes(pdu)
  if not bytes then return nil, bytes_err end
  local smsc_length = bytes[1]
  if not smsc_length or #bytes < 2 + smsc_length then return nil, "truncated SMSC address" end
  local pos = 2 + smsc_length
  local first = bytes[pos]
  if not first then return nil, "missing PDU first octet" end
  local mti = first % 4
  if mti == 1 then return { kind = "outgoing" } end
  if mti == 2 then return { kind = "report" } end
  if mti ~= 0 then return nil, "unsupported PDU message type" end
  local udhi = math.floor(first / 64) % 2 == 1
  pos = pos + 1

  local address_length, toa = bytes[pos], bytes[pos + 1]
  if not address_length or not toa then return nil, "truncated PDU sender" end
  pos = pos + 2
  local sender
  if math.floor(toa / 16) % 8 == 5 then
    local address_octets = math.ceil(address_length / 2)
    local address_septets = math.floor(address_length * 4 / 7)
    local address_bytes = {}
    for offset = 0, address_octets - 1 do address_bytes[#address_bytes + 1] = bytes[pos + offset] end
    sender = decode_gsm7(address_bytes, address_septets)
    if not sender then return nil, "invalid alphanumeric PDU sender" end
    pos = pos + address_octets
  else
    local address_octets = math.ceil(address_length / 2)
    sender = swapped_digits(bytes, pos, address_octets, address_length)
    if not sender then return nil, "truncated PDU sender" end
    if sender:find("[^0-9]") then return nil, "invalid PDU sender digits" end
    if math.floor(toa / 16) % 8 == 1 then sender = "+" .. sender end
    pos = pos + address_octets
  end

  if not bytes[pos] or not bytes[pos + 1] then return nil, "truncated PDU protocol fields" end
  local dcs = bytes[pos + 1]
  pos = pos + 2
  local timestamp, timestamp_err = decode_timestamp(bytes, pos)
  pos = pos + 7
  local udl = bytes[pos]
  if not udl then return nil, "missing PDU user data length" end
  pos = pos + 1
  local user_data = {}
  for index = pos, #bytes do user_data[#user_data + 1] = bytes[index] end

  local alphabet, alphabet_err = pdu_alphabet(dcs)
  if alphabet == nil then return nil, alphabet_err end
  if not timestamp then
    local recovered = not udhi and alphabet == 0 and decode_shifted_gsm7(user_data, udl) or nil
    if recovered and recovered ~= "" then
      return {
        kind = "incoming", sender = sender,
        timestamp = "未知（原始短信时间异常）", body = recovered
      }
    end
    return nil, timestamp_err
  end
  local body
  if alphabet == 0 then
    if #user_data ~= math.ceil(udl * 7 / 8) then return nil, "GSM7 user data length mismatch" end
    local header_septets = 0
    if udhi then
      if not user_data[1] then return nil, "missing PDU user data header" end
      header_septets = math.ceil((user_data[1] + 1) * 8 / 7)
      if header_septets > udl then return nil, "invalid PDU user data header" end
    end
    body = decode_gsm7(user_data, udl - header_septets, header_septets)
  elseif alphabet == 2 then
    if #user_data ~= udl then return nil, "UCS2 user data length mismatch" end
    local start = 1
    if udhi then
      if not user_data[1] then return nil, "missing PDU user data header" end
      start = user_data[1] + 2
    end
    if start > udl + 1 or (udl - start + 1) % 2 ~= 0 then
      return nil, "invalid UCS2 user data"
    end
    local hex = {}
    for index = start, udl do hex[#hex + 1] = string.format("%02X", user_data[index]) end
    body = M.ucs2_to_utf8(table.concat(hex))
  else
    return nil, "unsupported PDU data coding scheme"
  end
  if not body or body == "" then return nil, "invalid or empty PDU body" end
  return { kind = "incoming", sender = sender, timestamp = timestamp, body = body }
end

function M.cmgl_record_type(header)
  local fields, err = csv_fields(header)
  if not fields or not valid_index(fields[1]) then
    return nil, err or "malformed CMGL header"
  end
  local status = fields[2]
  if #fields == 4 and status:match("^[0-3]$") and
      tonumber(fields[4]) and tonumber(fields[4]) > 0 then
    return "pdu", fields
  end
  if status == "STO UNSENT" or status == "STO SENT" then
    if #fields >= 4 then return "outgoing", fields end
  elseif status == "REC READ" or status == "REC UNREAD" then
    -- STATUS-REPORT includes FO/MR before the recipient, then two timestamps.
    -- Its REC status is also used by DELIVER and cannot identify the TPDU type.
    local fo = tonumber(fields[3])
    if #fields == 9 and fo and fo % 4 == 2 and tonumber(fields[4]) and
        tonumber(fields[6]) and sms_timestamp(fields[7]) and sms_timestamp(fields[8]) and
        tonumber(fields[9]) then
      return "report", fields
    end
    if (#fields == 5 or #fields == 7) and fields[3] ~= "" and sms_timestamp(fields[5]) then
      return "incoming", fields
    end
  end
  return nil, "malformed CMGL header"
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
    if current.kind == "pdu" then
      if #current.body_lines == 0 then return nil, "missing CMGL PDU body" end
      local pdu = table.concat(current.body_lines)
      if not M.pdu_matches_length(pdu, current.fields[4]) then
        return nil, "CMGL PDU length mismatch"
      end
      local numeric_status = tonumber(current.fields[2])
      if numeric_status == 0 or numeric_status == 1 then
        local decoded, decode_err = M.decode_sms_pdu(pdu)
        if not decoded then return nil, decode_err end
        if decoded.kind == "incoming" then
          messages[#messages + 1] = {
            index = assert(tonumber(current.fields[1])),
            status = numeric_status == 0 and "REC UNREAD" or "REC READ",
            sender = decoded.sender,
            timestamp = decoded.timestamp,
            body = decoded.body
          }
        end
      end
      current = nil
      return true
    end
    if current.kind ~= "incoming" then current = nil return true end
    if #current.body_lines == 0 then return nil, "missing CMGL incoming body" end
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
      local kind, fields = M.cmgl_record_type(header)
      if not kind then
        return nil, fields
      end
      current = { kind = kind, fields = fields, body_lines = {} }
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

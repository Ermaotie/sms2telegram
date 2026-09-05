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

return M

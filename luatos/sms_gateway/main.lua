PROJECT = "sms_gateway"
VERSION = "1.0.0"

local sys = require "sys"
local uartid = uart.VUART_0
local sequence = 0

local function timestamp(metas)
  if type(metas) == "table" and tonumber(metas.year) and tonumber(metas.mon) and
      tonumber(metas.day) and tonumber(metas.hour) and tonumber(metas.min) and
      tonumber(metas.sec) then
    return string.format("%04d-%02d-%02d %02d:%02d:%02d",
      tonumber(metas.year), tonumber(metas.mon), tonumber(metas.day),
      tonumber(metas.hour), tonumber(metas.min), tonumber(metas.sec))
  end
  return os.date("%Y-%m-%d %H:%M:%S")
end

local function write_message(message)
  local encoded, err = json.encode(message)
  if not encoded then
    log.error("sms_gateway", "json encode failed", err)
    return
  end
  uart.write(uartid, encoded .. "\n")
end

assert(uart.setup(uartid, 115200, 8, 1) == 0, "VUART setup failed")
write_message({ type = "ready", project = PROJECT, version = VERSION })

if sms.autoLong then assert(sms.autoLong(true), "long SMS setup failed") end
sms.setNewSmsCb(function(num, txt, metas)
  sequence = sequence + 1
  local received_at = timestamp(metas)
  write_message({
    type = "sms",
    number = num,
    text = txt,
    timestamp = received_at,
    message_id = string.format("%s_%s_%d", received_at:gsub("%D", ""), num, sequence)
  })
end)

sys.run()

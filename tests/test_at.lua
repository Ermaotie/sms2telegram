local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local at = dofile(root .. "/usr/lib/sms2telegram/at.lua")

local responses = {
  ["AT"] = "OK\r\n", ["ATE0"] = "OK\r\n", ["AT+CMEE=2"] = "OK\r\n",
  ["AT+CSQ"] = "+CSQ: 22,0\r\nOK\r\n",
  ["AT+CEREG?"] = "+CEREG: 0,5\r\nOK\r\n"
}
local commands, transport = {}, {}
function transport:write_all(bytes)
  self.current = bytes:gsub("\r$", "")
  commands[#commands + 1] = self.current
  return true, nil, 3000
end
function transport:read_result() return responses[self.current] end

local client = at.Client.new(transport)
t.eq("diagnostic AT initialization", client:initialize(), true)
t.eq("no SMS AT commands", table.concat(commands, "|"), "AT|ATE0|AT+CMEE=2")
local rssi, ber = client:signal_quality()
t.eq("signal RSSI", rssi, 22)
t.eq("signal BER", ber, 0)
t.eq("registration", client:registration_status(), 5)
t.eq("SMS scan method removed", client.scan, nil)
t.eq("SMS delete method removed", client.delete, nil)
t.eq("CMTI waiter removed", client.wait_for_cmti, nil)
t.finish()

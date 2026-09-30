local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local serial = dofile(root .. "/usr/lib/sms2telegram/serial.lua")

local chunks = { '{"type":"sms",', '"text":"one"}\n{"type":"ready"}\n' }
local clock = 0
local fd = { read = function() return table.remove(chunks, 1) end }
local nixio = {
  gettimeofday = function() return clock, 0 end,
  poll_flags = function(name)
    local flags = { ["in"] = 1, out = 2, err = 4, hup = 8 }
    return flags[name] or 1
  end,
  poll = function(pfds, timeout)
    if #chunks > 0 then pfds[1].revents = 1; return 1 end
    clock = clock + timeout / 1000
    return 0
  end
}
local transport = setmetatable({ fd = fd, nixio = nixio, buffer = "", max_buffer = 65536 }, serial.Transport)
t.eq("partial reads form one line", transport:next_line(1000), '{"type":"sms","text":"one"}')
t.eq("second line remains buffered", transport:next_line(1000), '{"type":"ready"}')
t.eq("idle read times out without error", transport:next_line(10), nil)
t.finish()

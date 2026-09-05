local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local core = dofile(root .. "/usr/lib/sms2telegram/core.lua")
local at = dofile(root .. "/usr/lib/sms2telegram/at.lua")

local function fake_transport(results, lines)
  local transport = { commands = {}, results = results or {}, lines = lines or {} }
  function transport:write_all(bytes)
    self.commands[#self.commands + 1] = bytes:sub(1, -2)
    return true
  end
  function transport:read_result()
    local value = table.remove(self.results, 1)
    if type(value) == "table" then return value[1], value[2] end
    return value
  end
  function transport:wait_line()
    local value = table.remove(self.lines, 1)
    if type(value) == "table" then return value[1], value[2] end
    return value
  end
  return transport
end

local cmgl = table.concat({
  '+CMGL: 7,"REC READ","+8613800000000",,"26/09/05,14:30:00+32"',
  'hello', 'OK', ''
}, "\r\n")

local init_responses = { "OK\r\n", "OK\r\n", "OK\r\n", "OK\r\n", "OK\r\n", "OK\r\n", "OK\r\n" }
local fake = fake_transport(init_responses)
local client = at.Client.new(fake, core, { storage = "SM", timeout_ms = 3000 })
local ok, err = client:initialize()
t.eq("AT init succeeds", ok, true)
t.eq("AT init sequence", table.concat(fake.commands, "|"),
  'AT|ATE0|AT+CMEE=2|AT+CMGF=1|AT+CSCS="UCS2"|AT+CPMS="SM","SM","SM"|AT+CNMI=2,1,0,0,0')

local scan_fake = fake_transport({ cmgl, "OK\r\n" })
local scan_client = at.Client.new(scan_fake, core, { timeout_ms = 3000 })
t.eq("scan command", assert(scan_client:scan())[1].index, 7)
t.eq("delete success", scan_client:delete(7), true)
t.eq("scan sends CMGL", scan_fake.commands[1], 'AT+CMGL="ALL"')
t.eq("delete sends CMGD", scan_fake.commands[2], "AT+CMGD=7")

local timeout_client = at.Client.new(fake_transport({ { nil, "timeout" } }), core, {})
local timeout_value, timeout_err = timeout_client:scan()
t.eq("timeout result", timeout_value, nil)
t.truthy("timeout error", timeout_err and timeout_err:match("timeout"))

local terminal_client = at.Client.new(fake_transport({ "\r\nERROR\r\n" }), core, {})
local terminal_value, terminal_err = terminal_client:scan()
t.eq("terminal ERROR result", terminal_value, nil)
t.truthy("terminal ERROR", terminal_err and terminal_err:match("ERROR"))

local cms_client = at.Client.new(fake_transport({ "\r\n+CMS ERROR: 500\r\n" }), core, {})
local cms_value, cms_err = cms_client:scan()
t.eq("CMS ERROR result", cms_value, nil)
t.truthy("CMS ERROR", cms_err and cms_err:match("CMS ERROR"))

local malformed_client = at.Client.new(fake_transport({ "+CMGL: nope\r\nbody\r\nOK\r\n" }), core, {})
local malformed_value, malformed_err = malformed_client:scan()
t.eq("malformed CMGL result", malformed_value, nil)
t.truthy("malformed CMGL error", malformed_err and malformed_err:match("CMGL"))

local invalid_delete = at.Client.new(fake_transport(), core, {})
local zero_value, zero_err = invalid_delete:delete(0)
t.eq("delete zero result", zero_value, nil)
t.truthy("delete zero error", zero_err and zero_err:match("index"))
local nondigit_value, nondigit_err = invalid_delete:delete("7;AT")
t.eq("delete nondigit result", nondigit_value, nil)
t.truthy("delete nondigit error", nondigit_err and nondigit_err:match("index"))

local hangup_client = at.Client.new(fake_transport({ { nil, "hangup" } }), core, {})
local hangup_value, hangup_err = hangup_client:scan()
t.eq("hangup result", hangup_value, nil)
t.truthy("hangup error", hangup_err and hangup_err:match("hangup"))

local cmti_client = at.Client.new(fake_transport({}, { '+CMTI: "SM",7' }), core, {})
t.eq("CMTI wakes waiter", cmti_client:wait_for_cmti(3000), true)
local unrelated_client = at.Client.new(fake_transport({}, { "+CREG: 1" }), core, {})
t.eq("unrelated URC does not wake waiter", unrelated_client:wait_for_cmti(3000), false)
local idle_client = at.Client.new(fake_transport({}, { nil }), core, {})
t.eq("idle timeout does not wake waiter", idle_client:wait_for_cmti(3000), false)

local saved_nixio, saved_preload = package.loaded.nixio, package.preload.nixio
package.loaded.nixio = nil
package.preload.nixio = function()
  local polls = 0
  local chunks = { "OK\r\n" }
  local fd = {
    setblocking = function() return true end,
    read = function() return table.remove(chunks, 1) end,
    close = function() end
  }
  return {
    fork = function() return 1 end,
    waitpid = function() return 1, "exited", 0 end,
    open = function() return fd end,
    gettimeofday = function() return 0, 0 end,
    poll_flags = function(name) return ({ ["in"] = 1, err = 8, hup = 16 })[name] end,
    poll = function(pfds)
      polls = polls + 1
      if polls == 1 then return 0 end
      if polls == 2 then pfds[1].revents = 1 return 1 end
      return 0
    end
  }
end
local numeric_transport = assert(at.open_nixio_transport("/dev/ttyACM0", 115200))
t.eq("numeric nixio poll flags", assert(numeric_transport:read_result(20)), "OK\n")
package.loaded.nixio, package.preload.nixio = saved_nixio, saved_preload

package.loaded.nixio = nil
package.preload.nixio = function()
  return {
    fork = function() return 1 end,
    waitpid = function() return 1, "exited", 127 end,
    gettimeofday = function() return 0, 0 end,
    open = function() error("serial open must not run after stty failure") end
  }
end
local setup_value, setup_err = at.open_nixio_transport("/dev/ttyACM0", 115200)
t.eq("terminal setup failure result", setup_value, nil)
t.truthy("terminal setup failure", setup_err and setup_err:match("stty"))
package.loaded.nixio, package.preload.nixio = saved_nixio, saved_preload

local stale_reads = { "stale\r\n" }
local poll_count = 0
package.loaded.nixio = nil
package.preload.nixio = function()
  local fd = {
    setblocking = function() return true end,
    read = function() return table.remove(stale_reads, 1) end,
    close = function() end
  }
  return {
    fork = function() return 1 end,
    waitpid = function() return 1, "exited", 0 end,
    open = function() return fd end,
    gettimeofday = function() return 0, 0 end,
    poll_flags = function(name) return ({ ["in"] = 1, err = 8, hup = 16 })[name] end,
    poll = function(pfds)
      poll_count = poll_count + 1
      if poll_count == 1 then pfds[1].revents = 1 return 1 end
      return 0
    end
  }
end
assert(at.open_nixio_transport("/dev/ttyACM0", 115200))
t.eq("stale serial bytes drained", #stale_reads, 0)
package.loaded.nixio, package.preload.nixio = saved_nixio, saved_preload

local exec_args
package.loaded.nixio = nil
package.preload.nixio = function()
  return {
    fork = function() return 0 end,
    exec = function(...) exec_args = { ... } error("stop fake child") end
  }
end
pcall(at.open_nixio_transport, "/dev/ttyACM0", 115200, "/tmp/sms2telegram-stty/usr/bin/stty")
t.eq("custom stty executable", exec_args[1], "/tmp/sms2telegram-stty/usr/bin/stty")
package.loaded.nixio, package.preload.nixio = saved_nixio, saved_preload

local setup_now, killed = 0, false
package.loaded.nixio = nil
package.preload.nixio = function()
  return {
    fork = function() return 99 end,
    waitpid = function(_, mode)
      if mode == "nohang" then return false end
      return 99, "signaled", 9
    end,
    kill = function() killed = true return true end,
    gettimeofday = function()
      return math.floor(setup_now / 1000), (setup_now % 1000) * 1000
    end,
    poll = function(_, timeout) setup_now = setup_now + timeout return 0 end
  }
end
local stalled_setup, stalled_setup_err = at.open_nixio_transport("/dev/ttyACM0", 115200)
t.eq("stalled terminal setup result", stalled_setup, nil)
t.truthy("stalled terminal setup timeout", stalled_setup_err and stalled_setup_err:match("timeout"))
t.eq("stalled terminal setup killed", killed, true)
package.loaded.nixio, package.preload.nixio = saved_nixio, saved_preload

local write_now = 0
package.loaded.nixio = nil
package.preload.nixio = function()
  local fd = {
    setblocking = function() return true end,
    write = function() return nil, "would block" end,
    read = function() return nil, "would block" end,
    close = function() end
  }
  return {
    fork = function() return 1 end,
    waitpid = function() return 1, "exited", 0 end,
    open = function() return fd end,
    gettimeofday = function()
      return math.floor(write_now / 1000), (write_now % 1000) * 1000
    end,
    poll_flags = function(...) return select(1, ...) == "out" and 4 or 1 end,
    poll = function(_, timeout) write_now = write_now + timeout return 0 end
  }
end
local stalled_transport = assert(at.open_nixio_transport("/dev/ttyACM0", 115200))
local stalled_client = at.Client.new(stalled_transport, core, { timeout_ms = 10 })
local stalled_write, stalled_write_err = stalled_client:command("AT")
t.eq("stalled write result", stalled_write, nil)
t.truthy("stalled write timeout", stalled_write_err and stalled_write_err:match("write timeout"))
package.loaded.nixio, package.preload.nixio = saved_nixio, saved_preload

local function real_transport_with_chunks(chunks)
  local original_loaded, original_preload = package.loaded.nixio, package.preload.nixio
  local now, first_poll = 0, true
  package.loaded.nixio = nil
  package.preload.nixio = function()
    local fd = {
      setblocking = function() return true end,
      write = function(_, bytes) return #bytes end,
      read = function() return table.remove(chunks, 1) end,
      close = function() end
    }
    return {
      fork = function() return 1 end,
      waitpid = function() return 1, "exited", 0 end,
      open = function() return fd end,
      gettimeofday = function()
        return math.floor(now / 1000), (now % 1000) * 1000
      end,
      poll_flags = function(...)
        local flags = { ["in"] = 1, out = 4, err = 8, hup = 16 }
        local value = 0
        for i = 1, select("#", ...) do value = value + flags[select(i, ...)] end
        return value
      end,
      poll = function(pfds, timeout)
        if first_poll then first_poll = false return 0 end
        if pfds[1].events == 28 then pfds[1].revents = 4 return 1 end
        if #chunks > 0 then pfds[1].revents = 1 return 1 end
        now = now + timeout
        return 0
      end
    }
  end
  local transport = assert(at.open_nixio_transport("/dev/ttyACM0", 115200))
  return transport, function()
    package.loaded.nixio, package.preload.nixio = original_loaded, original_preload
  end
end

local embedded_transport, restore_embedded = real_transport_with_chunks({ table.concat({
  '+CMGL: 8,"REC READ","+8613800000000",,"26/09/05,14:31:00+32"',
  "first line", "OK", "last line", "OK", ""
}, "\r\n") })
local embedded_client = at.Client.new(embedded_transport, core, { timeout_ms = 100 })
local embedded_messages = assert(embedded_client:scan())
t.eq("serial CMGL preserves embedded OK", embedded_messages[1].body, "first line\nOK\nlast line")
restore_embedded()

local urc_transport, restore_urc = real_transport_with_chunks({ table.concat({
  '+CMGL: 9,"REC READ","+8613800000000",,"26/09/05,14:32:00+32"',
  "+CREG: 1", "hello", "OK", ""
}, "\r\n") })
local urc_client = at.Client.new(urc_transport, core, { timeout_ms = 100 })
local urc_messages, urc_err = urc_client:scan()
t.eq("interleaved CREG has no messages", urc_messages, nil)
t.truthy("interleaved CREG is rejected", urc_err and urc_err:match("unexpected"))
restore_urc()

local blank_client = at.Client.new(fake_transport({ "" }), core, {})
local blank_call_ok, blank_value, blank_err = pcall(blank_client.scan, blank_client)
t.eq("blank frame does not throw", blank_call_ok, true)
t.eq("blank frame result", blank_value, nil)
t.truthy("blank frame error", blank_err and blank_err:match("terminal"))

t.finish()

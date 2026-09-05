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

local function allowed_prefixes_for(command)
  if command:match("^AT%+CMGL") then return { "+CMGL:" } end
  if command:match("^AT%+CPMS") then return { "+CPMS:" } end
  if command:match("^AT%+CMGF") then return { "+CMGF:" } end
  if command:match("^AT%+CNMI") then return { "+CNMI:" } end
  return {}
end

function Client.new(transport, core, options)
  options = options or {}
  return setmetatable({
    transport = assert(transport, "transport required"),
    core = assert(core, "core required"),
    storage = options.storage or "SM",
    timeout_ms = options.timeout_ms or 3000
  }, Client)
end

function Client:command(text)
  local ok, write_err, remaining = self.transport:write_all(text .. "\r", self.timeout_ms)
  if not ok then return nil, write_err or "AT write failed" end

  local frame, read_err = self.transport:read_result(
    remaining or self.timeout_ms, allowed_prefixes_for(text), text:match("^AT%+CMGL") ~= nil
  )
  if not frame then return nil, read_err or "AT command timed out" end

  local normalized, terminal = terminal_line(frame)
  if not terminal then return nil, "AT command returned no terminal status" end
  if terminal == "OK" then return normalized end
  if terminal == "ERROR" or terminal:match("^%+CMS ERROR") then return nil, terminal end
  return nil, "AT command returned no terminal status"
end

function Client:initialize()
  if type(self.storage) ~= "string" or not self.storage:match("^[A-Z][A-Z0-9]*$") then
    return nil, "invalid SMS storage"
  end
  local commands = {
    "AT",
    "ATE0",
    "AT+CMEE=2",
    "AT+CMGF=1",
    'AT+CSCS="UCS2"',
    'AT+CPMS="' .. self.storage .. '","' .. self.storage .. '","' .. self.storage .. '"',
    "AT+CNMI=2,1,0,0,0"
  }
  for _, command in ipairs(commands) do
    local result, err = self:command(command)
    if not result then return nil, err end
  end
  return true
end

function Client:scan()
  local response, err = self:command('AT+CMGL="ALL"')
  if not response then return nil, err end
  return self.core.parse_cmgl(response)
end

function Client:delete(index)
  index = tostring(index)
  if not index:match("^[1-9][0-9]*$") then return nil, "invalid SMS index" end
  local result, err = self:command("AT+CMGD=" .. index)
  if not result then return nil, err end
  return true
end

function Client:wait_for_cmti(timeout_ms)
  local line, err = self.transport:wait_line(timeout_ms or self.timeout_ms)
  if not line then
    if err then return nil, err end
    return false
  end
  return not not line:match('^%+CMTI:%s*"[^"]+",%s*%d+%s*$')
end

M.Client = Client

local function now_ms(nixio)
  local seconds, microseconds = nixio.gettimeofday()
  return seconds * 1000 + math.floor(microseconds / 1000)
end

local function normalize_frame(frame)
  return frame:gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function pop_line(transport)
  local newline = transport.buffer:find("\n", 1, true)
  if not newline then return nil end
  local line = transport.buffer:sub(1, newline - 1):gsub("\r$", "")
  transport.buffer = transport.buffer:sub(newline + 1)
  return line
end

local function is_terminal(line)
  return line == "OK" or line == "ERROR" or line:match("^%+CMS ERROR")
end

local Transport = {}
Transport.__index = Transport

local function has_event(nixio, revents, name)
  if type(revents) == "number" then
    local flag = tonumber(nixio.poll_flags(name))
    return math.floor(revents / flag) % 2 == 1
  end
  return revents and revents:contains(name)
end

function Transport:write_all(bytes, timeout_ms)
  timeout_ms = timeout_ms or 3000
  local deadline = now_ms(self.nixio) + timeout_ms
  local offset = 1
  while offset <= #bytes do
    local remaining = deadline - now_ms(self.nixio)
    if remaining <= 0 then return nil, "write timeout" end
    local ready, poll_err = self:poll_write(remaining)
    if ready == nil then return nil, poll_err end
    if not ready then return nil, "write timeout" end
    local written, err = self.fd:write(bytes:sub(offset))
    if not written then
      if err and err:lower():match("would block") then
        -- The descriptor remains nonblocking; wait for the next writable edge.
      else
        return nil, err or "serial write failed"
      end
    elseif written == 0 then
      return nil, "serial write made no progress"
    else
      offset = offset + written
    end
  end
  return true, nil, math.max(0, deadline - now_ms(self.nixio))
end

function Transport:poll_write(timeout_ms)
  local events = self.nixio.poll_flags("out", "err", "hup")
  local pfds = { { fd = self.fd, events = events } }
  local ready, poll_err = self.nixio.poll(pfds, timeout_ms)
  if ready == nil then return nil, poll_err or "serial poll failed" end
  if ready == 0 then return false end
  local revents = pfds[1].revents
  if revents and (has_event(self.nixio, revents, "err") or has_event(self.nixio, revents, "hup")) then
    return nil, has_event(self.nixio, revents, "hup") and "serial hangup" or "serial error"
  end
  return revents and has_event(self.nixio, revents, "out") or false
end

function Transport:poll_read(timeout_ms)
  local events = self.nixio.poll_flags("in", "err", "hup")
  local pfds = { { fd = self.fd, events = events } }
  local ready, poll_err = self.nixio.poll(pfds, timeout_ms)
  if ready == nil then return nil, poll_err or "serial poll failed" end
  if ready == 0 then return false end
  local revents = pfds[1].revents
  if revents and (has_event(self.nixio, revents, "err") or has_event(self.nixio, revents, "hup")) then
    return nil, has_event(self.nixio, revents, "hup") and "serial hangup" or "serial error"
  end
  if not revents or not has_event(self.nixio, revents, "in") then return false end
  local chunk, read_err = self.fd:read(4096)
  if not chunk then return nil, read_err or "serial read failed" end
  if #chunk == 0 then return nil, "serial hangup" end
  self.buffer = self.buffer .. chunk
  return true
end

function Transport:next_line(timeout_ms)
  local line = pop_line(self)
  if line then return line end
  local deadline = now_ms(self.nixio) + timeout_ms
  while true do
    local remaining = deadline - now_ms(self.nixio)
    if remaining <= 0 then return nil end
    local ready, err = self:poll_read(remaining)
    if ready == nil then return nil, err end
    if ready then
      line = pop_line(self)
      if line then return line end
    end
  end
end

function Transport:read_result(timeout_ms, allowed_prefixes, cmgl_mode)
  local lines = {}
  local deadline = now_ms(self.nixio) + timeout_ms
  local ambiguous_cmgl = false
  local function allowed_prefix(line)
    for _, prefix in ipairs(allowed_prefixes or {}) do
      if line:sub(1, #prefix) == prefix then return true end
    end
    return false
  end
  local function complete_frame()
    return normalize_frame(table.concat(lines, "\r\n") .. "\r\n")
  end
  local function complete_cmgl()
    local record, saw_header
    for _, line in ipairs(lines) do
      if line:match("^%+CMGL:%s*%d+") then
        if record and not record.has_body then return false end
        saw_header = true
        record = { has_body = false }
      elseif not saw_header and line ~= "" then
        return false
      else
        record.has_body = true
        if line ~= "" and (#line % 4 ~= 0 or line:find("[^0-9A-Fa-f]")) then
          return false
        end
      end
    end
    return not record or record.has_body
  end
  while true do
    local line = pop_line(self)
    if line then
      if line:match('^%+CMTI:%s*"[^"]+",%s*%d+%s*$') then
        self.urcs[#self.urcs + 1] = line
      else
        if line:match("^%+[A-Z][A-Z0-9]*:") and not is_terminal(line) and
            not allowed_prefix(line) then
          return nil, "unexpected URC in AT response: " .. line
        end
        if is_terminal(line) then
          if not cmgl_mode or line ~= "OK" or complete_cmgl() then
            lines[#lines + 1] = line
            return complete_frame()
          end
          ambiguous_cmgl = true
        end
        lines[#lines + 1] = line
      end
    else
      local remaining = deadline - now_ms(self.nixio)
      if remaining <= 0 then return nil, "timeout" end
      local ready, err = self:poll_read(remaining)
      if ready == nil then return nil, err end
      if not ready then
        if ambiguous_cmgl then return nil, "ambiguous CMGL response" end
        return nil, "timeout"
      end
    end
  end
end

function Transport:wait_line(timeout_ms)
  if #self.urcs > 0 then return table.remove(self.urcs, 1) end
  return self:next_line(timeout_ms)
end

function Transport:drain_stale()
  for _ = 1, 64 do
    local ready, err = self:poll_read(0)
    if ready == nil then return nil, err end
    if not ready then
      self.buffer = ""
      return true
    end
    while true do
      local line = pop_line(self)
      if not line then break end
      if line:match('^%+CMTI:%s*"[^"]+",%s*%d+%s*$') then
        self.urcs[#self.urcs + 1] = line
      end
    end
  end
  return nil, "serial input did not quiesce"
end

function Transport:close()
  if self.fd then self.fd:close() end
  self.fd = nil
end

local function wait_for_child(nixio, child, timeout_ms)
  local deadline = now_ms(nixio) + timeout_ms
  while true do
    local waited, state, status = nixio.waitpid(child, "nohang")
    if waited == nil then return nil, state or "stty wait failed" end
    if waited ~= false and waited ~= 0 then return waited, state, status end

    local remaining = deadline - now_ms(nixio)
    if remaining <= 0 then return nil, "timeout" end
    nixio.poll({}, math.min(50, remaining))
  end
end

local function configure_terminal(nixio, device, stty_executable)
  local child, fork_err = nixio.fork()
  if child == nil then return nil, fork_err or "unable to start stty" end
  if child == 0 then
    nixio.exec(unpack({ stty_executable, "-F", device, "115200", "raw", "-echo" }))
    os.exit(127)
  end
  local waited, state, status = wait_for_child(nixio, child, 3000)
  if not waited and state == "timeout" then
    local killed, kill_err = nixio.kill(child, 9)
    if not killed then return nil, "stty cleanup kill failed: " .. tostring(kill_err) end
    local reaped, reap_state = wait_for_child(nixio, child, 1000)
    if not reaped then
      if reap_state == "timeout" then return nil, "stty cleanup timeout" end
      return nil, "stty cleanup wait failed: " .. tostring(reap_state)
    end
    return nil, "stty setup timeout"
  end
  if not waited then return nil, state or "stty failed" end
  if state ~= "exited" or status ~= 0 then
    return nil, "stty failed"
  end
  return true
end

function M.open_nixio_transport(device, baud, stty_executable)
  if type(device) ~= "string" or not device:match("^/dev/tty[%w._%-]+$") then
    return nil, "invalid serial device"
  end
  baud = baud or 115200
  if type(baud) ~= "number" or baud <= 0 or baud % 1 ~= 0 then
    return nil, "invalid serial baud"
  end
  stty_executable = stty_executable or "/bin/stty"
  if type(stty_executable) ~= "string" or not stty_executable:match("^/") then
    return nil, "invalid stty executable"
  end

  local nixio = require "nixio"
  local configured, config_err = configure_terminal(nixio, device, stty_executable)
  if not configured then return nil, config_err end
  local fd, open_err = nixio.open(device, "r+")
  if not fd then return nil, open_err or "unable to open serial device" end
  local nonblocking, nonblocking_err = fd:setblocking(false)
  if not nonblocking then
    fd:close()
    return nil, nonblocking_err or "unable to make serial device nonblocking"
  end
  local transport = setmetatable({ fd = fd, nixio = nixio, buffer = "", urcs = {} }, Transport)
  local drained, drain_err = transport:drain_stale()
  if not drained then
    transport:close()
    return nil, drain_err
  end
  return transport
end

return M

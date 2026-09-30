local M = {}
local Transport = {}
Transport.__index = Transport

local function now_ms(nixio)
  local seconds, microseconds = nixio.gettimeofday()
  return seconds * 1000 + math.floor(microseconds / 1000)
end

local function has_event(nixio, revents, name)
  if type(revents) == "number" then
    local flag = tonumber(nixio.poll_flags(name))
    return math.floor(revents / flag) % 2 == 1
  end
  return revents and revents:contains(name)
end

local function pop_line(transport)
  local newline = transport.buffer:find("\n", 1, true)
  if not newline then return nil end
  local line = transport.buffer:sub(1, newline - 1):gsub("\r$", "")
  transport.buffer = transport.buffer:sub(newline + 1)
  return line
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
  local chunk, _, read_err = self.fd:read(4096)
  if not chunk then return nil, read_err or "serial read failed" end
  if #chunk == 0 then return nil, "serial hangup" end
  self.buffer = self.buffer .. chunk
  if #self.buffer > self.max_buffer and not self.buffer:find("\n", 1, true) then
    self.buffer = ""
    return nil, "serial line too long"
  end
  return true
end

function Transport:next_line(timeout_ms)
  local line = pop_line(self)
  if line then return line end
  local deadline = now_ms(self.nixio) + (timeout_ms or 3000)
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

function Transport:write_all(bytes, timeout_ms)
  local deadline = now_ms(self.nixio) + (timeout_ms or 3000)
  local offset = 1
  while offset <= #bytes do
    local remaining = deadline - now_ms(self.nixio)
    if remaining <= 0 then return nil, "write timeout" end
    local ready, poll_err = self:poll_write(remaining)
    if ready == nil then return nil, poll_err end
    if not ready then return nil, "write timeout" end
    local written, errno, write_err = self.fd:write(bytes:sub(offset))
    if not written then
      if errno ~= 11 then return nil, write_err or "serial write failed" end
    elseif written == 0 then
      return nil, "serial write made no progress"
    else
      offset = offset + written
    end
  end
  return true, nil, math.max(0, deadline - now_ms(self.nixio))
end

function Transport:read_result(timeout_ms, allowed_prefixes)
  local lines, deadline = {}, now_ms(self.nixio) + timeout_ms
  local function allowed(line)
    for _, prefix in ipairs(allowed_prefixes or {}) do
      if line:sub(1, #prefix) == prefix then return true end
    end
    return false
  end
  while true do
    local line = pop_line(self)
    if line then
      local terminal = line == "OK" or line == "ERROR" or line:match("^%+CM[ES] ERROR")
      if terminal then
        lines[#lines + 1] = line
        return table.concat(lines, "\r\n") .. "\r\n"
      elseif not line:match("^%+[A-Z][A-Z0-9]*:") or allowed(line) then
        lines[#lines + 1] = line
      end
    else
      local remaining = deadline - now_ms(self.nixio)
      if remaining <= 0 then return nil, "timeout" end
      local ready, err = self:poll_read(remaining)
      if ready == nil then return nil, err end
      if not ready then return nil, "timeout" end
    end
  end
end

function Transport:drain()
  for _ = 1, 64 do
    local ready, err = self:poll_read(0)
    if ready == nil then return nil, err end
    if not ready then self.buffer = ""; return true end
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

local function configure(nixio, device, baud, executable)
  local child, fork_err = nixio.fork()
  if child == nil then return nil, fork_err or "unable to start stty" end
  if child == 0 then
    nixio.exec(unpack({ executable, "-F", device, tostring(baud), "raw", "-echo" }))
    os.exit(127)
  end
  local waited, state, status = wait_for_child(nixio, child, 3000)
  if not waited and state == "timeout" then
    local killed, kill_err = nixio.kill(child, 9)
    if not killed then return nil, "stty cleanup kill failed: " .. tostring(kill_err) end
    local reaped = wait_for_child(nixio, child, 1000)
    if not reaped then return nil, "stty cleanup timeout" end
    return nil, "stty setup timeout"
  end
  if not waited then return nil, state or "stty failed" end
  if state ~= "exited" or status ~= 0 then return nil, "stty failed" end
  return true
end

function M.open(device, baud, options)
  options = options or {}
  if type(device) ~= "string" or not device:match("^/dev/[%w._/%-]+$") or
      device:find("..", 1, true) then return nil, "invalid serial device" end
  baud = baud or 115200
  if type(baud) ~= "number" or baud <= 0 or baud % 1 ~= 0 then
    return nil, "invalid serial baud"
  end
  local executable = options.stty or "/bin/stty"
  if type(executable) ~= "string" or not executable:match("^/") then
    return nil, "invalid stty executable"
  end
  local nixio = options.nixio or require "nixio"
  local configured, config_err = configure(nixio, device, baud, executable)
  if not configured then return nil, config_err end
  local fd, open_err = nixio.open(device, "r+")
  if not fd then return nil, open_err or "unable to open serial device" end
  local nonblocking, nonblocking_err = fd:setblocking(false)
  if not nonblocking then fd:close(); return nil, nonblocking_err or "unable to set nonblocking" end
  local transport = setmetatable({
    fd = fd, nixio = nixio, buffer = "", max_buffer = options.max_buffer or 65536
  }, Transport)
  if options.drain then
    local drained, drain_err = transport:drain()
    if not drained then transport:close(); return nil, drain_err end
  end
  return transport
end

M.Transport = Transport
return M

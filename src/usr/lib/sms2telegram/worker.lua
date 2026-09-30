local M = {}
local Worker = {}
Worker.__index = Worker

function Worker.new(deps, config)
  assert(type(deps) == "table" and type(deps.core) == "table" and
    type(deps.delivery) == "table" and type(deps.sender) == "table" and
    type(deps.route) == "function", "worker dependencies required")
  return setmetatable({
    deps = deps,
    config = config or {},
    pending = {},
    pending_keys = {},
    seen = {},
    seen_order = {},
    seen_limit = 200
  }, Worker)
end

local function key_for(message)
  -- message_id is only a hint; content prevents an ID collision from dropping a real SMS.
  return table.concat({ message.number, message.timestamp, message.text }, "\0")
end

function Worker:enqueue(message)
  local key = key_for(message)
  if self.seen[key] or self.pending_keys[key] then return false, "duplicate" end
  self.pending[#self.pending + 1] = message
  self.pending_keys[key] = true
  return true
end

function Worker:pending_count()
  return #self.pending
end

local function remember(self, key)
  self.seen[key] = true
  self.seen_order[#self.seen_order + 1] = key
  if #self.seen_order > self.seen_limit then
    self.seen[table.remove(self.seen_order, 1)] = nil
  end
end

function Worker:process_next()
  local message = self.pending[1]
  if not message then return true end
  local config, deps = self.config, self.deps
  if not deps.delivery.validate_credentials(config.bot_token, config.chat_id) then
    return nil, "config"
  end
  local parts, format_err = deps.core.format_parts({
    sender = message.number,
    timestamp = message.timestamp,
    body = message.text
  }, config.telegram_limit or 4096)
  if not parts then
    local key = key_for(message)
    table.remove(self.pending, 1)
    self.pending_keys[key] = nil
    return nil, "message", format_err, message
  end
  for _, part in ipairs(parts) do
    if not deps.delivery.route_allowed(deps.route(), config.allowed_wan_device, deps.core) then
      return nil, "route"
    end
    if not deps.sender:send_parts(config.bot_token, config.chat_id, { part }) then
      return nil, "telegram"
    end
  end
  local key = key_for(message)
  table.remove(self.pending, 1)
  self.pending_keys[key] = nil
  remember(self, key)
  return true, nil, nil, message
end

function M.new(deps, config)
  return Worker.new(deps, config)
end

return M

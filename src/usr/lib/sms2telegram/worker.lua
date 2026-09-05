local M = {}

local Worker = {}
Worker.__index = Worker

local function categorized(category)
  return nil, category
end

local function valid_dependencies(deps)
  return type(deps) == "table" and type(deps.core) == "table" and
    type(deps.delivery) == "table" and type(deps.at_client) == "table" and
    type(deps.sender) == "table" and type(deps.ledger) == "table" and
    type(deps.route) == "function"
end

function Worker.new(deps, config)
  assert(valid_dependencies(deps), "worker dependencies required")
  return setmetatable({ deps = deps, config = config or {} }, Worker)
end

function Worker:cycle()
  local deps, config = self.deps, self.config
  local credentials_ok = deps.delivery.validate_credentials(config.bot_token, config.chat_id)
  if not credentials_ok then return categorized("config") end

  local messages = deps.at_client:scan()
  if not messages then return categorized("at") end

  for _, message in ipairs(messages) do
    local fingerprint = deps.delivery.fingerprint(message)
    if not fingerprint then return categorized("ledger") end

    if deps.ledger:contains(message.index, fingerprint) then
      local deleted = deps.at_client:delete(message.index)
      if not deleted then return categorized("at") end
      local removed = deps.ledger:remove(message.index, fingerprint)
      if not removed then return categorized("ledger") end
      local saved = deps.ledger:save_atomic()
      if not saved then return categorized("ledger") end
    else
      local route_output = deps.route()
      local route_ok = deps.delivery.route_allowed(route_output, config.allowed_wan_device, deps.core)
      if not route_ok then return categorized("route") end

      local parts = deps.core.format_parts(message, config.telegram_limit or 4096)
      if not parts then return categorized("at") end
      local sent = deps.sender:send_parts(config.bot_token, config.chat_id, parts)
      if not sent then return categorized("telegram") end

      local added = deps.ledger:add(message.index, fingerprint)
      if not added then return categorized("ledger") end
      local saved = deps.ledger:save_atomic()
      if not saved then return categorized("ledger") end

      local deleted = deps.at_client:delete(message.index)
      if not deleted then return categorized("at") end
      local removed = deps.ledger:remove(message.index, fingerprint)
      if not removed then return categorized("ledger") end
      local removed_saved = deps.ledger:save_atomic()
      if not removed_saved then return categorized("ledger") end
    end
  end
  return true
end

function M.new(deps, config)
  return Worker.new(deps, config)
end

return M

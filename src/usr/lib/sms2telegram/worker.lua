local M = {}

local Worker = {}
Worker.__index = Worker

local function categorized(category, at_failed)
  return nil, category, at_failed
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
  if not messages then return categorized("at", true) end

  local first_error
  local at_failed = false
  for _, message in ipairs(messages) do
    local fingerprint = deps.delivery.fingerprint(message, nil, config.storage or "SM")
    if not fingerprint then
      first_error = first_error or "ledger"
    elseif deps.ledger:contains(message.index, fingerprint) then
      local deleted = deps.at_client:delete(message.index)
      if not deleted then
        first_error = first_error or "at"
        at_failed = true
        break
      else
        local removed = deps.ledger:remove(message.index, fingerprint)
        if not removed then
          first_error = first_error or "ledger"
        else
          local saved = deps.ledger:save_atomic()
          if not saved then first_error = first_error or "ledger" end
        end
      end
    elseif not first_error then
      local parts = deps.core.format_parts(message, config.telegram_limit or 4096)
      if not parts then
        first_error = "at"
      else
        for _, part in ipairs(parts) do
          local route_output = deps.route()
          local route_ok = deps.delivery.route_allowed(route_output, config.allowed_wan_device, deps.core)
          if not route_ok then
            first_error = "route"
            break
          end
          local sent = deps.sender:send_parts(config.bot_token, config.chat_id, { part })
          if not sent then
            first_error = "telegram"
            break
          end
        end
        if not first_error then
          local added = deps.ledger:add(message.index, fingerprint)
          if not added then
            first_error = "ledger"
          else
            local saved = deps.ledger:save_atomic()
            if not saved then
              first_error = "ledger"
            else
              local deleted = deps.at_client:delete(message.index)
              if not deleted then
                first_error = "at"
                at_failed = true
                break
              else
                local removed = deps.ledger:remove(message.index, fingerprint)
                if not removed then
                  first_error = "ledger"
                else
                  local removed_saved = deps.ledger:save_atomic()
                  if not removed_saved then first_error = "ledger" end
                end
              end
            end
          end
        end
      end
    end
  end
  if first_error then return categorized(first_error, at_failed) end
  return true
end

function M.new(deps, config)
  return Worker.new(deps, config)
end

return M

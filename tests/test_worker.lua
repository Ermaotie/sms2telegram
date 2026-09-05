local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local worker = dofile(root .. "/usr/lib/sms2telegram/worker.lua")

local digest_a = string.rep("a", 64)
local digest_b = string.rep("b", 64)

local function message(index, body)
  return { index = index, sender = "+8613800000000", timestamp = "26/09/05,14:30:00+32", body = body or "hello" }
end

local function fixture(options)
  options = options or {}
  local events, records = {}, options.records or {}
  local messages = options.messages or { message(7) }
  local deps = {
    core = {
      format_parts = function(item) return { item.body } end
    },
    delivery = {
      validate_credentials = function(token, chat_id)
        if token == "token" and chat_id == "chat" then return true end
        return nil, "invalid credentials"
      end,
      fingerprint = function(item) return item.body == "changed" and digest_b or digest_a end,
      route_allowed = function(output, allowed)
        if output == allowed then return true end
        return nil, "route blocked"
      end
    },
    at_client = {
      scan = function()
        events[#events + 1] = "scan"
        return messages
      end,
      delete = function(_, index)
        events[#events + 1] = "delete"
        if options.delete_fails or options.delete_fails_at == index then return nil, "delete failed" end
        return true
      end
    },
    sender = {
      send_parts = function(_, _, _, parts)
        events[#events + 1] = "send"
        if options.send_fails then return nil, "send failed" end
        return true
      end
    },
    ledger = {
      contains = function(_, index, digest) return records[tostring(index)] == digest end,
      add = function(_, index, digest)
        events[#events + 1] = "ledger-add"
        records[tostring(index)] = digest
        return true
      end,
      remove = function(_, index, digest)
        events[#events + 1] = "ledger-remove"
        if records[tostring(index)] ~= digest then return nil, "missing record" end
        records[tostring(index)] = nil
        return true
      end,
      save_atomic = function()
        events[#events + 1] = "ledger-save"
        return true
      end
    },
    route = function()
      events[#events + 1] = "route"
      return options.route or "eth0"
    end
  }
  return deps, events, records
end

local function cycle(options, config)
  local deps, events, records = fixture(options)
  local instance = worker.new(deps, config or {
    bot_token = "token", chat_id = "chat", allowed_wan_device = "eth0", telegram_limit = 4096
  })
  local ok, err, at_failed = instance:cycle()
  return ok, err, events, records, at_failed
end

-- Removing the early credential gate would expose the modem or confirmation state.
local empty_ok, empty_err, empty_events = cycle({}, { bot_token = "", chat_id = "" })
t.eq("missing credentials result", empty_ok, nil)
t.eq("missing credentials category", empty_err, "config")
t.eq("missing credentials have zero operations", #empty_events, 0)

-- Changing the route gate to accept eth2 would leak delivery onto the modem link.
local route_ok, route_err, route_events, route_records = cycle({ route = "eth2" })
t.eq("eth2 route result", route_ok, nil)
t.eq("eth2 route category", route_err, "route")
t.eq("eth2 route order", table.concat(route_events, ","), "scan,route")
t.eq("eth2 leaves ledger unchanged", route_records["7"], nil)

-- Marking after a failed Telegram request would make retries silently disappear.
local send_ok, send_err, send_events, send_records = cycle({ send_fails = true })
t.eq("Telegram failure result", send_ok, nil)
t.eq("Telegram failure category", send_err, "telegram")
t.eq("Telegram failure order", table.concat(send_events, ","), "scan,route,send")
t.eq("Telegram failure leaves ledger unchanged", send_records["7"], nil)

local success_ok, success_err, events = cycle()
t.eq("successful delivery result", success_ok, true)
t.eq("successful delivery error", success_err, nil)
t.eq("delivery order", table.concat(events, ","),
  "scan,route,send,ledger-add,ledger-save,delete,ledger-remove,ledger-save")

-- Removing a confirmation after a failed delete would cause a duplicate send.
local delete_ok, delete_err, delete_events, delete_records = cycle({ delete_fails = true })
t.eq("delete failure result", delete_ok, nil)
t.eq("delete failure category", delete_err, "at")
t.eq("delete failure keeps confirmation", delete_records["7"], digest_a)
t.eq("delete failure order", table.concat(delete_events, ","), "scan,route,send,ledger-add,ledger-save,delete")

local recover_ok, recover_err, recover_events, recover_records = cycle({ records = { ["7"] = digest_a } })
t.eq("matching ledger cleanup result", recover_ok, true)
t.eq("matching ledger cleanup error", recover_err, nil)
t.eq("matching ledger skips Telegram", table.concat(recover_events, ","), "scan,delete,ledger-remove,ledger-save")
t.eq("matching ledger cleanup removes record", recover_records["7"], nil)

local reuse_ok, reuse_err, reuse_events = cycle({ records = { ["7"] = digest_a }, messages = { message(7, "changed") } })
t.eq("reused index result", reuse_ok, true)
t.eq("reused index error", reuse_err, nil)
t.eq("reused index sends new fingerprint", table.concat(reuse_events, ","),
  "scan,route,send,ledger-add,ledger-save,delete,ledger-remove,ledger-save")

local cleanup_ok, cleanup_err, cleanup_events, cleanup_records = cycle({ records = { ["7"] = digest_a } })
t.eq("successful delete cleanup result", cleanup_ok, true)
t.eq("successful delete cleanup error", cleanup_err, nil)
t.eq("successful delete cleanup order", table.concat(cleanup_events, ","), "scan,delete,ledger-remove,ledger-save")
t.eq("successful delete removes ledger entry", cleanup_records["7"], nil)

-- A send failure must not undo independent cleanup of an already-confirmed record.
local mixed_ok, mixed_err, mixed_events, mixed_records = cycle({
  send_fails = true,
  records = { ["7"] = digest_a },
  messages = { message(7), message(8, "new") }
})
t.eq("mixed messages result", mixed_ok, nil)
t.eq("mixed messages category", mixed_err, "telegram")
t.eq("mixed messages order", table.concat(mixed_events, ","), "scan,delete,ledger-remove,ledger-save,route,send")
t.eq("mixed failed new record not confirmed", mixed_records["8"], nil)
t.eq("mixed confirmed record cleaned", mixed_records["7"], nil)

-- Returning at the first failed new record would strand later confirmed records.
local reverse_ok, reverse_err, reverse_events, reverse_records = cycle({
  send_fails = true,
  records = { ["8"] = digest_a },
  messages = { message(7, "new"), message(8), message(9, "changed") }
})
t.eq("reverse mixed result", reverse_ok, nil)
t.eq("reverse mixed category", reverse_err, "telegram")
t.eq("reverse mixed cleans only later confirmation", table.concat(reverse_events, ","),
  "scan,route,send,delete,ledger-remove,ledger-save")
t.eq("reverse failed new record is not confirmed", reverse_records["7"], nil)
t.eq("reverse later confirmation is removed", tostring(reverse_records["8"]), "nil")
t.eq("reverse later new record is not sent", reverse_records["9"], nil)

-- Once a delete loses AT synchronization, no later delete may touch that serial session.
local at_stop_ok, at_stop_err, at_stop_events, at_stop_records, at_stop_failed = cycle({
  send_fails = true,
  delete_fails_at = 8,
  records = { ["8"] = digest_a, ["9"] = digest_a },
  messages = { message(7, "new"), message(8), message(9) }
})
t.eq("AT stop preserves primary Telegram error", at_stop_ok, nil)
t.eq("AT stop primary category", at_stop_err, "telegram")
t.eq("AT stop reports reconnect signal", tostring(at_stop_failed), "true")
t.eq("AT stop has no later serial delete", table.concat(at_stop_events, ","), "scan,route,send,delete")
t.eq("AT stop keeps failed confirmation", at_stop_records["8"], digest_a)
t.eq("AT stop keeps later confirmation", tostring(at_stop_records["9"]), digest_a)

local function quote(value)
  return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function shell_status(command)
  local a, _, c = os.execute(command)
  if type(a) == "number" then return a end
  if a then return 0 end
  return c or 1
end

local function write_file(path, contents)
  local file = assert(io.open(path, "wb"))
  assert(file:write(contents))
  assert(file:close())
end

local process_number = 0
local function process_temp()
  process_number = process_number + 1
  return "/tmp/sms2telegram-worker-process-" .. tostring(os.time()) .. "-" .. tostring(process_number)
end

local function copy_runtime(temp)
  assert(shell_status("mkdir -p " .. quote(temp .. "/lib") .. " " .. quote(temp .. "/bin")) == 0)
  assert(shell_status("cp " .. quote(root .. "/usr/lib/sms2telegram/core.lua") .. " " .. quote(temp .. "/lib/core.lua")) == 0)
  assert(shell_status("cp " .. quote(root .. "/usr/lib/sms2telegram/delivery.lua") .. " " .. quote(temp .. "/lib/delivery.lua")) == 0)
  assert(shell_status("cp " .. quote(root .. "/usr/lib/sms2telegram/worker.lua") .. " " .. quote(temp .. "/lib/worker.lua")) == 0)
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return "" end
  local value = file:read("*a")
  file:close()
  return value
end

local function install_uci(temp, missing)
  write_file(temp .. "/bin/uci", [[#!/bin/sh
key="$3"
if [ -e "$SMS2TELEGRAM_UCI_STATE" ]; then changed=yes; else changed=; fi
case "$key" in
  sms2telegram.main.device) if [ "$changed" ]; then printf '/dev/second\n'; else printf '/dev/first\n'; fi ;;
  sms2telegram.main.storage) if [ "$changed" ]; then printf 'ME\n'; else printf 'SM\n'; fi ;;
  sms2telegram.main.bot_token) [ "$SMS2TELEGRAM_MISSING" = bot_token ] || printf '123456:Abc_def-XYZ\n' ;;
  sms2telegram.main.chat_id) [ "$SMS2TELEGRAM_MISSING" = chat_id ] || printf '%s\n' '-1001234567890' ;;
  sms2telegram.main.allowed_wan_device) printf 'eth0\n' ;;
  sms2telegram.main.poll_interval|sms2telegram.main.retry_initial|sms2telegram.main.retry_max) printf '1\n' ;;
esac
]])
  assert(shell_status("chmod 700 " .. quote(temp .. "/bin/uci")) == 0)
end

local function run_daemon(temp, extra, seconds)
  local process_command = "PATH=" .. quote(temp .. "/bin") .. ":$PATH " ..
    "SMS2TELEGRAM_LIBDIR=" .. quote(temp .. "/lib") .. " " .. extra .. " " ..
    quote(root .. "/usr/sbin/sms2telegram") ..
    " >/dev/null 2>&1 & child=$!; sleep " .. tostring(seconds or 2) .. "; kill -0 $child; alive=$?; kill $child 2>/dev/null; wait $child 2>/dev/null; exit $alive"
  return shell_status("sh -c " .. quote(process_command))
end

-- An early AT open would append to this fake; each blank credential is checked independently.
for _, missing in ipairs({ "bot_token", "chat_id" }) do
  local temp = process_temp()
  copy_runtime(temp)
  install_uci(temp)
  write_file(temp .. "/lib/at.lua", [[local M = { Client = {} }
function M.open_nixio_transport()
  local log = assert(io.open(os.getenv("SMS2TELEGRAM_AT_LOG"), "ab"))
  log:write("open\n")
  log:close()
  return nil, "should not open"
end
return M
]])
  local at_log = temp .. "/at.log"
  local extra = "SMS2TELEGRAM_MISSING=" .. missing .. " SMS2TELEGRAM_AT_LOG=" .. quote(at_log)
  t.eq("empty " .. missing .. " daemon stays alive", run_daemon(temp, extra), 0)
  t.eq("empty " .. missing .. " makes zero AT opens", read_file(at_log), "")
  shell_status("rm -rf " .. quote(temp))
end

-- Replacing the daemon's PID wiring with an empty value makes Sender reject its temporary paths before curl.
do
  local temp = process_temp()
  copy_runtime(temp)
  install_uci(temp)
  write_file(temp .. "/lib/at.lua", [[local M = { Client = {} }
local stored = true
local function append(value)
  local file = assert(io.open(os.getenv("SMS2TELEGRAM_AT_LOG"), "ab"))
  file:write(value .. "\n")
  file:close()
end
function M.open_nixio_transport()
  append("open")
  return {}
end
function M.Client.new(transport)
  return {
    transport = transport,
    initialize = function() append("init"); return true end,
    scan = function()
      if not stored then return {} end
      return { { index = 7, sender = "+8613800000000", timestamp = "26/09/05,14:30:00+32", body = "test" } }
    end,
    delete = function() stored = false; append("delete"); return true end,
    wait_for_cmti = function() require("nixio").nanosleep(1); return false end
  }
end
return M
]])
  write_file(temp .. "/bin/ip", "#!/bin/sh\nprintf '1.1.1.1 dev eth0\\n'\n")
  write_file(temp .. "/bin/curl", [[#!/bin/sh
while [ "$1" ]; do
  if [ "$1" = --output ]; then output="$2"; shift 2; else shift; fi
done
printf '{"ok":true}' > "$output"
printf 'send\n' >> "$SMS2TELEGRAM_SEND_LOG"
printf 200
]])
  write_file(temp .. "/bin/jsonfilter", "#!/bin/sh\nprintf 'true\\n'\n")
  assert(shell_status("chmod 700 " .. quote(temp .. "/bin/ip") .. " " .. quote(temp .. "/bin/curl") .. " " .. quote(temp .. "/bin/jsonfilter")) == 0)
  local at_log, send_log = temp .. "/at.log", temp .. "/send.log"
  local extra = "SMS2TELEGRAM_AT_LOG=" .. quote(at_log) .. " SMS2TELEGRAM_SEND_LOG=" .. quote(send_log) ..
    " SMS2TELEGRAM_LEDGER_PATH=" .. quote(temp .. "/delivered")
  t.eq("production sender process stays alive", run_daemon(temp, extra), 0)
  t.eq("production Sender reaches fake curl", read_file(send_log), "send\n")
  t.eq("production Sender deletes after fake success", tostring(read_file(at_log):find("delete\n", 1, true) ~= nil), "true")
  shell_status("rm -rf " .. quote(temp))
end

-- Keeping the old connected device/storage after UCI changes uses stale modem settings.
do
  local temp = process_temp()
  copy_runtime(temp)
  install_uci(temp)
  write_file(temp .. "/lib/at.lua", [[local M = { Client = {} }
local function append(value)
  local file = assert(io.open(os.getenv("SMS2TELEGRAM_AT_LOG"), "ab"))
  file:write(value .. "\n")
  file:close()
end
function M.open_nixio_transport(device)
  append("open:" .. device)
  return { close = function() append("close") end }
end
function M.Client.new(transport, _, options)
  return {
    transport = transport,
    initialize = function() append("init:" .. options.storage); return true end,
    scan = function() return {} end,
    wait_for_cmti = function() require("nixio").nanosleep(1); return false end
  }
end
return M
]])
  local at_log, state = temp .. "/at.log", temp .. "/changed"
  local extra = "SMS2TELEGRAM_AT_LOG=" .. quote(at_log) .. " SMS2TELEGRAM_LEDGER_PATH=" .. quote(temp .. "/delivered") ..
    " SMS2TELEGRAM_UCI_STATE=" .. quote(state)
  local process_command = "PATH=" .. quote(temp .. "/bin") .. ":$PATH SMS2TELEGRAM_LIBDIR=" .. quote(temp .. "/lib") .. " " .. extra .. " " ..
    quote(root .. "/usr/sbin/sms2telegram") ..
    " >/dev/null 2>&1 & child=$!; sleep 1; : > " .. quote(state) .. "; sleep 2; kill -0 $child; alive=$?; kill $child 2>/dev/null; wait $child 2>/dev/null; exit $alive"
  t.eq("hot-reload daemon stays alive", shell_status("sh -c " .. quote(process_command)), 0)
  t.eq("hot-reload reopens changed device and storage", read_file(at_log),
    "open:/dev/first\ninit:SM\nclose\nopen:/dev/second\ninit:ME\n")
  shell_status("rm -rf " .. quote(temp))
end

-- A Telegram primary error must still recreate the client when the worker reports AT failure.
do
  local temp = process_temp()
  copy_runtime(temp)
  install_uci(temp)
  write_file(temp .. "/lib/worker.lua", [[local M = {}
local failed = false
function M.new()
  return { cycle = function()
    if not failed then failed = true; return nil, "telegram", true end
    return nil, "telegram", false
  end }
end
return M
]])
  write_file(temp .. "/lib/at.lua", [[local M = { Client = {} }
local function append(value)
  local file = assert(io.open(os.getenv("SMS2TELEGRAM_AT_LOG"), "ab"))
  file:write(value .. "\n")
  file:close()
end
function M.open_nixio_transport()
  append("open")
  return { close = function() append("close") end }
end
function M.Client.new(transport)
  return { transport = transport, initialize = function() append("init"); return true end }
end
return M
]])
  local at_log = temp .. "/at.log"
  local extra = "SMS2TELEGRAM_AT_LOG=" .. quote(at_log) .. " SMS2TELEGRAM_LEDGER_PATH=" .. quote(temp .. "/delivered")
  t.eq("AT reconnect daemon stays alive", run_daemon(temp, extra, 3), 0)
  t.eq("AT reconnect closes and rebuilds after Telegram primary error", read_file(at_log),
    "open\ninit\nclose\nopen\ninit\n")
  shell_status("rm -rf " .. quote(temp))
end

t.finish()

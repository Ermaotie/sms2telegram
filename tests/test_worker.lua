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
  local order = options.order or {}
  if #order == 0 then
    for index in pairs(records) do order[#order + 1] = tostring(index) end
    table.sort(order, function(left, right) return tonumber(left) < tonumber(right) end)
  end
  local messages = options.messages or { message(7) }
  local deps = {
    core = {
      format_parts = function(item) return options.parts or { item.body } end
    },
    delivery = {
      validate_credentials = function(token, chat_id)
        if token == "token" and chat_id == "chat" then return true end
        return nil, "invalid credentials"
      end,
      fingerprint = function(item, _, storage)
        if options.capture_storage then options.capture_storage(storage) end
        return item.body == "changed" and digest_b or digest_a
      end,
      route_allowed = function(output, allowed)
        if output == allowed then return true end
        return nil, "route blocked"
      end
    },
    at_client = {
      scan = function()
        events[#events + 1] = "scan"
        return messages, nil, options.rejected
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
        index = tostring(index)
        for position = #order, 1, -1 do
          if order[position] == index then table.remove(order, position) end
        end
        records[index] = digest
        order[#order + 1] = index
        return true
      end,
      remove = function(_, index, digest)
        events[#events + 1] = "ledger-remove"
        if records[tostring(index)] ~= digest then return nil, "missing record" end
        index = tostring(index)
        records[index] = nil
        for position = #order, 1, -1 do
          if order[position] == index then table.remove(order, position) end
        end
        return true
      end,
      ordered_matching = function(_, candidates)
        local matching = {}
        for _, index in ipairs(order) do
          if records[index] and candidates[index] == records[index] then
            matching[#matching + 1] = { index = index, digest = records[index] }
          end
        end
        return matching
      end,
      save_atomic = function()
        events[#events + 1] = "ledger-save"
        return true
      end
    },
    route = function()
      events[#events + 1] = "route"
      if options.routes then return table.remove(options.routes, 1) end
      return options.route or "eth0"
    end
  }
  return deps, events, records
end

local function cycle(options, config)
  local deps, events, records = fixture(options)
  local instance = worker.new(deps, config or {
    bot_token = "token", chat_id = "chat", allowed_wan_device = "eth0",
    telegram_limit = 4096, retain_count = 3
  })
  local ok, err, at_failed, rejected = instance:cycle()
  return ok, err, events, records, at_failed, rejected
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
  "scan,route,send,ledger-add,ledger-save")

local zero_ok, zero_err, zero_events, zero_records = cycle({}, {
  bot_token = "token", chat_id = "chat", allowed_wan_device = "eth0",
  telegram_limit = 4096, retain_count = 0
})
t.eq("zero retention delivery result", zero_ok, true)
t.eq("zero retention delivery error", zero_err, nil)
t.eq("zero retention deletes after confirmation", table.concat(zero_events, ","),
  "scan,route,send,ledger-add,ledger-save,delete,ledger-remove,ledger-save")
t.eq("zero retention clears confirmation", zero_records["7"], nil)

local invalid_retain_ok, invalid_retain_err, invalid_retain_events = cycle({}, {
  bot_token = "token", chat_id = "chat", allowed_wan_device = "eth0", retain_count = -1
})
t.eq("invalid retention result", invalid_retain_ok, nil)
t.eq("invalid retention category", invalid_retain_err, "config")
t.eq("invalid retention has zero operations", #invalid_retain_events, 0)

local multipart_ok, multipart_err, multipart_events, multipart_records = cycle({
  parts = { "first", "second" }, routes = { "eth0", "eth2" }
})
t.eq("multipart changed route retains SMS", multipart_ok, nil)
t.eq("multipart changed route error category", multipart_err, "route")
t.eq("multipart checks each send and stops on eth2", table.concat(multipart_events, ","), "scan,route,send,route")
t.eq("multipart route failure persists no confirmation", multipart_records["7"], nil)
local observed_storage
cycle({ capture_storage = function(value) observed_storage = value end }, {
  bot_token = "token", chat_id = "chat", allowed_wan_device = "eth0", storage = "ME"
})
t.eq("worker fingerprints configured storage", observed_storage, "ME")

local real_core = dofile(root .. "/usr/lib/sms2telegram/core.lua")
local incoming_only = assert(real_core.parse_cmgl(table.concat({
  '+CMGL: 1,"STO UNSENT","+8613800000000",', '0061',
  '+CMGL: 2,"STO SENT","+8613800000000",', '0062',
  '+CMGL: 3,"REC READ",6,42,"+8613800000000",145,"26/09/05,14:30:00+32","26/09/05,14:31:00+32",0',
  '+CMGL: 4,"REC UNREAD","+8613800000000",,"26/09/05,14:32:00+32"', '004F004B', 'OK', ''
}, '\r\n')))
local incoming_ok, _, incoming_events = cycle({ messages = incoming_only })
t.eq("mixed records deliver successfully", incoming_ok, true)
t.eq("outgoing and report have no worker send or delete", table.concat(incoming_events, ","),
  "scan,route,send,ledger-add,ledger-save")

local partial_messages, _, rejected_records = real_core.parse_cmgl(table.concat({
  "+CMGL: 5,1,,23",
  "000407D049A7F109002062311021000023068542A1502800",
  "+CMGL: 7,0,,20",
  "00000491214300006290601250002305E8329BFD06", "OK", ""
}, "\r\n"))
local partial_ok, partial_err, partial_events, partial_records, partial_at_failed, partial_rejected = cycle({
  messages = assert(partial_messages), rejected = rejected_records,
  records = { ["5"] = digest_a }
}, { bot_token = "token", chat_id = "chat", allowed_wan_device = "eth0", retain_count = 0 })
t.eq("partial decode still forwards good SMS", partial_ok, true)
t.eq("partial decode has no delivery error", partial_err, nil)
t.eq("partial decode does not reconnect modem", partial_at_failed, false)
t.eq("partial decode surfaces bad slot", partial_rejected[1].index, 5)
t.eq("partial decode never confirms or removes rejected slot", partial_records["5"], digest_a)
t.eq("only good SMS is sent and pruned with retention zero", table.concat(partial_events, ","),
  "scan,route,send,ledger-add,ledger-save,delete,ledger-remove,ledger-save")
local all_bad_ok, _, all_bad_events, _, all_bad_at_failed, all_bad_rejected = cycle({
  messages = {}, rejected = rejected_records
})
t.eq("all bad records do not break worker", all_bad_ok, true)
t.eq("all bad records never send or delete", table.concat(all_bad_events, ","), "scan")
t.eq("all bad records do not reconnect", all_bad_at_failed, false)
t.eq("all bad records surface count", #all_bad_rejected, 1)

local recover_ok, recover_err, recover_events, recover_records = cycle({ records = { ["7"] = digest_a } })
t.eq("matching retained result", recover_ok, true)
t.eq("matching retained error", recover_err, nil)
t.eq("matching retained skips Telegram and delete", table.concat(recover_events, ","), "scan")
t.eq("matching retained keeps record", recover_records["7"], digest_a)

local reuse_ok, reuse_err, reuse_events = cycle({ records = { ["7"] = digest_a }, messages = { message(7, "changed") } })
t.eq("reused index result", reuse_ok, true)
t.eq("reused index error", reuse_err, nil)
t.eq("reused index sends new fingerprint", table.concat(reuse_events, ","),
  "scan,route,send,ledger-add,ledger-save")

-- A send failure must not remove any of the three retained confirmations.
local mixed_ok, mixed_err, mixed_events, mixed_records = cycle({
  send_fails = true,
  records = { ["7"] = digest_a },
  messages = { message(7), message(8, "new") }
})
t.eq("mixed messages result", mixed_ok, nil)
t.eq("mixed messages category", mixed_err, "telegram")
t.eq("mixed messages order", table.concat(mixed_events, ","), "scan,route,send")
t.eq("mixed failed new record not confirmed", mixed_records["8"], nil)
t.eq("mixed confirmed record retained", mixed_records["7"], digest_a)

-- A failed new record does not disturb later retained records.
local reverse_ok, reverse_err, reverse_events, reverse_records = cycle({
  send_fails = true,
  records = { ["8"] = digest_a },
  messages = { message(7, "new"), message(8), message(9, "changed") }
})
t.eq("reverse mixed result", reverse_ok, nil)
t.eq("reverse mixed category", reverse_err, "telegram")
t.eq("reverse mixed leaves later confirmation retained", table.concat(reverse_events, ","),
  "scan,route,send")
t.eq("reverse failed new record is not confirmed", reverse_records["7"], nil)
t.eq("reverse later confirmation is retained", tostring(reverse_records["8"]), digest_a)
t.eq("reverse later new record is not sent", reverse_records["9"], nil)

-- The fourth confirmed SMS prunes the oldest one, never one chosen by slot number.
local prune_ok, prune_err, prune_events, prune_records = cycle({
  records = { ["8"] = digest_a, ["9"] = digest_a, ["2"] = digest_a },
  order = { "8", "9", "2" },
  messages = { message(8), message(9), message(2), message(1, "changed") }
})
t.eq("fourth SMS delivery succeeds", prune_ok, true)
t.eq("fourth SMS delivery error", prune_err, nil)
t.eq("fourth SMS sends then deletes oldest", table.concat(prune_events, ","),
  "scan,route,send,ledger-add,ledger-save,delete,ledger-remove,ledger-save")
t.eq("oldest retained record removed", prune_records["8"], nil)
t.eq("new reused low slot retained", prune_records["1"], digest_b)

-- Once a pruning delete loses AT synchronization, no later delete may touch that serial session.
local at_stop_ok, at_stop_err, at_stop_events, at_stop_records, at_stop_failed = cycle({
  delete_fails_at = "8",
  records = { ["8"] = digest_a, ["9"] = digest_a, ["2"] = digest_a },
  order = { "8", "9", "2" },
  messages = { message(8), message(9), message(2), message(1, "changed") }
})
t.eq("AT stop result", at_stop_ok, nil)
t.eq("AT stop category", at_stop_err, "at")
t.eq("AT stop reports reconnect signal", tostring(at_stop_failed), "true")
t.eq("AT stop has no later serial delete", table.concat(at_stop_events, ","),
  "scan,route,send,ledger-add,ledger-save,delete")
t.eq("AT stop keeps failed oldest confirmation", at_stop_records["8"], digest_a)
t.eq("AT stop keeps new confirmation", at_stop_records["1"], digest_b)

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
  assert(shell_status("cp " .. quote(root .. "/usr/lib/sms2telegram/status.lua") .. " " .. quote(temp .. "/lib/status.lua")) == 0)
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
  sms2telegram.main.poll_interval) printf '%s\n' "${SMS2TELEGRAM_TEST_POLL_INTERVAL:-1}" ;;
  sms2telegram.main.retry_initial|sms2telegram.main.retry_max) printf '%s\n' "${SMS2TELEGRAM_TEST_RETRY:-1}" ;;
esac
]])
  assert(shell_status("chmod 700 " .. quote(temp .. "/bin/uci")) == 0)
end

local function run_daemon(temp, extra, seconds)
  local process_command = "PATH=" .. quote(temp .. "/bin") .. ":$PATH " ..
    "SMS2TELEGRAM_LIBDIR=" .. quote(temp .. "/lib") .. " SMS2TELEGRAM_LEDGER_PATH=" .. quote(temp .. "/state/delivered") ..
    " SMS2TELEGRAM_STATUS_DISABLED=1 " .. extra .. " " ..
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

-- A delivered SMS is retained across daemon restarts without being sent twice.
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
    delete = function()
      append("delete")
      if os.getenv("SMS2TELEGRAM_DELETE_FAILS") == "1" then return nil, "delete failed" end
      stored = false; return true
    end,
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
    " SMS2TELEGRAM_LEDGER_PATH=" .. quote(temp .. "/state/delivered")
  t.eq("first-start sender stays alive", run_daemon(temp, extra), 0)
  t.eq("production Sender reaches fake curl", read_file(send_log), "send\n")
  t.eq("one retained SMS is not deleted", read_file(at_log):find("delete\n", 1, true), nil)
  t.truthy("retained confirmation survives on disk", read_file(temp .. "/state/delivered"):match("^7\t"))
  write_file(at_log, "")
  t.eq("restarted daemon stays alive", run_daemon(temp, extra), 0)
  t.eq("restart recovers without another send", read_file(send_log), "send\n")
  t.eq("restart keeps retained SMS without deletion", read_file(at_log):find("delete\n", 1, true), nil)
  t.truthy("restart keeps persisted confirmation", read_file(temp .. "/state/delivered"):match("^7\t"))
  write_file(temp .. "/blocked-parent", "file")
  write_file(send_log, "")
  write_file(at_log, "")
  t.eq("unusable ledger parent keeps daemon alive", run_daemon(temp,
    extra .. " SMS2TELEGRAM_LEDGER_PATH=" .. quote(temp .. "/blocked-parent/delivered")), 0)
  t.eq("unusable ledger parent prevents send", read_file(send_log), "")
  t.eq("unusable ledger parent prevents delete", read_file(at_log):find("delete\n", 1, true), nil)
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
  local process_command = "PATH=" .. quote(temp .. "/bin") .. ":$PATH SMS2TELEGRAM_LIBDIR=" .. quote(temp .. "/lib") ..
    " SMS2TELEGRAM_STATUS_DISABLED=1 " .. extra .. " " ..
    quote(root .. "/usr/sbin/sms2telegram") ..
    " >/dev/null 2>&1 & child=$!; sleep 1; : > " .. quote(state) ..
    "; attempt=0; while ! grep -q 'init:ME' " .. quote(at_log) ..
    " 2>/dev/null && [ $attempt -lt 6 ]; do sleep 1; attempt=$((attempt + 1)); done" ..
    "; kill -0 $child; alive=$?; kill $child 2>/dev/null; wait $child 2>/dev/null; exit $alive"
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

-- Undecodable records keep the modem connected, normal polling, and honest status.
do
  local temp = process_temp()
  copy_runtime(temp)
  install_uci(temp)
  write_file(temp .. "/lib/at.lua", [[local M = { Client = {} }
function M.open_nixio_transport()
  local file = assert(io.open(os.getenv("SMS2TELEGRAM_AT_LOG"), "ab"))
  file:write("open\n"); file:close()
  return {}
end
function M.Client.new(transport)
  return {
    transport = transport, initialize = function() return true end,
    scan = function() return {}, nil, { { index = 5, error = "empty PDU body", raw_pdu = "00AB" } } end,
    signal_quality = function() return 22, 0 end,
    wait_for_cmti = function() require("nixio").nanosleep(1); return false end
  }
end
return M
]])
  write_file(temp .. "/lib/status.lua", [[local M = { OffsetStore = {}, Bot = {} }
function M.offset_path(path) return path .. ".123456", "123456" end
function M.OffsetStore.new() return {} end
function M.Bot.new()
  return { poll = function(_, _, snapshot)
    local file = assert(io.open(os.getenv("SMS2TELEGRAM_STATUS_LOG"), "ab"))
    file:write(tostring(snapshot.modem_connected) .. ":" .. tostring(snapshot.signal_rssi) ..
      ":" .. tostring(snapshot.last_scan_ok) .. ":" .. snapshot.last_scan .. "\n")
    file:close(); return true
  end }
end
return M
]])
  local at_log, status_log = temp .. "/at.log", temp .. "/status.log"
  write_file(temp .. "/bin/ip", "#!/bin/sh\nprintf '1.1.1.1 dev eth0\\n'\n")
  write_file(temp .. "/bin/curl", [[#!/bin/sh
while [ "$1" ]; do
  if [ "$1" = --output ]; then output="$2"; shift 2; else shift; fi
done
printf '{"ok":true}' > "$output"
printf 'alert\n' >> "$SMS2TELEGRAM_SEND_LOG"
printf 200
]])
  write_file(temp .. "/bin/jsonfilter", "#!/bin/sh\nprintf 'true\\n'\n")
  assert(shell_status("chmod 700 " .. quote(temp .. "/bin/ip") .. " " .. quote(temp .. "/bin/curl") .. " " .. quote(temp .. "/bin/jsonfilter")) == 0)
  local send_log = temp .. "/send.log"
  local extra = "SMS2TELEGRAM_AT_LOG=" .. quote(at_log) ..
    " SMS2TELEGRAM_STATUS_LOG=" .. quote(status_log) .. " SMS2TELEGRAM_STATUS_DISABLED=0" ..
    " SMS2TELEGRAM_SEND_LOG=" .. quote(send_log)
  t.eq("partial decode daemon stays alive", run_daemon(temp, extra, 3), 0)
  t.eq("partial decode never reopens modem", read_file(at_log), "open\n")
  local _, count = read_file(status_log):gsub(
    "true:22:false:已保留 1 条无法解析短信，其他短信正常处理", "")
  t.truthy("partial decode keeps polling with signal and warning", count >= 2)
  t.eq("daemon reports anomaly only once", read_file(send_log), "alert\n")
  t.truthy("anomaly confirmation persisted separately", read_file(temp .. "/state/delivered.alerts"):match("^5\t"))
  t.eq("daemon restart succeeds with retained anomaly", run_daemon(temp, extra, 2), 0)
  t.eq("daemon restart does not repeat anomaly report", read_file(send_log), "alert\n")
  shell_status("rm -rf " .. quote(temp))
end

-- A status request must still be processed while the modem is unavailable.
do
  local temp = process_temp()
  copy_runtime(temp)
  install_uci(temp)
  write_file(temp .. "/lib/at.lua", [[local M = { Client = {} }
function M.open_nixio_transport() return nil, "modem unavailable" end
return M
]])
  write_file(temp .. "/lib/status.lua", [[local M = { OffsetStore = {}, Bot = {} }
function M.offset_path(path) return path .. ".123456", "123456" end
function M.OffsetStore.new() return {} end
function M.Bot.new()
  return { poll = function(_, _, snapshot)
    local file = assert(io.open(os.getenv("SMS2TELEGRAM_STATUS_LOG"), "ab"))
    file:write("poll:" .. tostring(snapshot.modem_connected) .. "\n")
    file:close()
    return true
  end }
end
return M
]])
  local status_log = temp .. "/status.log"
  local extra = "SMS2TELEGRAM_STATUS_LOG=" .. quote(status_log) ..
    " SMS2TELEGRAM_STATUS_DISABLED=0" ..
    " SMS2TELEGRAM_TEST_POLL_INTERVAL=1 SMS2TELEGRAM_TEST_RETRY=30" ..
    " SMS2TELEGRAM_LEDGER_PATH=" .. quote(temp .. "/state/delivered") ..
    " SMS2TELEGRAM_UPDATE_OFFSET_PATH=" .. quote(temp .. "/state/update_offset")
  t.eq("daemon with unavailable modem stays alive", run_daemon(temp, extra, 3), 0)
  local _, status_poll_count = read_file(status_log):gsub("poll:false", "")
  t.truthy("status polling continues during long modem backoff", status_poll_count >= 2)
  shell_status("rm -rf " .. quote(temp))
end

t.finish()

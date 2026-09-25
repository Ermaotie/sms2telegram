local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local core = dofile(root .. "/usr/lib/sms2telegram/core.lua")
local delivery = dofile(root .. "/usr/lib/sms2telegram/delivery.lua")
local worker = dofile(root .. "/usr/lib/sms2telegram/worker.lua")
local nixio = require "nixio"
local directory = "/tmp/sms2telegram-report-test-" .. nixio.getpid()
assert(nixio.fs.mkdir(directory))
assert(os.execute("chmod 700 " .. directory) == 0)
local path = directory .. "/alerts"
local record = { index = 5, error = "empty PDU body", raw_pdu = "00AB", sender = "INFO" }
local other = { index = 5, error = "empty PDU body", raw_pdu = "00AC" }
local sends, routes, deletes, fail_send = 0, 0, 0, false
local device = "eth0"
local config = { bot_token = "123456:Abc_def-XYZ", chat_id = "-1001234567890",
  allowed_wan_device = "eth0", storage = "SM" }
local deps = {
  core = core, delivery = delivery, ledger = {},
  at_client = { delete = function() deletes = deletes + 1 end },
  route = function() routes = routes + 1; return "1.1.1.1 dev " .. device end,
  sender = { send_parts = function(_, _, _, parts)
    sends = sends + 1
    t.truthy("report has warning title", parts[1]:match("^⚠️"))
    t.eq("raw PDU absent from report", parts[1]:find(record.raw_pdu, 1, true), nil)
    if fail_send then return nil, "failed" end
    return true
  end }
}
local instance = worker.new(deps, config)
local ledger = assert(delivery.Ledger.new(path))
t.eq("first anomaly sends report", instance:report_rejected({record}, ledger), true)
t.eq("first anomaly one send", sends, 1)
t.eq("alert file private", tostring(nixio.fs.stat(path).modedec), "600")
t.eq("repeated scan suppresses report", instance:report_rejected({record}, ledger), true)
t.eq("repeated scan has no extra send", sends, 1)
ledger = assert(delivery.Ledger.new(path))
t.eq("restart suppresses report", worker.new(deps, config):report_rejected({record}, ledger), true)
t.eq("restart has no extra send", sends, 1)
local changed_reason = { index = 5, error = "different decoder error", raw_pdu = "00ab" }
t.eq("reason and hex case do not create duplicates", instance:report_rejected({changed_reason}, ledger), true)
t.eq("same raw bytes still one send", sends, 1)
t.eq("reused slot different data sends", instance:report_rejected({other}, ledger), true)
t.eq("reused slot adds one send", sends, 2)
t.eq("alert never deletes original SMS", deletes, 0)

local third = { index = 6, error = "empty PDU body", raw_pdu = "0011" }
device = "eth2"
local blocked, blocked_error = instance:report_rejected({third}, ledger)
t.eq("SIM route blocks alert", blocked, nil)
t.eq("SIM route alert category", blocked_error, "route")
t.eq("SIM route makes no Telegram request", sends, 2)
t.eq("SIM route does not confirm alert", ledger:contains(6, assert(delivery.rejection_fingerprint(third, "SM"))), false)
device, fail_send = "eth0", true
local failed, failure = instance:report_rejected({third}, ledger)
t.eq("send failure reported", failed, nil)
t.eq("send failure category", failure, "telegram")
t.eq("send failure is unconfirmed", ledger:contains(6, assert(delivery.rejection_fingerprint(third, "SM"))), false)
fail_send = false
t.eq("failed alert can retry", instance:report_rejected({third}, assert(delivery.Ledger.new(path))), true)
t.eq("send attempts include retry", sends, 4)
local before_routes = routes
t.eq("unavailable ledger fails without network", instance:report_rejected({third}, nil), nil)
t.eq("ledger failure does not check network", routes, before_routes)
t.eq("empty rejection set needs no ledger", instance:report_rejected({}, nil), true)
t.eq("invalid raw payload is not reportable", instance:report_rejected({{index=7, raw_pdu="not hex"}}, ledger), nil)
t.eq("bad payload has no extra send", sends, 4)
local failed_store = {
  contains = function() return false end,
  add = function() return true end,
  save_atomic = function() return nil, "full" end
}
local saved, save_error = instance:report_rejected({third}, failed_store)
t.eq("failed persistence is not success", saved, nil)
t.eq("failed persistence category", save_error, "ledger")
t.eq("no alert path ever deletes SMS", deletes, 0)
os.remove(path)
os.remove(path .. ".tmp")
assert(nixio.fs.rmdir(directory))
t.finish()

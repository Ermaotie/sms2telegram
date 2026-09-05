# SMS to Telegram IPK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a tested `sms2telegram_1.0.0_all.ipk` that forwards Air780EPV SMS messages to Telegram through the router's `eth0`/OpenClash path and starts automatically with OpenWrt.

**Architecture:** A Lua 5.1 daemon owns `/dev/ttyACM0`, stores incoming messages on `SM`, scans all stored messages, and treats the modem as the persistent pending queue. Focused Lua modules handle pure parsing/formatting, AT transport, Telegram delivery and the confirmed-delivery ledger; `procd` manages lifecycle and a deterministic shell builder assembles the architecture-independent IPK.

**Tech Stack:** Lua 5.1, `nixio`, OpenWrt `procd` and UCI CLI, curl, `jsonfilter`, POSIX shell, `ar`, `tar`, `gzip`.

**Spec:** `docs/superpowers/specs/2026-09-05-sms-to-telegram-design.md`

## Global Constraints

- Verified target is ImmortalWrt 24.10.5 on FriendlyElec NanoPi R2S.
- Modem is Air780EPV on `/dev/ttyACM0`; RNDIS/SIM-data device is `eth2`.
- Telegram delivery is permitted only when `ip -4 route get 1.1.1.1` selects exactly `eth0` by default.
- Do not bind curl to `eth0`; router-local traffic must remain eligible for OpenClash transparent interception.
- Never read or delete stored SMS while Bot Token or Chat ID is empty.
- Delete an SMS with `AT+CMGD=<index>` only after Telegram HTTP and JSON success for every part.
- SMS body is first; sender and timestamp metadata follow it.
- The service provides at-least-once delivery and survives router/service restart.
- Bot Token and complete SMS body must never appear in logs.
- The final package is not installed and no live Telegram message is sent without separate user authorization.

## File Map

- `src/usr/lib/sms2telegram/core.lua`: pure CSV, CMGL, UCS2, UTF-8, formatting, splitting, route and retry functions.
- `src/usr/lib/sms2telegram/at.lua`: bounded AT commands, modem initialization, scans, deletes and `+CMTI` event handling.
- `src/usr/lib/sms2telegram/delivery.lua`: credential validation, curl execution, Telegram result validation, fingerprints and atomic ledger persistence.
- `src/usr/lib/sms2telegram/worker.lua`: configuration gate and one-cycle delivery orchestration.
- `src/usr/sbin/sms2telegram`: production dependency wiring and long-running loop.
- `src/etc/init.d/sms2telegram`: `procd` lifecycle and respawn.
- `src/etc/config/sms2telegram`: root-only UCI defaults.
- `src/usr/share/doc/sms2telegram/README.zh-CN.md`: Chinese operator guide.
- `ipk/control/*`: package metadata, conffile declaration and lifecycle scripts.
- `scripts/build-ipk.sh`: reproducible IPK assembly.
- `tests/testlib.lua`: minimal Lua 5.1 test helpers.
- `tests/test_core.lua`: pure behavior coverage.
- `tests/test_at.lua`: fake-transport AT behavior coverage.
- `tests/test_delivery.lua`: fake-command delivery and real temporary-ledger coverage.
- `tests/test_worker.lua`: end-to-end orchestration with controlled adapters.
- `tests/test_package.sh`: archive metadata, paths, permissions and script checks.
- `tests/router-smoke.sh`: non-destructive target capability checks.

---

### Task 1: Establish the Lua Test Harness and Unicode Primitives

**Files:**
- Create: `tests/testlib.lua`
- Create: `tests/test_core.lua`
- Create: `src/usr/lib/sms2telegram/core.lua`

**Interfaces:**
- Produces: `core.ucs2_to_utf8(hex) -> string|nil,error`
- Produces: `core.utf8_length(text) -> integer`
- Produces: `core.utf8_prefix(text, max_chars) -> prefix,remainder`
- Consumes: no production modules.

- [ ] **Step 1: Create a small test harness and failing Unicode tests**

`tests/testlib.lua` must expose literal assertions and exit nonzero after reporting failures:

```lua
local M = { failures = 0 }
function M.eq(name, got, want)
  if got ~= want then
    M.failures = M.failures + 1
    io.stderr:write(string.format("FAIL %s: got %q want %q\n", name, got, want))
  else
    io.stdout:write("PASS " .. name .. "\n")
  end
end
function M.truthy(name, value)
  M.eq(name, not not value, true)
end
function M.finish()
  if M.failures > 0 then os.exit(1) end
end
return M
```

`tests/test_core.lua` must load the production path supplied as its first argument and prove these exact behaviors:

```lua
local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local core = dofile(root .. "/usr/lib/sms2telegram/core.lua")

t.eq("UCS2 Chinese", assert(core.ucs2_to_utf8("77ED4FE1")), "短信")
t.eq("UCS2 phone", assert(core.ucs2_to_utf8("002B0038003600310033")), "+8613")
local value, err = core.ucs2_to_utf8("D800")
t.eq("reject surrogate", value, nil)
t.truthy("surrogate error", err and err:match("surrogate"))
t.eq("UTF-8 length", core.utf8_length("A短信🙂"), 4)
local head, tail = core.utf8_prefix("A短信🙂B", 3)
t.eq("UTF-8 prefix", head, "A短信")
t.eq("UTF-8 remainder", tail, "🙂B")
t.finish()
```

- [ ] **Step 2: Run the tests on the router and verify RED**

Copy `tests/` to `/tmp/sms2telegram-dev/tests/`, create an empty `/tmp/sms2telegram-dev/src/usr/lib/sms2telegram/` directory, then run:

```sh
cd /tmp/sms2telegram-dev
lua tests/test_core.lua src
```

Expected: nonzero exit with `cannot open src/usr/lib/sms2telegram/core.lua`.

- [ ] **Step 3: Implement only the Unicode primitives**

Implement `ucs2_to_utf8` by validating an all-hex input whose length is divisible by four, converting each 16-bit code unit, rejecting `D800` through `DFFF`, and emitting one-, two-, or three-byte UTF-8. Implement `utf8_length` and `utf8_prefix` by advancing according to the leading-byte width and rejecting truncated continuation sequences. Return the module table at EOF.

Core function shape:

```lua
local M = {}

local function encode_codepoint(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64))
  end
  return string.char(
    0xE0 + math.floor(cp / 4096),
    0x80 + (math.floor(cp / 64) % 64),
    0x80 + (cp % 64)
  )
end

function M.ucs2_to_utf8(hex)
  if type(hex) ~= "string" or #hex % 4 ~= 0 or hex:find("[^0-9A-Fa-f]") then
    return nil, "invalid UCS2 hexadecimal input"
  end
  local out = {}
  for pos = 1, #hex, 4 do
    local cp = tonumber(hex:sub(pos, pos + 3), 16)
    if cp >= 0xD800 and cp <= 0xDFFF then return nil, "UCS2 surrogate is invalid" end
    out[#out + 1] = encode_codepoint(cp)
  end
  return table.concat(out)
end
```

- [ ] **Step 4: Sync production code to the router and verify GREEN**

Run the same `lua tests/test_core.lua src` command after copying `src/`. Expected: six `PASS` lines and exit 0.

- [ ] **Step 5: Commit the Unicode test cycle**

```sh
git add tests/testlib.lua tests/test_core.lua src/usr/lib/sms2telegram/core.lua
git commit -m "feat: add SMS Unicode primitives"
```

---

### Task 2: Parse Stored SMS and Format Telegram Parts

**Files:**
- Modify: `tests/test_core.lua`
- Modify: `src/usr/lib/sms2telegram/core.lua`

**Interfaces:**
- Consumes: Task 1 Unicode primitives.
- Produces: `core.parse_cmgl(response) -> messages|nil,error`, each message containing `index`, `status`, `sender`, `timestamp`, `body`.
- Produces: `core.format_parts(message, limit) -> string[]`.
- Produces: `core.route_device(route_output) -> string|nil`.
- Produces: `core.next_backoff(current, initial, maximum) -> integer`.

- [ ] **Step 1: Add failing literal-fixture tests**

Append fixtures that exercise a real text-mode AirM2M response, multiline preservation, body-first rendering, route denial inputs and capped retry:

```lua
local response = table.concat({
  '+CMGL: 7,"REC READ","002B00380036003100330038003000300030003000300030003000300030",,"26/09/05,14:30:00+32"',
  '77ED4FE1000A7B2C4E8C884C',
  'OK',
  ''
}, '\r\n')
local messages = assert(core.parse_cmgl(response))
t.eq("one CMGL record", #messages, 1)
t.eq("CMGL index", messages[1].index, 7)
t.eq("decoded sender", messages[1].sender, "+8613800000000")
t.eq("decoded multiline body", messages[1].body, "短信\n第二行")

local parts = core.format_parts(messages[1], 4096)
t.eq("short SMS one part", #parts, 1)
t.eq("body precedes metadata", parts[1], "短信\n第二行\n\n📩 短信信息\n来自：+8613800000000\n时间：26/09/05,14:30:00+32")
t.eq("route eth0", core.route_device("1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.2\n"), "eth0")
t.eq("route eth2", core.route_device("1.1.1.1 dev eth2 src 10.0.0.2\n"), "eth2")
t.eq("missing route", core.route_device("RTNETLINK answers: Network unreachable\n"), nil)
t.eq("backoff starts", core.next_backoff(nil, 15, 300), 15)
t.eq("backoff doubles", core.next_backoff(60, 15, 300), 120)
t.eq("backoff caps", core.next_backoff(240, 15, 300), 300)
```

Add a generated 4,200-character ASCII body and assert that every returned part is at most 4,096 UTF-8 characters, every part starts with body text, and every part repeats the metadata.

- [ ] **Step 2: Verify RED on the router**

Run `lua tests/test_core.lua src`. Expected: failure `attempt to call field 'parse_cmgl' (a nil value)`.

- [ ] **Step 3: Implement CSV/CMGL parsing and body decoding**

Implement an RFC-4180-like single-line CSV scanner that preserves empty fields and doubled quotes. Normalize CRLF to LF, start a record on `+CMGL:`, collect body lines until the next header or terminal `OK`, and decode a value as UCS2 only when it is all hex and its length is a positive multiple of four. Join UCS2 body lines before decoding so an encoded newline `000A` becomes a real newline.

Required record construction:

```lua
messages[#messages + 1] = {
  index = assert(tonumber(fields[1])),
  status = fields[2],
  sender = decode_text(fields[3]),
  timestamp = fields[5] or "",
  body = decode_body(body_lines)
}
```

Malformed headers, invalid UCS2, and missing terminal status return `nil,error`; they must never yield a partially deliverable record.

- [ ] **Step 4: Implement formatting, splitting, route parsing and backoff**

Use this exact metadata block and append it after the body:

```lua
local metadata = "📩 短信信息\n来自：" .. message.sender .. "\n时间：" .. message.timestamp
```

For multipart Telegram output, reserve the character length of `\n\n[1/N]\n` plus metadata, split the body with `utf8_prefix`, then recalculate once with the final part count. `route_device` must match the whitespace-delimited token following `dev`; `next_backoff` returns `initial` for no prior delay and otherwise `min(current * 2, maximum)`.

- [ ] **Step 5: Verify GREEN and run the mutation checks**

Run `lua tests/test_core.lua src`. Expected: all assertions pass. Temporarily change the metadata/body order and `dev` token extraction in production code; each corresponding test must fail. Restore production code and rerun to exit 0.

- [ ] **Step 6: Commit parsing and formatting**

```sh
git add tests/test_core.lua src/usr/lib/sms2telegram/core.lua
git commit -m "feat: parse and format stored SMS messages"
```

---

### Task 3: Implement the Bounded AT Client

**Files:**
- Create: `tests/test_at.lua`
- Create: `src/usr/lib/sms2telegram/at.lua`

**Interfaces:**
- Consumes: `core.parse_cmgl(response)`.
- Produces: `at.Client.new(transport, core, options) -> client`.
- Produces: `client:initialize() -> true|nil,error`.
- Produces: `client:scan() -> messages|nil,error`.
- Produces: `client:delete(index) -> true|nil,error`.
- Produces: `client:wait_for_cmti(timeout_ms) -> boolean|nil,error`.
- Produces: `at.open_nixio_transport(device, baud) -> transport|nil,error`.

- [ ] **Step 1: Write fake-transport tests before production code**

Create a fake transport that records writes and returns literal response frames. Tests must prove:

```lua
local client = at.Client.new(fake, core, { storage = "SM", timeout_ms = 3000 })
local ok, err = client:initialize()
t.eq("AT init succeeds", ok, true)
t.eq("AT init sequence", table.concat(fake.commands, "|"),
  'AT|ATE0|AT+CMEE=2|AT+CMGF=1|AT+CSCS="UCS2"|AT+CPMS="SM","SM","SM"|AT+CNMI=2,1,0,0,0')
t.eq("scan command", client:scan()[1].index, 7)
t.eq("delete success", client:delete(7), true)
```

Separate cases must return errors for timeout, terminal `ERROR`, `+CMS ERROR`, malformed CMGL data, delete index zero, delete index containing non-digits, and a hangup from the transport. A `+CMTI: "SM",7` line delivered while idle must make `wait_for_cmti` return true; unrelated URCs return false.

- [ ] **Step 2: Verify RED on the router**

Run `lua tests/test_at.lua src`. Expected: nonzero exit because `src/usr/lib/sms2telegram/at.lua` does not exist.

- [ ] **Step 3: Implement the command-level client**

`Client:command(text)` writes `text .. "\r"`, waits for a complete result with the configured timeout, and succeeds only on a terminal line equal to `OK`. It returns the complete frame so `scan` can call `core.parse_cmgl`. `delete` must validate `index` with `^[1-9][0-9]*$` before sending `AT+CMGD=<index>`.

Initialization must execute the exact seven-command sequence from the test and stop on the first failure. It may retry only at the worker/main-loop level, never hide a failed command inside `initialize`.

- [ ] **Step 4: Implement the real nixio transport**

Validate the device as an absolute `/dev/tty...` path and baud as an integer. Run the fixed terminal setup `stty -F <validated-device> 115200 raw -echo`, open with `nixio.open(device, "r+")`, and use `nixio.poll` with `in`, `err`, and `hup` flags. Buffer arbitrary read chunks, normalize CRLF only when returning a completed frame, and preserve unsolicited `+CMTI` lines for `wait_for_cmti`.

The real transport surface consumed by `Client` is:

```lua
transport:write_all(bytes)          -- true or nil,error
transport:read_result(timeout_ms)   -- frame or nil,error
transport:wait_line(timeout_ms)     -- line or nil,error; timeout is not an error
transport:close()
```

- [ ] **Step 5: Verify GREEN and run non-destructive modem smoke queries**

Run `lua tests/test_at.lua src`; expected exit 0. Copy only `core.lua`, `at.lua`, and a smoke driver to `/tmp/sms2telegram-dev` and issue `AT`, `ATI`, `AT+CMGF=?`, `AT+CPMS=?`, and `AT+CNMI=?` through the real transport. Expected output includes `Air780EPV`, `+CMGF: (0-1)`, `SM`, and a `+CNMI` range; do not issue `CMGL`, `CMGR`, `CMGD`, or Telegram calls in this smoke check.

- [ ] **Step 6: Commit the AT client**

```sh
git add tests/test_at.lua src/usr/lib/sms2telegram/at.lua
git commit -m "feat: add bounded Air780EPV AT client"
```

---

### Task 4: Implement Route-Gated Telegram Delivery and the Ledger

**Files:**
- Create: `tests/test_delivery.lua`
- Create: `src/usr/lib/sms2telegram/delivery.lua`

**Interfaces:**
- Consumes: `core.route_device`, `core.format_parts`.
- Produces: `delivery.validate_credentials(token, chat_id) -> true|nil,error`.
- Produces: `delivery.route_allowed(route_output, allowed_device, core) -> true|nil,error`.
- Produces: `delivery.fingerprint(message, sha256_fn) -> hex_digest`.
- Produces: `delivery.Ledger.new(path, fs) -> ledger` with `contains`, `add`, `remove`, `save_atomic`.
- Produces: `delivery.Sender.new(adapters, options) -> sender` with `send_parts(token, chat_id, parts) -> true|nil,error`.

- [ ] **Step 1: Write failing delivery-policy tests**

Use fake command execution and real files under `/tmp/sms2telegram-test-<pid>/`. Cover these exact outcomes:

```lua
t.eq("accept bot token", delivery.validate_credentials("123456:Abc_def-XYZ", "-1001234567890"), true)
t.eq("reject shell token", delivery.validate_credentials("123;reboot", "1"), nil)
t.eq("allow exact eth0", delivery.route_allowed("1.1.1.1 dev eth0 src 192.168.1.2", "eth0", core), true)
t.eq("deny SIM eth2", delivery.route_allowed("1.1.1.1 dev eth2 src 10.0.0.2", "eth0", core), nil)
```

Assert that a successful send requires command exit 0, HTTP code `200`, and response JSON parsed by `jsonfilter` as literal `true`. Test HTTP 401, curl timeout, malformed JSON, and `{"ok":false}` as failures. Assert the constructed curl command contains the temporary body filename but never contains the SMS body.

For the ledger, add index 7/fingerprint `abc`, reload from disk, prove it matches, prove index 7/fingerprint `def` does not match, remove `abc`, and prove the saved file is empty. Assert ledger and temporary file modes are `0600`.

- [ ] **Step 2: Verify RED on the router**

Run `lua tests/test_delivery.lua src`. Expected: nonzero exit because `delivery.lua` is absent.

- [ ] **Step 3: Implement validation, route gating and fingerprints**

Accept tokens only when they match `^[0-9]+:[A-Za-z0-9_-]+$`. Accept numeric Chat IDs matching `^-?[0-9]+$` and channel usernames matching `^@[A-Za-z0-9_]+$`. `route_allowed` succeeds only on exact equality with `allowed_device`.

Construct fingerprint input with explicit length delimiters to prevent field-boundary collisions:

```lua
local canonical = table.concat({
  tostring(message.index),
  tostring(#message.sender), message.sender,
  tostring(#message.timestamp), message.timestamp,
  tostring(#message.body), message.body
}, "\0")
```

Write `canonical` to a protected temporary file, call `sha256sum`, validate a 64-hex-character digest, and delete the temporary file.

- [ ] **Step 4: Implement atomic ledger persistence**

Split each ledger line on its single tab, require the index to match `^[1-9][0-9]*$`, require the digest to match `^[0-9a-f]+$`, and then require the digest length to equal 64; reject a corrupt ledger rather than silently discarding records. Write sorted `<index>\t<sha256>\n` records to `<path>.tmp`, chmod `0600`, flush and close, then atomically rename over `<path>`.

- [ ] **Step 5: Implement curl delivery without body interpolation**

For each part, write a mode-`0600` body file. Build curl only from validated credentials and fixed safe paths:

```sh
curl --silent --show-error --connect-timeout 10 --max-time 30 \
  --output /tmp/sms2telegram.response \
  --write-out '%{http_code}' \
  --data-urlencode chat_id=-1001234567890 \
  --data-urlencode text@/tmp/sms2telegram.message \
  https://api.telegram.org/bot123456:Abc_def-XYZ/sendMessage
```

The actual filenames include the daemon PID, are validated as `/tmp/sms2telegram.[0-9]+.(message|response)`, and are shell-quoted. Parse the response with `jsonfilter -i <response-file> -e '@.ok'`; require literal `true`. Remove request and response files on every success and failure path.

- [ ] **Step 6: Verify GREEN and mutation behavior**

Run `lua tests/test_delivery.lua src`; expected exit 0. Temporarily relax route equality and Telegram JSON checking; the `eth2` and `ok:false` tests must fail. Restore code and rerun to exit 0.

- [ ] **Step 7: Commit delivery safety**

```sh
git add tests/test_delivery.lua src/usr/lib/sms2telegram/delivery.lua
git commit -m "feat: gate Telegram delivery and persist confirmations"
```

---

### Task 5: Orchestrate Safe Delivery and Recovery

**Files:**
- Create: `tests/test_worker.lua`
- Create: `src/usr/lib/sms2telegram/worker.lua`
- Create: `src/usr/sbin/sms2telegram`

**Interfaces:**
- Consumes: `at.Client`, `delivery.Sender`, `delivery.Ledger`, and all pure core functions.
- Produces: `worker.new(deps, config) -> worker`.
- Produces: `worker:cycle() -> true|nil,error`.
- Produces: executable daemon that reloads UCI, owns the real serial transport, handles retry/backoff and logs redacted categories.

- [ ] **Step 1: Write failing worker tests with controlled adapters**

Create fakes that expose calls rather than mocking framework internals. Tests must prove observable order and state:

1. Empty token or Chat ID causes zero calls to AT scan, route, sender, ledger, and delete.
2. `eth2` route causes scan but zero Telegram/send/delete calls and leaves ledger unchanged.
3. Telegram failure causes zero delete and ledger writes.
4. Telegram success calls ledger add/save before AT delete.
5. Delete failure leaves the confirmed fingerprint in the ledger.
6. A matching ledger entry skips Telegram and retries delete.
7. A reused index with a different fingerprint sends the new SMS.
8. Successful delete removes and saves the ledger entry.
9. Two stored SMS are processed independently; failure of one does not delete it or prevent an already-confirmed other record from cleanup.

The success-order assertion uses this literal event list:

```lua
t.eq("delivery order", table.concat(events, ","),
  "scan,route,send,ledger-add,ledger-save,delete,ledger-remove,ledger-save")
```

- [ ] **Step 2: Verify RED on the router**

Run `lua tests/test_worker.lua src`. Expected: nonzero exit because `worker.lua` does not exist.

- [ ] **Step 3: Implement one deterministic worker cycle**

`cycle` validates credentials first, scans all modem messages, computes each fingerprint, checks ledger recovery, checks the route immediately before each new send, sends every formatted part, records confirmation atomically, then deletes and clears the ledger. Return categorized errors (`config`, `route`, `telegram`, `at`, `ledger`) without including token, Chat ID, sender or body.

Do not let a Telegram failure delete or mark the SMS. Continue only with ledger-confirmed cleanup records; otherwise finish the cycle so backoff applies globally and avoids hammering Telegram.

- [ ] **Step 4: Implement production configuration and loop wiring**

The executable reads fixed keys with `uci -q get sms2telegram.main.<key>`, validates numeric intervals as `1..3600`, opens the ledger at `/var/lib/sms2telegram/delivered`, opens the real AT transport, initializes it, and runs cycles.

Loop behavior:

```lua
while true do
  local ok, category = worker:cycle()
  if ok then
    delay = nil
    at_client:wait_for_cmti(config.poll_interval * 1000)
  else
    delay = core.next_backoff(delay, config.retry_initial, config.retry_max)
    log_redacted(category, delay)
    nixio.nanosleep(delay)
  end
end
```

On AT hangup, close the client and recreate/reinitialize it. Reload UCI configuration before each scan and while credentials are incomplete. Log through `nixio.syslog` with tag `sms2telegram`; never include values from credentials or parsed messages.

- [ ] **Step 5: Verify GREEN and process-level behavior**

Run all Lua suites:

```sh
lua tests/test_core.lua src
lua tests/test_at.lua src
lua tests/test_delivery.lua src
lua tests/test_worker.lua src
```

Expected: every suite exits 0. Run the executable in a temporary test mode with fake UCI output containing empty credentials; expected: it remains alive for one polling interval and the fake AT adapter records no open/scan/delete operations.

- [ ] **Step 6: Commit orchestration**

```sh
git add tests/test_worker.lua src/usr/lib/sms2telegram/worker.lua src/usr/sbin/sms2telegram
git commit -m "feat: orchestrate restart-safe SMS forwarding"
```

---

### Task 6: Add OpenWrt Service, Configuration and Chinese Operations Guide

**Files:**
- Create: `src/etc/init.d/sms2telegram`
- Create: `src/etc/config/sms2telegram`
- Create: `src/usr/share/doc/sms2telegram/README.zh-CN.md`
- Create: `tests/test_openwrt.sh`

**Interfaces:**
- Consumes: `/usr/sbin/sms2telegram` from Task 5.
- Produces: boot-enabled `procd` service and documented UCI operator flow.

- [ ] **Step 1: Write failing executable service checks**

`tests/test_openwrt.sh` must copy the init script into a temporary root containing a stub `/etc/rc.common` and stub `procd_*` functions, source it, and assert the recorded service command is exactly `/usr/sbin/sms2telegram`, stdout/stderr are enabled, and respawn is configured. It must parse the config with a stub `config_get` and assert exact defaults: device `/dev/ttyACM0`, storage `SM`, allowed device `eth0`, poll 15, retry initial 15 and maximum 300.

It must also fail if config mode is not `0600`, the init script is not executable, or the guide omits the exact install, UCI, restart, log and uninstall commands.

- [ ] **Step 2: Verify RED locally**

Run `sh tests/test_openwrt.sh`. Expected: failure because `src/etc/init.d/sms2telegram` is missing.

- [ ] **Step 3: Implement the procd init service and protected config**

The init script uses:

```sh
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10

start_service() {
    config_load sms2telegram
    config_get_bool enabled main enabled 1
    [ "$enabled" -eq 1 ] || return 0
    procd_open_instance
    procd_set_param command /usr/sbin/sms2telegram
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn 3600 5 5
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger sms2telegram
}
```

Create the exact UCI defaults from the design and chmod the config `0600`; chmod the init script and daemon `0755`.

- [ ] **Step 4: Write the Chinese guide**

Document these exact operator actions with the final filename:

```sh
opkg install /tmp/sms2telegram_1.0.0_all.ipk
uci set sms2telegram.main.bot_token='123456:replace_with_real_token'
uci set sms2telegram.main.chat_id='-1001234567890'
uci commit sms2telegram
/etc/init.d/sms2telegram restart
logread -e sms2telegram
/etc/init.d/sms2telegram status
opkg remove sms2telegram
```

Explain that `allowed_wan_device` must remain `eth0` for this router, that `eth2` is prohibited, credentials must not be pasted into logs or screenshots, and no SMS is touched before credentials are set.

- [ ] **Step 5: Verify service checks and shell syntax**

Run:

```sh
sh -n src/etc/init.d/sms2telegram
sh tests/test_openwrt.sh
```

Expected: both exit 0 with no warnings.

- [ ] **Step 6: Commit OpenWrt integration**

```sh
git add src/etc tests/test_openwrt.sh src/usr/share/doc/sms2telegram/README.zh-CN.md
git commit -m "feat: add OpenWrt service and operator guide"
```

---

### Task 7: Assemble and Validate the IPK

**Files:**
- Create: `ipk/control/control`
- Create: `ipk/control/conffiles`
- Create: `ipk/control/postinst`
- Create: `ipk/control/prerm`
- Create: `scripts/build-ipk.sh`
- Create: `tests/test_package.sh`
- Create: `tests/router-smoke.sh`
- Create: `dist/sms2telegram_1.0.0_all.ipk` (ignored build artifact)
- Create: `dist/sms2telegram_1.0.0_all.ipk.sha256` (ignored build artifact)

**Interfaces:**
- Consumes: complete `src/` root filesystem tree.
- Produces: installable IPK and checksum.

- [ ] **Step 1: Write failing package archive tests**

`tests/test_package.sh` accepts the IPK path, extracts its ar members into a new temporary directory, and asserts:

- members are exactly `debian-binary`, `control.tar.gz`, and `data.tar.gz`;
- `debian-binary` is exactly `2.0` plus newline;
- control fields equal package `sms2telegram`, version `1.0.0`, architecture `all`, and dependencies `lua, luci-lib-nixio, curl, ca-bundle, jsonfilter`;
- conffiles contains only `/etc/config/sms2telegram`;
- data archive contains every file in the File Map and no test or secret files;
- modes are `0755` for daemon/init/control scripts and `0600` for config;
- postinst enables and restarts only when `IPKG_INSTROOT` is empty;
- prerm stops and disables only when `IPKG_INSTROOT` is empty;
- extracting the IPK does not contain the values from `router.txt`.

- [ ] **Step 2: Verify RED locally**

Run `sh tests/test_package.sh dist/sms2telegram_1.0.0_all.ipk`. Expected: nonzero exit because the IPK is absent.

- [ ] **Step 3: Add exact control metadata and lifecycle scripts**

Use this control metadata:

```text
Package: sms2telegram
Version: 1.0.0
Architecture: all
Maintainer: Local Administrator
Depends: lua, luci-lib-nixio, curl, ca-bundle, jsonfilter
Section: net
Priority: optional
Description: Forward stored Air780EPV SMS messages to Telegram using the router uplink.
```

`conffiles` contains `/etc/config/sms2telegram`. `postinst` exits immediately for a nonempty `IPKG_INSTROOT`; otherwise it runs enable then restart and propagates failure. `prerm` follows the same root guard and runs stop then disable.

- [ ] **Step 4: Implement deterministic package assembly**

`scripts/build-ipk.sh` uses `set -eu`, resolves the repository root from its own path, creates a fresh `build/ipk/` tree, copies `src/`, applies exact modes, creates sorted gzip-compressed control and data tar archives, writes `debian-binary`, then calls `ar rcs` in member order. It rejects any empty source file and scans the staging tree for the router password before packaging.

The last commands create both outputs:

```sh
mkdir -p "$repo/dist"
ar rcs "$repo/dist/sms2telegram_1.0.0_all.ipk" debian-binary control.tar.gz data.tar.gz
sha256sum "$repo/dist/sms2telegram_1.0.0_all.ipk" > "$repo/dist/sms2telegram_1.0.0_all.ipk.sha256"
```

- [ ] **Step 5: Build and verify the package locally**

Run:

```sh
sh scripts/build-ipk.sh
sh tests/test_package.sh dist/sms2telegram_1.0.0_all.ipk
shasum -a 256 -c dist/sms2telegram_1.0.0_all.ipk.sha256
```

Expected: build exits 0, package test reports every assertion as passing, and checksum reports `OK`.

- [ ] **Step 6: Run full regression tests on the router and non-destructive smoke checks**

Copy `src/`, `tests/*.lua`, and `tests/router-smoke.sh` to `/tmp/sms2telegram-dev/`. Run:

```sh
cd /tmp/sms2telegram-dev
lua tests/test_core.lua src
lua tests/test_at.lua src
lua tests/test_delivery.lua src
lua tests/test_worker.lua src
sh tests/router-smoke.sh
```

`router-smoke.sh` must assert Lua 5.1, `nixio`, curl, CA bundle, `jsonfilter`, `sha256sum`, default route device `eth0`, OpenClash enabled, Telegram API reachability through the router output path, modem identity Air780EPV, and supported SMS query ranges. It must not use `CMGL`, `CMGR`, `CMGD`, a Bot Token, or `sendMessage`.

- [ ] **Step 7: Inspect the archive exactly as opkg will see it**

List control and data archives, then verify no credentials or unexpected paths:

```sh
ar t dist/sms2telegram_1.0.0_all.ipk
mkdir -p build/final-inspect
cd build/final-inspect
ar x ../../dist/sms2telegram_1.0.0_all.ipk
tar -tzf control.tar.gz
tar -tzf data.tar.gz
```

Expected: only the specified package members and root filesystem paths appear; neither router credentials nor Telegram credentials are present.

- [ ] **Step 8: Commit source and packaging metadata, then record final evidence**

Run fresh verification again before the commit, then:

```sh
git add src tests ipk scripts docs/superpowers/plans/2026-09-05-sms-to-telegram-ipk.md
git commit -m "build: produce SMS to Telegram OpenWrt package"
git status --short
```

Expected: commit succeeds and `git status --short` is empty because `dist/` and `build/` artifacts are intentionally ignored. Report the absolute IPK path, checksum path, package size, test counts, router smoke results, and the fact that the package was not installed and no Telegram message was sent.

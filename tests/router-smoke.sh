#!/bin/sh
# This check is deliberately read-only: it neither installs the IPK nor changes UCI.
set -eu

http_status_proves_reachability() {
    case "${1:-}" in
        [234][0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

modem_identity_matches() {
    grep -Fq 'AirM2M_780EPV'
}

if [ "${1:-}" = "--check-http-status" ]; then
    if http_status_proves_reachability "${2:-}"; then exit 0; fi
    exit 1
fi
if [ "${1:-}" = "--check-modem-identity" ]; then
    if modem_identity_matches; then exit 0; fi
    exit 1
fi
STTY_BIN=${STTY_BIN:-/tmp/sms2telegram-stty/usr/bin/stty}
AT_DEVICE=${AT_DEVICE:-/dev/ttyACM0}
SMS_DEVICE=${SMS_DEVICE:-/dev/ttyACM2}
TMP=${TMPDIR:-/tmp}/sms2telegram-router-smoke-$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

need lua
need curl
need jsonfilter
lua -e 'assert(_VERSION == "Lua 5.1"); assert(require("nixio"))' || fail "Lua 5.1 with nixio is required"
pass "Lua 5.1 and nixio"

[ -r /etc/ssl/certs/ca-certificates.crt ] || [ -r /etc/ssl/cert.pem ] || fail "CA bundle is unavailable"
pass "curl, jsonfilter, and CA bundle"

route=$(ip -4 route get 1.1.1.1 2>&1) || fail "unable to inspect IPv4 route"
set -- $route
device=
previous=
for token in "$@"; do
    [ "$previous" = dev ] && device=$token
    previous=$token
done
[ "$device" = eth0 ] || fail "default route device is '${device:-unknown}', expected eth0"
pass "eth0 default route"

/etc/init.d/openclash enabled >/dev/null 2>&1 || fail "OpenClash is not enabled"
pass "OpenClash enabled"

# No token is used: this only verifies public HTTPS reachability through normal router output.
http_status=$(curl --silent --show-error --connect-timeout 10 --max-time 20 --output "$TMP/telegram.json" \
    --write-out '%{http_code}' https://api.telegram.org/) || fail "Telegram HTTPS reachability failed"
http_status_proves_reachability "$http_status" || fail "Telegram API returned unacceptable HTTP status"
pass "Telegram HTTPS reachable without credentials"

[ -x "$STTY_BIN" ] || fail "stty unavailable; extract coreutils-stty to /tmp/sms2telegram-stty or set STTY_BIN"
[ "$AT_DEVICE" != "$SMS_DEVICE" ] || fail "AT_DEVICE and SMS_DEVICE must be different"
[ -c "$AT_DEVICE" ] || fail "AT device $AT_DEVICE is unavailable"
[ -c "$SMS_DEVICE" ] || fail "VUART device $SMS_DEVICE is unavailable"

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cp "$ROOT/src/usr/lib/sms2telegram/at.lua" "$TMP/at.lua"
cp "$ROOT/src/usr/lib/sms2telegram/serial.lua" "$TMP/serial.lua"
cp "$ROOT/src/usr/lib/sms2telegram/vuart.lua" "$TMP/vuart.lua"
cat > "$TMP/probe.lua" <<'EOF'
local at = dofile(arg[1] .. "/at.lua")
local serial = dofile(arg[1] .. "/serial.lua")
local vuart = dofile(arg[1] .. "/vuart.lua")
local json = require "luci.jsonc"
local transport, err = serial.open(arg[2], 115200, { stty = arg[4], drain = true })
assert(transport, err)
local client = at.Client.new(transport, { timeout_ms = 5000 })
for _, command in ipairs({ "AT", "ATI" }) do
  local frame, command_err = client:command(command)
  assert(frame, command_err)
  io.write(frame, "\n")
end
transport:close()
local sms_transport, sms_err = serial.open(arg[3], 115200, { stty = arg[4] })
assert(sms_transport, sms_err)
local line, read_err = sms_transport:next_line(10000)
assert(line, read_err or "no VUART event; reboot Air780EPV to emit ready")
local event, event_err = vuart.decode_line(line, function(value) return json.parse(value) end)
assert(event and event.type == "ready", event_err or "first VUART event is not ready")
sms_transport:close()
EOF
lua "$TMP/probe.lua" "$TMP" "$AT_DEVICE" "$SMS_DEVICE" "$STTY_BIN" > "$TMP/modem.txt" ||
    fail "AT/VUART probe failed (reboot Air780EPV so it emits ready)"
modem_identity_matches < "$TMP/modem.txt" || fail "unexpected modem identity"
pass "AirM2M_780EPV AT identity and LuatOS VUART ready event"

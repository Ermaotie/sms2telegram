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

cpms_supports_sm() { grep -Fq 'SM'; }
cnmi_supports_required_ranges() { grep -Fq '+CNMI: (0-3),(0-3),(0-3),(0-2),(0-1)'; }

if [ "${1:-}" = "--check-http-status" ]; then
    if http_status_proves_reachability "${2:-}"; then exit 0; fi
    exit 1
fi
if [ "${1:-}" = "--check-modem-identity" ]; then
    if modem_identity_matches; then exit 0; fi
    exit 1
fi
if [ "${1:-}" = "--check-cpms" ]; then if cpms_supports_sm; then exit 0; fi; exit 1; fi
if [ "${1:-}" = "--check-cnmi" ]; then if cnmi_supports_required_ranges; then exit 0; fi; exit 1; fi

STTY_BIN=${STTY_BIN:-/tmp/sms2telegram-stty/usr/bin/stty}
TMP=${TMPDIR:-/tmp}/sms2telegram-router-smoke-$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

need lua
need curl
need jsonfilter
need sha256sum
lua -e 'assert(_VERSION == "Lua 5.1"); assert(require("nixio"))' || fail "Lua 5.1 with nixio is required"
pass "Lua 5.1 and nixio"

[ -r /etc/ssl/certs/ca-certificates.crt ] || [ -r /etc/ssl/cert.pem ] || fail "CA bundle is unavailable"
pass "curl, jsonfilter, sha256sum, and CA bundle"

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
[ -c /dev/ttyACM0 ] || fail "modem device /dev/ttyACM0 is unavailable"

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cp "$ROOT/src/usr/lib/sms2telegram/at.lua" "$TMP/at.lua"
cp "$ROOT/src/usr/lib/sms2telegram/core.lua" "$TMP/core.lua"
cat > "$TMP/probe.lua" <<'EOF'
local at = dofile(arg[1] .. "/at.lua")
local core = dofile(arg[1] .. "/core.lua")
local transport, err = at.open_nixio_transport("/dev/ttyACM0", 115200, arg[2])
assert(transport, err)
local client = at.Client.new(transport, core, { timeout_ms = 5000 })
for _, command in ipairs({ "AT", "ATI", "AT+CMGF=?", "AT+CPMS=?", "AT+CNMI=?" }) do
  local frame, command_err = client:command(command)
  assert(frame, command_err)
  if command == "AT+CPMS=?" then
    local file = assert(io.open(arg[3] .. "/cpms.txt", "wb")); file:write(frame); file:close()
  elseif command == "AT+CNMI=?" then
    local file = assert(io.open(arg[3] .. "/cnmi.txt", "wb")); file:write(frame); file:close()
  end
  io.write(frame, "\n")
end
transport:close()
EOF
lua "$TMP/probe.lua" "$TMP" "$STTY_BIN" "$TMP" > "$TMP/modem.txt" || fail "non-destructive modem capability probes failed"
modem_identity_matches < "$TMP/modem.txt" || fail "unexpected modem identity"
grep -F '+CMGF: (0-1)' "$TMP/modem.txt" >/dev/null || fail "text SMS mode capability missing"
cpms_supports_sm < "$TMP/cpms.txt" || fail "SIM SMS storage capability missing"
cnmi_supports_required_ranges < "$TMP/cnmi.txt" || fail "CNMI capability range missing"
pass "AirM2M_780EPV non-destructive SMS capabilities"

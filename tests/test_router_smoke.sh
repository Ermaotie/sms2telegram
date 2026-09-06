#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() { echo "FAIL: $*" >&2; exit 1; }

accepts() {
    "$ROOT/tests/router-smoke.sh" --check-http-status "$1" ||
        fail "expected HTTP status $1 to prove public Telegram reachability"
}

rejects() {
    if "$ROOT/tests/router-smoke.sh" --check-http-status "$1"; then
        fail "expected HTTP status $1 to be rejected"
    fi
}

# A regression to a literal 404 check would reject the controller's real 302.
accepts 200
accepts 302
accepts 404
rejects 000
rejects 500
rejects 99
rejects abc

accepts_identity() {
    if ! printf '%s\n' "$1" | "$ROOT/tests/router-smoke.sh" --check-modem-identity; then
        fail "expected AirM2M_780EPV ATI fixture to be accepted"
    fi
}

rejects_identity() {
    if printf '%s\n' "$1" | "$ROOT/tests/router-smoke.sh" --check-modem-identity; then
        fail "expected unrelated ATI fixture to be rejected"
    fi
}

# A literal Air780EPV substring check misses the actual AirM2M ATI identity.
accepts_identity 'AirM2M_780EPV_V1009_LTE_AT'
rejects_identity 'Air780EPV_V1009_LTE_AT'
rejects_identity 'AirM2M_700EPV_V1009_LTE_AT'

printf '+CPMS: ("SM","ME"),("SM"),("SM")\n' | "$ROOT/tests/router-smoke.sh" --check-cpms ||
    fail "expected CPMS SM capability to be accepted"
if printf '+CNMI: (0-3),(0-3),(0-3),(0-2),(0-0)\n' | "$ROOT/tests/router-smoke.sh" --check-cnmi; then
    fail "expected incomplete CNMI range to be rejected"
fi
printf '+CNMI: (0-3),(0-3),(0-3),(0-2),(0-1)\n' | "$ROOT/tests/router-smoke.sh" --check-cnmi ||
    fail "expected full CNMI range to be accepted"

echo "PASS router smoke HTTP, identity, and SMS capability policy"

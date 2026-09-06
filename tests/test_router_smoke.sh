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

echo "PASS router smoke HTTP status policy"

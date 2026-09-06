#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sms2telegram-build-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_flags() {
    style=$1
    want=$2
    got=$(sh "$ROOT/scripts/build-ipk.sh" --tar-flags-for "$style") || fail "tar flag probe failed for $style"
    [ "$got" = "$want" ] || fail "wrong $style tar flags: $got"
}

assert_flags bsd '--format ustar --uid 0 --gid 0 --numeric-owner'
assert_flags gnu '--format=ustar --owner=0 --group=0 --numeric-owner'

mkdir -p "$TMP/stage" "$TMP/control"
printf 'ordinary router host line\nordinary IP line\nfixture-password\n' > "$TMP/router.txt"
printf 'endpoint: fixture-token\n' > "$TMP/tg_setting.txt"
printf 'fixture-password\n' > "$TMP/stage/leak"
if sh "$ROOT/scripts/build-ipk.sh" --check-secret-scan "$TMP/stage" "$TMP/control" "$TMP/router.txt" "$TMP/tg_setting.txt"; then
    fail "router password fixture was not rejected"
fi
printf 'fixture-token\n' > "$TMP/stage/leak"
if sh "$ROOT/scripts/build-ipk.sh" --check-secret-scan "$TMP/stage" "$TMP/control" "$TMP/router.txt" "$TMP/tg_setting.txt"; then
    fail "Telegram token fixture was not rejected"
fi
printf 'ordinary router host line\nordinary IP line\n' > "$TMP/stage/leak"
sh "$ROOT/scripts/build-ipk.sh" --check-secret-scan "$TMP/stage" "$TMP/control" "$TMP/router.txt" "$TMP/tg_setting.txt" || fail "ordinary router fields were treated as secrets"

echo "PASS tar portability and exact secret scan fixtures"

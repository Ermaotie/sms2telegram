#!/bin/sh
set -eu

PACKAGE=${1:?usage: tests/test_package.sh path/to/package.ipk}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sms2telegram-package.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (got '$1', want '$2')"; }
assert_file() { [ -f "$1" ] || fail "missing $2"; }

mode_of() {
    if value=$(stat -f '%Lp' "$1" 2>/dev/null); then
        printf '%s\n' "$value"
    else
        stat -c '%a' "$1"
    fi
}

[ -f "$PACKAGE" ] || fail "IPK is absent: $PACKAGE"
case "$PACKAGE" in /*) ;; *) PACKAGE=$(CDPATH= cd -- "$(dirname -- "$PACKAGE")" && pwd)/$(basename -- "$PACKAGE");; esac

(
    cd "$TMP"
    ar x "$PACKAGE"
)

members=$(ar t "$PACKAGE")
assert_eq "$members" "debian-binary
control.tar.gz
data.tar.gz" "IPK member order"
pass "IPK member order"
assert_eq "$(cat "$TMP/debian-binary")" "2.0" "debian-binary version"
pass "debian-binary"

mkdir "$TMP/control" "$TMP/data"
tar -xzf "$TMP/control.tar.gz" -C "$TMP/control"
tar -xzf "$TMP/data.tar.gz" -C "$TMP/data"

expected_control='conffiles
control
postinst
prerm'
actual_control=$(tar -tzf "$TMP/control.tar.gz" | sed -e 's#^\./##' -e '/\/$/d')
assert_eq "$actual_control" "$expected_control" "control archive paths"
pass "control archive paths"

control_field() { awk -F ': ' -v key="$1" '$1 == key { print substr($0, length(key) + 3); exit }' "$TMP/control/control"; }
assert_eq "$(control_field Package)" "sms2telegram" "package name"
assert_eq "$(control_field Version)" "1.0.0" "package version"
assert_eq "$(control_field Architecture)" "all" "package architecture"
assert_eq "$(control_field Depends)" "lua, luci-lib-nixio, coreutils-stty, curl, ca-bundle, jsonfilter" "package dependencies"
pass "control metadata"
assert_eq "$(cat "$TMP/control/conffiles")" "/etc/config/sms2telegram" "conffile declaration"
pass "conffile declaration"

expected_data='etc/config/sms2telegram
etc/init.d/sms2telegram
usr/lib/sms2telegram/at.lua
usr/lib/sms2telegram/core.lua
usr/lib/sms2telegram/delivery.lua
usr/lib/sms2telegram/worker.lua
usr/sbin/sms2telegram
usr/share/doc/sms2telegram/README.zh-CN.md'
actual_data=$(tar -tzf "$TMP/data.tar.gz" | sed -e 's#^\./##' -e '/\/$/d')
assert_eq "$actual_data" "$expected_data" "data archive paths"
pass "data archive paths"

for path in \
    etc/config/sms2telegram \
    etc/init.d/sms2telegram \
    usr/lib/sms2telegram/at.lua \
    usr/lib/sms2telegram/core.lua \
    usr/lib/sms2telegram/delivery.lua \
    usr/lib/sms2telegram/worker.lua \
    usr/sbin/sms2telegram \
    usr/share/doc/sms2telegram/README.zh-CN.md; do
    assert_file "$TMP/data/$path" "data file $path"
done
assert_eq "$(mode_of "$TMP/data/etc/config/sms2telegram")" "600" "config mode"
for path in "$TMP/data/etc/init.d/sms2telegram" "$TMP/data/usr/sbin/sms2telegram" \
    "$TMP/control/postinst" "$TMP/control/prerm"; do
    assert_eq "$(mode_of "$path")" "755" "executable mode $(basename "$path")"
done
pass "staged modes"

if find "$TMP/data" -type f \( -name '*test*' -o -name 'router.txt' -o -name 'tg_setting.txt' \) | grep . >/dev/null; then
    fail "data archive contains a test or sensitive file"
fi
if [ -n "${ROUTER_SECRET_FILE:-}" ]; then
    [ -f "$ROUTER_SECRET_FILE" ] || fail "ROUTER_SECRET_FILE is not a file"
    if find "$TMP/data" -type f -exec grep -F -q -f "$ROUTER_SECRET_FILE" {} \; -print | grep -q .; then
        fail "data archive contains configured router secret"
    fi
fi
pass "no test or secret files"

for script in postinst prerm; do
    IPKG_INSTROOT="$TMP/offline-root" sh "$TMP/control/$script"
done
grep -F 'IPKG_INSTROOT' "$TMP/control/postinst" >/dev/null || fail "postinst lacks root guard"
grep -F 'IPKG_INSTROOT' "$TMP/control/prerm" >/dev/null || fail "prerm lacks root guard"
grep -F 'set -eu' "$TMP/control/postinst" >/dev/null || fail "postinst does not propagate failures"
grep -F 'set -eu' "$TMP/control/prerm" >/dev/null || fail "prerm does not propagate failures"
grep -F '/etc/init.d/sms2telegram enable' "$TMP/control/postinst" >/dev/null || fail "postinst does not enable"
grep -F '/etc/init.d/sms2telegram restart' "$TMP/control/postinst" >/dev/null || fail "postinst does not restart"
grep -F '/etc/init.d/sms2telegram stop' "$TMP/control/prerm" >/dev/null || fail "prerm does not stop"
grep -F '/etc/init.d/sms2telegram disable' "$TMP/control/prerm" >/dev/null || fail "prerm does not disable"
pass "lifecycle root guards and actions"

echo "PASS package archive validation"

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

magic=$(od -An -tx1 -N2 "$PACKAGE" | tr -d ' \n')
assert_eq "$magic" "1f8b" "IPK outer gzip magic"
members=$(tar -tzf "$PACKAGE")
assert_eq "$members" "./debian-binary
./data.tar.gz
./control.tar.gz" "target-compatible IPK member order"
tar -xzf "$PACKAGE" -C "$TMP"
pass "target-compatible gzip/tar IPK outer archive"
assert_eq "$(wc -c < "$TMP/debian-binary" | tr -d ' ')" "4" "debian-binary byte count"
printf '2.0\n' | cmp - "$TMP/debian-binary" || fail "debian-binary bytes"
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
assert_eq "$(control_field Version)" "1.0.1" "package version"
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
for directory in \
    ./etc/ \
    ./etc/config/ \
    ./etc/init.d/ \
    ./etc/sms2telegram/ \
    ./usr/ \
    ./usr/lib/ \
    ./usr/lib/sms2telegram/ \
    ./usr/sbin/ \
    ./usr/share/ \
    ./usr/share/doc/ \
    ./usr/share/doc/sms2telegram/; do
    tar -tzf "$TMP/data.tar.gz" | grep -F -x "$directory" >/dev/null ||
        fail "data archive omits directory entry $directory"
done
pass "data archive directory entries"
[ -d "$TMP/data/etc/sms2telegram" ] || fail "missing persistent ledger directory"
assert_eq "$(mode_of "$TMP/data/etc/sms2telegram")" "700" "persistent ledger directory mode"
[ ! -e "$TMP/data/etc/sms2telegram/delivered" ] || fail "runtime ledger must not be packaged"
pass "persistent ledger directory without runtime state"

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
if [ -n "${ROUTER_SECRET_FILE:-}" ] && [ -n "${TELEGRAM_SECRET_FILE:-}" ]; then
    ROUTER_SOURCE=$ROUTER_SECRET_FILE
    TELEGRAM_SOURCE=$TELEGRAM_SECRET_FILE
else
    if COMMON_GIT_DIR=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null); then
        case "$COMMON_GIT_DIR" in /*) ;; *) COMMON_GIT_DIR="$ROOT/$COMMON_GIT_DIR";; esac
        MAIN_WORKSPACE=$(CDPATH= cd -- "$(dirname -- "$COMMON_GIT_DIR")" && pwd)
    else
        MAIN_WORKSPACE=$ROOT
    fi
    ROUTER_SOURCE=${ROUTER_SECRET_FILE:-$MAIN_WORKSPACE/router.txt}
    TELEGRAM_SOURCE=${TELEGRAM_SECRET_FILE:-$MAIN_WORKSPACE/tg_setting.txt}
fi
sh "$ROOT/scripts/build-ipk.sh" --check-secret-scan "$TMP/data" "$TMP/control" "$ROUTER_SOURCE" "$TELEGRAM_SOURCE" ||
    fail "archive contains configured secret"
pass "no test or secret files"

mkdir -p "$TMP/init.d" "$TMP/lifecycle"
cat > "$TMP/init.d/sms2telegram" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$ACTION_LOG"
[ "${FAIL_ACTION:-}" != "$1" ]
EOF
chmod 700 "$TMP/init.d/sms2telegram"
for script in postinst prerm; do
    sed "s|/etc/init.d|$TMP/init.d|g" "$TMP/control/$script" > "$TMP/lifecycle/$script"
    chmod 700 "$TMP/lifecycle/$script"
done
ACTION_LOG="$TMP/actions" IPKG_INSTROOT="$TMP/offline-root" sh "$TMP/lifecycle/postinst"
ACTION_LOG="$TMP/actions" IPKG_INSTROOT="$TMP/offline-root" sh "$TMP/lifecycle/prerm"
[ ! -e "$TMP/actions" ] || fail "offline lifecycle ran an action"
ACTION_LOG="$TMP/actions" IPKG_INSTROOT= sh "$TMP/lifecycle/postinst"
assert_eq "$(cat "$TMP/actions")" "enable
restart" "postinst action order"
: > "$TMP/actions"
ACTION_LOG="$TMP/actions" IPKG_INSTROOT= sh "$TMP/lifecycle/prerm"
assert_eq "$(cat "$TMP/actions")" "stop
disable" "prerm action order"
for script in postinst prerm; do
    first=enable second=restart
    [ "$script" = prerm ] && { first=stop; second=disable; }
    : > "$TMP/actions"
    if ACTION_LOG="$TMP/actions" FAIL_ACTION="$first" IPKG_INSTROOT= sh "$TMP/lifecycle/$script"; then fail "$script swallowed first failure"; fi
    assert_eq "$(cat "$TMP/actions")" "$first" "$script stops after first failure"
    : > "$TMP/actions"
    if ACTION_LOG="$TMP/actions" FAIL_ACTION="$second" IPKG_INSTROOT= sh "$TMP/lifecycle/$script"; then fail "$script swallowed second failure"; fi
    assert_eq "$(cat "$TMP/actions")" "$first
$second" "$script propagates second failure"
done
pass "lifecycle root guards, ordering, and failures"

echo "PASS package archive validation"

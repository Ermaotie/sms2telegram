#!/bin/sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$REPO/build/ipk"
STAGE="$BUILD/data"
CONTROL="$BUILD/control"
PACKAGE=sms2telegram_1.0.0_all.ipk

tar_flags_for() {
    case "$1" in
        bsd) printf '%s\n' '--format ustar --uid 0 --gid 0 --numeric-owner' ;;
        gnu) printf '%s\n' '--format=ustar --owner=0 --group=0 --numeric-owner' ;;
        *) return 1 ;;
    esac
}

tar_style() {
    if tar --version 2>/dev/null | head -n 1 | grep -q 'GNU tar'; then
        printf '%s\n' gnu
    else
        printf '%s\n' bsd
    fi
}

append_router_secret() {
    file=$1
    [ -r "$file" ] || return 0
    lines=$(awk 'NF { count++; values[count] = $0 } END { if (count == 3) print values[3] }' "$file")
    [ -z "$lines" ] || printf '%s\n' "$lines" >> "$SECRET_PATTERNS"
}

append_telegram_secrets() {
    file=$1
    [ -r "$file" ] || return 0
    awk 'index($0, ":") { value = substr($0, index($0, ":") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); if (value != "") print value }' "$file" >> "$SECRET_PATTERNS"
}

scan_secrets() {
    scan_stage=$1
    scan_control=$2
    scan_router=${3:-}
    scan_telegram=${4:-}
    umask 077
    SECRET_PATTERNS=$(mktemp "${TMPDIR:-/tmp}/sms2telegram-secret-patterns.XXXXXX")
    chmod 0600 "$SECRET_PATTERNS"
    trap 'rm -f "$SECRET_PATTERNS"' EXIT HUP INT TERM
    [ -n "$scan_router" ] && append_router_secret "$scan_router"
    [ -n "$scan_telegram" ] && append_telegram_secrets "$scan_telegram"
    if [ ! -s "$SECRET_PATTERNS" ]; then
        echo "secret scan not verified: no discoverable credential source" >&2
        return 0
    fi
    if find "$scan_stage" "$scan_control" -type f -exec grep -F -q -f "$SECRET_PATTERNS" {} \; -print | grep -q .; then
        echo "refusing to package configured secret" >&2
        return 1
    fi
}

if [ "${1:-}" = "--tar-flags-for" ]; then tar_flags_for "${2:-}"; exit $?; fi
if [ "${1:-}" = "--check-secret-scan" ]; then
    scan_secrets "${2:?stage required}" "${3:?control required}" "${4:-}" "${5:-}"
    exit $?
fi

create_portable_ar() {
    output=$1
    shift
    {
        printf '!<arch>\n'
        for member in "$@"; do
            size=$(wc -c < "$member" | tr -d ' ')
            printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' "$member" 0 0 0 100644 "$size"
            cat "$member"
            [ $((size % 2)) -eq 0 ] || printf '\n'
        done
    } > "$output"
}

rm -rf "$BUILD"
mkdir -p "$STAGE" "$CONTROL" "$REPO/dist"
cp -R "$REPO/src/." "$STAGE/"
cp "$REPO/ipk/control/control" "$REPO/ipk/control/conffiles" \
    "$REPO/ipk/control/postinst" "$REPO/ipk/control/prerm" "$CONTROL/"

chmod 0600 "$STAGE/etc/config/sms2telegram"
chmod 0755 "$STAGE/etc/init.d/sms2telegram" "$STAGE/usr/sbin/sms2telegram" \
    "$CONTROL/postinst" "$CONTROL/prerm"
# cp(1) on macOS assigns the current time to staged files.  Normalize it so
# tar headers and the resulting gzip streams remain reproducible across time.
# 1980 avoids a negative local timestamp on UTC+ timezones, which ustar cannot
# encode (unlike the Unix epoch at local midnight).
find "$STAGE" "$CONTROL" -type f -exec touch -t 198001010000 {} +

if find "$STAGE" "$CONTROL" -type f -size 0 -print | grep -q .; then
    echo "refusing to package an empty source file" >&2
    exit 1
fi
if find "$STAGE" -type f \( -name 'router.txt' -o -name 'tg_setting.txt' \) -print | grep -q .; then
    echo "refusing to package a sensitive source filename" >&2
    exit 1
fi

# When a credential file is supplied, check it quietly and never print its value.
COMMON_GIT_DIR=$(git -C "$REPO" rev-parse --git-common-dir)
case "$COMMON_GIT_DIR" in /*) ;; *) COMMON_GIT_DIR="$REPO/$COMMON_GIT_DIR";; esac
MAIN_WORKSPACE=$(CDPATH= cd -- "$(dirname -- "$COMMON_GIT_DIR")" && pwd)
ROUTER_SOURCE=${ROUTER_SECRET_FILE:-$MAIN_WORKSPACE/router.txt}
TELEGRAM_SOURCE=${TELEGRAM_SECRET_FILE:-$MAIN_WORKSPACE/tg_setting.txt}
scan_secrets "$STAGE" "$CONTROL" "$ROUTER_SOURCE" "$TELEGRAM_SOURCE"

(
    cd "$CONTROL"
    if [ "$(tar_style)" = gnu ]; then
        LC_ALL=C find . -type f -print | LC_ALL=C sort | xargs tar --format=ustar --owner=0 --group=0 --numeric-owner -cf "$BUILD/control.tar"
    else
        LC_ALL=C find . -type f -print | LC_ALL=C sort | xargs tar --format ustar --uid 0 --gid 0 --numeric-owner -cf "$BUILD/control.tar"
    fi
)
(
    cd "$STAGE"
    if [ "$(tar_style)" = gnu ]; then
        LC_ALL=C find . -type f -print | LC_ALL=C sort | xargs tar --format=ustar --owner=0 --group=0 --numeric-owner -cf "$BUILD/data.tar"
    else
        LC_ALL=C find . -type f -print | LC_ALL=C sort | xargs tar --format ustar --uid 0 --gid 0 --numeric-owner -cf "$BUILD/data.tar"
    fi
)
gzip -n -f "$BUILD/control.tar"
gzip -n -f "$BUILD/data.tar"
printf '2.0\n' > "$BUILD/debian-binary"
(
    cd "$BUILD"
    # macOS ar adds a Mach-O symbol-table member even for data archives.  Use
    # the standard ar wire format there so opkg sees exactly three members.
    if [ "$(uname -s)" = Darwin ]; then
        create_portable_ar "$REPO/dist/$PACKAGE" debian-binary control.tar.gz data.tar.gz
    else
        ar rcs "$REPO/dist/$PACKAGE" debian-binary control.tar.gz data.tar.gz
    fi
)
(
    cd "$REPO"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "dist/$PACKAGE" > "dist/$PACKAGE.sha256"
    else
        shasum -a 256 "dist/$PACKAGE" > "dist/$PACKAGE.sha256"
    fi
)

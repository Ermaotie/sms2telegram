#!/bin/sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$REPO/build/ipk"
STAGE="$BUILD/data"
CONTROL="$BUILD/control"
PACKAGE=sms2telegram_1.0.2_all.ipk

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

rm -rf "$BUILD"
mkdir -p "$STAGE" "$CONTROL" "$REPO/dist"
for path in \
    etc/config/sms2telegram \
    etc/init.d/sms2telegram \
    usr/lib/sms2telegram/at.lua \
    usr/lib/sms2telegram/core.lua \
    usr/lib/sms2telegram/delivery.lua \
    usr/lib/sms2telegram/worker.lua \
    usr/sbin/sms2telegram \
    usr/share/doc/sms2telegram/README.zh-CN.md; do
    mkdir -p "$STAGE/$(dirname -- "$path")"
    cp "$REPO/src/$path" "$STAGE/$path"
done
mkdir -p "$STAGE/etc/sms2telegram"
chmod 0700 "$STAGE/etc/sms2telegram"
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
find "$STAGE" -type d -exec touch -t 198001010000 {} +

if find "$STAGE" "$CONTROL" -type f -size 0 -print | grep -q .; then
    echo "refusing to package an empty source file" >&2
    exit 1
fi
if find "$STAGE" -type f \( -name 'router.txt' -o -name 'tg_setting.txt' \) -print | grep -q .; then
    echo "refusing to package a sensitive source filename" >&2
    exit 1
fi

# When a credential file is supplied, check it quietly and never print its value.
if [ -n "${ROUTER_SECRET_FILE:-}" ] && [ -n "${TELEGRAM_SECRET_FILE:-}" ]; then
    ROUTER_SOURCE=$ROUTER_SECRET_FILE
    TELEGRAM_SOURCE=$TELEGRAM_SECRET_FILE
else
    if COMMON_GIT_DIR=$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null); then
        case "$COMMON_GIT_DIR" in /*) ;; *) COMMON_GIT_DIR="$REPO/$COMMON_GIT_DIR";; esac
        MAIN_WORKSPACE=$(CDPATH= cd -- "$(dirname -- "$COMMON_GIT_DIR")" && pwd)
    else
        MAIN_WORKSPACE=$REPO
    fi
    ROUTER_SOURCE=${ROUTER_SECRET_FILE:-$MAIN_WORKSPACE/router.txt}
    TELEGRAM_SOURCE=${TELEGRAM_SECRET_FILE:-$MAIN_WORKSPACE/tg_setting.txt}
fi
scan_secrets "$STAGE" "$CONTROL" "$ROUTER_SOURCE" "$TELEGRAM_SOURCE"

(
    cd "$CONTROL"
    set -- $(tar_flags_for "$(tar_style)")
    LC_ALL=C find . -type f -print | LC_ALL=C sort | xargs tar "$@" -cf "$BUILD/control.tar"
)
(
    cd "$STAGE"
    set -- $(tar_flags_for "$(tar_style)")
    LC_ALL=C find . ! -path . \( -type d -o -type f \) -print | LC_ALL=C sort |
        xargs tar --no-recursion "$@" -cf "$BUILD/data.tar"
)
gzip -n -f "$BUILD/control.tar"
gzip -n -f "$BUILD/data.tar"
printf '2.0\n' > "$BUILD/debian-binary"
touch -t 198001010000 "$BUILD/debian-binary" "$BUILD/control.tar.gz" "$BUILD/data.tar.gz"
(
    cd "$BUILD"
    set -- $(tar_flags_for "$(tar_style)")
    tar "$@" -cf package.tar ./debian-binary ./data.tar.gz ./control.tar.gz
    gzip -n -f package.tar
    mv package.tar.gz "$REPO/dist/$PACKAGE"
)
(
    cd "$REPO"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "dist/$PACKAGE" > "dist/$PACKAGE.sha256"
    else
        shasum -a 256 "dist/$PACKAGE" > "dist/$PACKAGE.sha256"
    fi
)

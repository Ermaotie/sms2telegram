#!/bin/sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$REPO/build/ipk"
STAGE="$BUILD/data"
CONTROL="$BUILD/control"
PACKAGE=sms2telegram_1.0.0_all.ipk

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
if [ -n "${ROUTER_SECRET_FILE:-}" ]; then
    [ -r "$ROUTER_SECRET_FILE" ] || { echo "ROUTER_SECRET_FILE is unreadable" >&2; exit 1; }
    if find "$STAGE" -type f -exec grep -F -q -f "$ROUTER_SECRET_FILE" {} \; -print | grep -q .; then
        echo "refusing to package configured router secret" >&2
        exit 1
    fi
fi

(
    cd "$CONTROL"
    LC_ALL=C find . -type f -print | LC_ALL=C sort | \
        xargs tar --format ustar --uid 0 --gid 0 --numeric-owner -cf "$BUILD/control.tar"
)
(
    cd "$STAGE"
    LC_ALL=C find . -type f -print | LC_ALL=C sort | \
        xargs tar --format ustar --uid 0 --gid 0 --numeric-owner -cf "$BUILD/data.tar"
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

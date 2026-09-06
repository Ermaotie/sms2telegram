#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE="$ROOT/dist/sms2telegram_1.0.1_all.ipk"

fail() { echo "FAIL: $*" >&2; exit 1; }
digest() { shasum -a 256 "$PACKAGE" | awk '{print $1}'; }

sh "$ROOT/scripts/build-ipk.sh"
first=$(digest)
sleep 1
sh "$ROOT/scripts/build-ipk.sh"
second=$(digest)
[ "$first" = "$second" ] || fail "IPK bytes differ across fresh builds"

echo "PASS reproducible IPK across a clock boundary"

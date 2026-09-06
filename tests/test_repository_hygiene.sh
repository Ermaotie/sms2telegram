#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if ! git -C "$ROOT" check-ignore -q tg_setting.txt; then
    echo "FAIL: tg_setting.txt must be ignored to prevent accidental credential commits" >&2
    exit 1
fi

echo "PASS Telegram credential source is ignored by Git"

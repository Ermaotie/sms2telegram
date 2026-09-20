#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sms2telegram-openwrt.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] || fail "$3 (got '$1', want '$2')"
}

mode_of() {
    if value=$(stat -f '%Lp' "$1" 2>/dev/null); then
        printf '%s\n' "$value"
    else
        stat -c '%a' "$1"
    fi
}

mkdir -p "$TMP/etc/init.d" "$TMP/etc/config" "$TMP/usr/sbin"
cp "$ROOT/src/etc/init.d/sms2telegram" "$TMP/etc/init.d/sms2telegram"
cp "$ROOT/src/etc/config/sms2telegram" "$TMP/etc/config/sms2telegram"

cat > "$TMP/etc/rc.common" <<'EOF'
config_load() { :; }
config_get_bool() { eval "$1=1"; }
procd_open_instance() { opened=1; }
procd_set_param() {
    case "$1" in
        command) service_command=$2 ;;
        stdout) service_stdout=$2 ;;
        stderr) service_stderr=$2 ;;
        respawn) service_respawn="$2 $3 $4" ;;
        *) fail "unexpected procd parameter $1" ;;
    esac
}
procd_close_instance() { closed=1; }
procd_add_reload_trigger() { service_reload=$1; }
EOF

# shellcheck disable=SC1091
. "$TMP/etc/rc.common"
# shellcheck disable=SC1091
. "$TMP/etc/init.d/sms2telegram"
start_service
assert_eq "${service_command:-}" "/usr/sbin/sms2telegram" "service command"
assert_eq "${service_stdout:-}" "1" "stdout forwarding"
assert_eq "${service_stderr:-}" "1" "stderr forwarding"
assert_eq "${service_respawn:-}" "3600 5 5" "respawn policy"
service_triggers
assert_eq "${service_reload:-}" "sms2telegram" "reload trigger"

config() { :; }
option() { eval "cfg_$1=\${2-}"; }
# shellcheck disable=SC1091
. "$TMP/etc/config/sms2telegram"
config_get() {
    variable=$1
    key=$3
    default=${4-}
    eval "$variable=\${cfg_$key:-$default}"
}
config_get device main device
assert_eq "$device" "/dev/ttyACM0" "default device"
config_get storage main storage
assert_eq "$storage" "SM" "default storage"
config_get allowed_wan_device main allowed_wan_device
assert_eq "$allowed_wan_device" "eth0" "default allowed WAN device"
config_get poll_interval main poll_interval
assert_eq "$poll_interval" "15" "default poll interval"
config_get retry_initial main retry_initial
assert_eq "$retry_initial" "15" "default initial retry"
config_get retry_max main retry_max
assert_eq "$retry_max" "300" "default maximum retry"
config_get retain_count main retain_count
assert_eq "$retain_count" "3" "default retained SMS count"

assert_eq "$(mode_of "$ROOT/src/etc/init.d/sms2telegram")" "755" "init script mode"
assert_eq "$(mode_of "$ROOT/src/usr/sbin/sms2telegram")" "755" "daemon mode"

guide="$ROOT/src/usr/share/doc/sms2telegram/README.zh-CN.md"
[ -f "$guide" ] || fail "Chinese operations guide is missing"
for command in \
    "opkg install /tmp/sms2telegram_1.2.0_all.ipk" \
    "uci set sms2telegram.main.bot_token='123456:replace_with_real_token'" \
    "uci set sms2telegram.main.chat_id='-1001234567890'" \
    "uci commit sms2telegram" \
    "/etc/init.d/sms2telegram restart" \
    "logread -e sms2telegram" \
    "/etc/init.d/sms2telegram status" \
    "opkg remove sms2telegram"; do
    grep -F "$command" "$guide" >/dev/null || fail "guide omits: $command"
done
grep -F 'allowed_wan_device' "$guide" >/dev/null || fail "guide omits allowed_wan_device"
grep -F 'eth0' "$guide" >/dev/null || fail "guide omits eth0 requirement"
grep -F 'eth2' "$guide" >/dev/null || fail "guide omits eth2 prohibition"
grep -F '日志' "$guide" >/dev/null || fail "guide omits credential log safety"
grep -F '短信' "$guide" >/dev/null || fail "guide omits SMS safety"

echo "PASS OpenWrt service, defaults, permissions, and guide"

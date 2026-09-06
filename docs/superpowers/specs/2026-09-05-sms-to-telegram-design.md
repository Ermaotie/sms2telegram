# OpenWrt SMS to Telegram IPK Design

**Date:** 2026-09-05

## Goal

Build an installable OpenWrt IPK that reads incoming SMS messages from the attached Air780EPV modem and forwards them to a configured Telegram bot. The service must start automatically after router reboot, must retain a message until Telegram confirms delivery, and must never use the modem's SIM data connection for Telegram traffic.

## Verified Target Environment

- Router: FriendlyElec NanoPi R2S
- Firmware: ImmortalWrt 24.10.5, revision `r33805-7c4e882aaf6f`
- Target: `rockchip/armv8`
- Package architecture: `aarch64_generic`; the proposed package contains only portable Lua and shell code and can therefore use IPK architecture `all`
- Modem: Air780EPV, firmware `AirM2M_780EPV_V1009_LTE_AT`
- AT device: `/dev/ttyACM0`
- SIM status: ready; mobile network registration and PDP attachment are active
- Modem RNDIS device: `eth2`, currently not configured as an OpenWrt network interface
- Permitted router uplink: `eth0`
- Router proxy: OpenClash enabled in rule mode; router-originated Telegram traffic is already transparently proxied
- Available runtime dependencies: Lua 5.1, `nixio`, curl, CA certificates, `jsonfilter`, `sha256sum`, and OpenWrt `procd`

The supplied AirM2M AT manual documents `AT+CPMS`, `AT+CMGF`, `AT+CSCS`, `AT+CNMI`, `AT+CMGR`, `AT+CMGL`, and `AT+CMGD`. Live probing confirmed that this Air780EPV accepts text-mode SMS commands, offers `ME` and `SM` storage, and supports the `GSM`, `IRA`, and `UCS2` character sets.

## Chosen Approach

Use a lightweight Lua daemon managed by OpenWrt `procd`. Lua is already installed on the router, and `nixio` provides file-descriptor polling for the serial AT channel. The daemon invokes the installed curl client for Telegram HTTPS requests so the package does not need its own TLS implementation. Live implementation probing found that the target does not currently provide `stty`, so the IPK declares `coreutils-stty` as a dependency and treats a failed terminal setup as a hard initialization error.

The alternatives were rejected for the following reasons:

- A statically linked Go daemon would handle serial and HTTPS independently but would increase package size by several megabytes without providing a required capability.
- A shell-only daemon would be smaller but would make serial timeouts, unsolicited AT responses, multiline SMS parsing, and UCS2 decoding fragile.

## Package Contents

The output package is named `sms2telegram_1.0.0_all.ipk` and contains:

- `/usr/sbin/sms2telegram`: long-running Lua daemon and orchestration loop
- `/usr/lib/sms2telegram/core.lua`: pure parsing, UCS2 conversion, message formatting, route-result parsing, and retry calculations
- `/usr/lib/sms2telegram/at.lua`: bounded serial transport and modem commands
- `/usr/lib/sms2telegram/delivery.lua`: Telegram requests, storage-scoped fingerprints, and atomic confirmation ledger
- `/usr/lib/sms2telegram/worker.lua`: per-part route checks, delivery and delete ordering
- `/etc/sms2telegram/`: empty persistent state directory, staged mode `0700`; the runtime `delivered` file is neither shipped nor declared as a conffile
- `/etc/init.d/sms2telegram`: `procd` service definition with automatic respawn
- `/etc/config/sms2telegram`: UCI-style configuration owned and readable only by `root`
- `/usr/share/doc/sms2telegram/README.zh-CN.md`: Chinese installation, configuration, operation, and troubleshooting guide
- IPK control scripts that enable and start the service after installation and stop it during removal

The UCI configuration is treated as a conffile, so package upgrades and normal removal preserve the user's Bot Token and Chat ID.

## Configuration

Default configuration values are:

```text
config sms2telegram 'main'
    option enabled '1'
    option device '/dev/ttyACM0'
    option storage 'SM'
    option bot_token ''
    option chat_id ''
    option allowed_wan_device 'eth0'
    option poll_interval '15'
    option retry_initial '15'
    option retry_max '300'
```

The daemon validates configuration before touching SMS storage. When `bot_token` or `chat_id` is empty, it remains idle, does not read or delete messages, and periodically reloads configuration. Secrets and complete SMS bodies are never written to system logs.

## Service Lifecycle

The init script uses `USE_PROCD=1`, starts the daemon only when the UCI service is enabled, and configures `procd` respawn. Package installation creates the boot-time enablement link and starts the service. If Telegram credentials have not yet been configured, the running daemon waits safely as described above.

On router reboot, `procd` starts the service automatically. A process crash causes `procd` to restart it. Removal stops and disables the service while preserving `/etc/config/sms2telegram` as user configuration.

## Modem Initialization and SMS Acquisition

After valid Telegram configuration is available, the daemon opens `/dev/ttyACM0`, configures the terminal for raw 115200-baud I/O, and initializes the modem with bounded timeouts:

1. `AT` to verify communication.
2. `ATE0` to disable command echo.
3. `AT+CMEE=2` for descriptive modem errors.
4. `AT+CMGF=1` for text-mode SMS output.
5. `AT+CSCS="UCS2"` for deterministic Unicode representation.
6. `AT+CPMS="SM","SM","SM"` so received messages persist on the SIM storage queue.
7. `AT+CNMI=2,1,0,0,0` so new messages are stored and announced with `+CMTI` rather than delivered only as transient serial output.

The daemon keeps the AT port open. A `+CMTI` event triggers an immediate scan, while a 15-second periodic scan recovers notifications missed during reboot, modem reconnect, or daemon failure.

Each scan uses `AT+CMGL="ALL"`, not only `REC UNREAD`. Listing a message may change its state from unread to read; scanning all messages therefore ensures failed deliveries remain eligible for retry. Only structurally valid SMS-DELIVER records with `REC READ` or `REC UNREAD` status become incoming messages. The parser checks the DELIVER sender/timestamp layout; status alone is insufficient because SMS-STATUS-REPORT uses the same REC statuses. STO SENT/UNSENT and structurally valid STATUS-REPORT records are retained untouched and excluded from delivery, confirmation and deletion. A bodyless STATUS-REPORT is a complete record, while an incoming DELIVER requires at least one actual body line (an explicit blank line is allowed). A malformed incoming header or non-UCS2 serial body fails the scan closed. UCS2 hexadecimal values are converted to UTF-8.

The modem or SIM remains the authoritative pending-message queue. The daemon does not delete a message before confirmed Telegram delivery. Concatenated SMS behavior follows what the modem exposes in text mode: an assembled message is forwarded once; separately stored segments are forwarded as separate messages.

## Message Format

Telegram receives plain text without Markdown or HTML parsing. The SMS body appears first:

```text
短信正文

📩 短信信息
来自：+86138...
时间：2026-09-05 14:30:00
```

Untrusted SMS text is passed as data rather than shell syntax. The daemon writes each formatted part to a mode-`0600` temporary file and gives curl the fixed `--data-urlencode text@<file>` argument; it never interpolates the body into an executable command. Messages exceeding Telegram's per-message text limit are split at UTF-8 character boundaries, with sender and timestamp metadata included in every part. A stored SMS is considered delivered only after every part succeeds.

## Router-Only Egress and Proxy Behavior

The daemon must not activate, configure, or route through the modem's RNDIS interface. Before every Telegram request, including each individual multipart request, it runs `ip -4 route get 1.1.1.1`, parses the selected `dev` field, and permits sending only when that value exactly matches `allowed_wan_device`, whose default is `eth0`.

If the default route is absent, uses `eth2`, or uses any device other than the configured `eth0`, the daemon does not call Telegram. The SMS remains stored for a later retry. This fail-closed behavior protects against a future cellular failover route.

The curl request is not bound directly to `eth0`, because live verification showed that explicit interface binding bypasses the current OpenClash transparent proxy and cannot reach Telegram. Instead, the request enters the router's normal local-output path. OpenClash transparently applies its current rules, and its outbound connection follows the router's permitted default route. The service does not contain or log OpenClash credentials and does not fall back to the SIM interface.

## Delivery, Deletion, and Duplicate Control

For each stored SMS:

1. Compute a SHA-256 fingerprint from storage, index, sender, timestamp, and exact body.
2. If the persistent success ledger already contains that index and fingerprint, skip Telegram and retry only deletion.
3. Verify that the current default route uses `eth0`.
4. Call Telegram `sendMessage` using HTTPS, the configured Bot Token and Chat ID, and plain-text form data.
5. Require both a successful HTTP status and Telegram JSON field `ok: true` for every message part.
6. Atomically record the confirmed fingerprint in `/etc/sms2telegram/delivered`.
7. Delete the modem record with `AT+CMGD=<index>`.
8. Remove the ledger entry after the modem confirms deletion or after a later scan proves that the indexed message no longer exists.

This order prevents a confirmed message from being resent when modem deletion fails or the router reboots between Telegram success and deletion. If Telegram accepts a request but its response is lost before the router receives it, the daemon cannot prove success and may send the message again. The system therefore provides at-least-once delivery, preferring rare duplication over message loss.

The target's `/var` resolves to volatile `/tmp`, so confirmation state must live under persistent `/etc`. Before constructing a worker, ledger opening creates a missing parent directory, rejects a non-directory or symlink, repairs its permissions to `0700`, and verifies them. Preparation failure logs only category `ledger` and blocks scanning/sending/deletion for that cycle. Tests override the ledger path to an isolated `/tmp` directory, including first-start and process-restart cases.

A multipart SMS is confirmed only after every part succeeds. If a later part fails or its route becomes disallowed, no confirmation is written and the stored SMS is retained. A later retry starts again from the first part, so previously accepted parts can appear twice.

The ledger contains one tab-separated `<index>\t<sha256>` record per confirmed but not-yet-deleted SMS. It is rewritten through a mode-`0600` temporary file followed by atomic rename to avoid corruption during power loss. If an SMS index is reused for different content, the fingerprint differs and the new message is not mistaken for the old one.

## Error Handling

- Missing Bot Token or Chat ID: remain idle and reload configuration; do not access SMS records.
- AT device missing or modem disconnected: close the descriptor, wait, and reopen without terminating the service.
- AT timeout, `ERROR`, or `+CMS ERROR`: retain the SMS and reinitialize the modem before retrying.
- Default route not exactly `eth0`: block Telegram transmission and retain the SMS.
- OpenClash unavailable, DNS failure, TLS failure, timeout, non-success HTTP response, or Telegram `ok` not true: retain the SMS.
- Telegram authorization or Chat ID errors: retain the SMS and use the same capped retry policy; log the error category without exposing credentials or SMS text.
- Storage full while Telegram is unavailable: log a warning. The service cannot create more modem capacity without violating the no-delete-before-delivery rule.
- Invalid UCS2 or malformed modem output: do not delete the record; log its index and retry after modem reinitialization.

Transient failures start at a 15-second delay and double up to 300 seconds. Receipt of a new `+CMTI` wakes the scanner but does not bypass the route or retry safety checks.

## Security

- `/etc/config/sms2telegram` is mode `0600` and owned by `root`.
- Bot Token, Chat ID, proxy credentials, and full SMS body are excluded from logs.
- Telegram messages use no parse mode, preventing SMS text from injecting Telegram markup.
- SMS content is supplied through a protected mode-`0600` temporary file, never shell interpolation.
- Temporary files are mode `0600` and removed after each request.
- The route policy fails closed: an unknown or changed default device blocks delivery.

## Testing and Verification

Development follows test-first cycles. Pure Lua tests run on the router's actual Lua 5.1 runtime from `/tmp` and cover:

- English and UCS2 Chinese SMS parsing
- Multiline body preservation
- Body-first Telegram formatting
- UTF-8-safe Telegram length splitting
- Malformed `+CMGL` responses
- Successful and unsuccessful Telegram response classification
- Parsing routes that allow `eth0` and rejecting `eth2`, missing routes, and unknown devices
- Retry backoff limits
- Delivered-ledger matching and index reuse
- First-start parent creation, `0700` directory repair, and disk-backed delete-only recovery after daemon restart
- Numeric nixio write errors (`false/nil, errno, message`), bounded EAGAIN/EWOULDBLOCK retries and partial writes
- Mixed outgoing/status-report/incoming CMGL frames and per-part route changes

Integration checks use the real Air780EPV AT device but initially issue only non-destructive identification and capability queries. IPK verification checks control metadata, conffile declarations, ownership and modes, init-script syntax, package extraction, and install/remove script behavior in a temporary root.

The final IPK is not installed on the router and no real Telegram message is sent unless the user explicitly authorizes those actions. The handoff includes checksums and exact Chinese commands for installation, credential configuration, service restart, status inspection, and uninstall.

## Acceptance Criteria

- `opkg` recognizes and installs `sms2telegram_1.0.0_all.ipk` on the verified ImmortalWrt target.
- The service is enabled at boot and managed by `procd` with respawn.
- With credentials absent, no SMS is read or deleted.
- With credentials present, new and reboot-surviving stored SMS records are forwarded with body first and metadata afterward.
- Telegram delivery is attempted only while the selected default route device is exactly `eth0`.
- Existing OpenClash transparent proxy behavior remains untouched and is used by router-originated Telegram requests.
- A message is deleted from the modem only after Telegram reports success.
- Failed sends survive service restart and router reboot.
- Confirmed delivery followed by deletion failure does not normally resend the same indexed message.
- English, Chinese UCS2, multiline text, route rejection, retry, and package-layout tests pass.

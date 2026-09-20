# sms2telegram for OpenWrt

从连接在 OpenWrt 路由器上的 Air780EPV 4G 模块读取入站短信，并通过路由器网络转发到 Telegram Bot。

## 功能

- Telegram 消息以短信正文开头，发件号码和时间放在正文之后。
- 使用带长度和编码标识的 PDU 模式读取，避免把正文中的 `OK` 或纯数字误判为协议数据。
- 对部分验证码平台产生的异常时间戳和 GSM 7-bit 位移提供兼容恢复；恢复成功时仍会转发正文，时间标记为未知。
- 在已配置的 Telegram 聊天中发送 `/status`，可查看服务、串口、网络出口和最近扫描状态。
- 只处理入站短信，不转发发件箱记录和短信状态报告。
- 每次发送（包括长短信的每一段）都检查网络出口，仅允许 `eth0`。
- 明确禁止使用 4G 模块的 RNDIS/SIM 数据接口 `eth2`。
- 请求经过路由器正常网络栈，可使用 OpenClash 等透明代理。
- Telegram 成功接收后仍在 SIM 中保留最新 3 条入站短信，第 4 条到来时才删除最旧的一条。
- 发送确认和保留顺序持久化保存，路由器重启后不会重复转发已缓存短信。
- 使用 OpenWrt `procd` 管理，安装后自动启用并随路由器启动。
- Bot Token、Chat ID 和短信正文不会写入系统日志。

## 已验证环境

- FriendlyElec NanoPi R2S
- ImmortalWrt 24.10.5（`rockchip/armv8`）
- Air780EPV，AT 串口 `/dev/ttyACM0`
- 路由器上网出口 `eth0`
- 模块 RNDIS/SIM 接口 `eth2`
- OpenClash 透明代理

安装包由 Lua 和 Shell 编写，架构为 `all`。其他 OpenWrt 设备也可以使用，但建议先确认串口路径、短信存储区和网络接口名称。

## 下载

从 [Releases](https://github.com/Ermaotie/sms2telegram/releases) 下载：

- `sms2telegram_1.1.1_all.ipk`
- `sms2telegram_1.1.1_all.ipk.sha256`

可在电脑上校验文件：

```sh
shasum -a 256 -c sms2telegram_1.1.1_all.ipk.sha256
```

Linux/OpenWrt 也可使用：

```sh
sha256sum -c sms2telegram_1.1.1_all.ipk.sha256
```

## 安装

先把 IPK 上传到路由器 `/tmp`，然后执行：

```sh
opkg install /tmp/sms2telegram_1.1.1_all.ipk
```

软件包会安装以下依赖：

- `lua`
- `luci-lib-nixio`
- `luci-lib-jsonc`
- `coreutils-stty`
- `curl`
- `ca-bundle`
- `jsonfilter`

## 配置 Telegram Bot

首次使用前，请先在 Telegram 中打开你的 Bot 并发送 `/start`。Bot 无法主动联系一个从未开始过会话的用户；此时 Telegram 会返回 `chat not found`。

将示例中的 Token 和 Chat ID 替换为真实值：

```sh
uci set sms2telegram.main.bot_token='123456:replace_with_real_token'
uci set sms2telegram.main.chat_id='-1001234567890'
uci commit sms2telegram
/etc/init.d/sms2telegram restart
```

请勿把真实 Token 提交到 Git、粘贴到日志或放进截图。配置文件安装权限为 `0600`，仅 root 可读写。

未填写 Token 或 Chat ID 时，服务会保持等待，不读取或删除短信。

## 网络出口保护

默认配置只允许：

```text
allowed_wan_device=eth0
```

服务在每次请求 Telegram 前检查当前路由。出口不是准确的 `eth0`、路由不存在，或切换为 `eth2` 时，发送会被拒绝，短信保留等待重试。

请不要把 `allowed_wan_device` 改成模块的 SIM 数据接口。服务不会主动配置或启用 `eth2`。

Telegram 请求不会强制绑定 `eth0`，因此仍会进入路由器正常的本机输出链路，让 OpenClash 等透明代理按现有规则处理；出口检查则负责阻止 SIM 流量。

## 服务管理

```sh
# 查看状态
/etc/init.d/sms2telegram status

# 查看日志
logread -e sms2telegram

# 重启
/etc/init.d/sms2telegram restart

# 设置开机启动
/etc/init.d/sms2telegram enable

# 停止
/etc/init.d/sms2telegram stop
```

服务由 `procd` 自动拉起。确认记录和缓存顺序保存在 `/etc/sms2telegram/delivered`，不会包含短信正文。

向已配置的 Bot 私聊发送 `/status`，服务会返回当前版本、运行时长、4G 模块连接、
串口、网络出口及最近一次短信扫描状态。命令只响应配置中的数字 `chat_id`；其他聊天会被忽略。

## 默认配置

```text
device=/dev/ttyACM0
storage=SM
allowed_wan_device=eth0
poll_interval=15
retry_initial=15
retry_max=300
retain_count=3
```

`retain_count` 表示成功转发后在 SIM 中保留的最新入站短信数量，默认值为 `3`。
保留的短信不会重复转发；新短信使数量超过该值时，服务只删除最旧的已确认短信。

如模块使用其他 AT 串口，可修改：

```sh
uci set sms2telegram.main.device='/dev/ttyACM0'
uci commit sms2telegram
/etc/init.d/sms2telegram restart
```

## 消息格式

```text
短信正文

📩 短信信息
来自：+86138...
时间：2026-09-05 14:30:00
```

超长短信会按 UTF-8 字符边界拆分，每一段都包含来源信息。若后续分段发送失败，短信不会删除；下次会从第一段重试，因此极端情况下前几段可能重复。

## 故障排查

服务没有转发短信时，依次检查：

1. `/dev/ttyACM0` 是否存在。
2. Bot Token 和 Chat ID 是否正确。
3. 当前路由出口是否为 `eth0`。
4. OpenClash 或路由器自身网络是否能够访问 Telegram。
5. `logread -e sms2telegram` 中的错误类别。

日志不会主动输出 Token、Chat ID 或完整短信正文。分享日志前仍建议人工检查敏感信息。

## 卸载

```sh
opkg remove sms2telegram
```

卸载时服务会停止并取消开机启动。OpenWrt 会保留用户修改过的 UCI 配置，重新安装前如不再需要，请自行删除 `/etc/config/sms2telegram`。

## 从源码构建

在 macOS 或 Linux 上执行：

```sh
sh scripts/build-ipk.sh
```

输出文件位于 `dist/`。构建脚本只打包声明过的运行时文件，并检查本地路由器与 Telegram 凭据是否意外混入安装包。

## 安全说明

- 路由策略默认拒绝未知或非 `eth0` 出口。
- Telegram 返回失败时不删除短信；发送成功后默认保留最新 3 条。
- 串口异常、解析失败或确认记录不可用时停止发送并保留短信。
- Telegram 采用至少一次投递策略：在请求已被 Telegram 接收但响应丢失的极端情况下，可能产生重复消息，以避免短信丢失。

## 许可证

本项目暂未声明开源许可证。未经许可，请不要假定拥有复制、修改或再分发权利。

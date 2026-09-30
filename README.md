# sms2telegram for OpenWrt

Air780EP/Air780EPV 在 LuatOS 内接收、解码并合并短信，通过 USB
`uart.VUART_0` 输出单行 UTF-8 JSON；NanoPi R2S 只负责读取 JSON、去重、重试并转发
Telegram。

## 架构

旧链路已经移除：

```text
OpenWrt AT+CNMI/+CMTI -> AT+CMGL/CMGR -> PDU parser -> Telegram
```

当前链路：

```text
SIM -> LuatOS sms.setNewSmsCb -> uart.VUART_0 JSONL
    -> OpenWrt /dev/ttyACM* -> Telegram
```

AT 控制口仍可选地用于 `AT+CSQ` 和 `AT+CEREG?` 状态查询，但不再执行任何短信 AT
命令，也不能和 VUART 配成同一设备。

协议每行一条 JSON，以 `\n` 结束。正文中的真实换行由 `json.encode` 转义，不会破坏
分帧：

```json
{"type":"ready","project":"sms_gateway","version":"1.0.0"}
{"type":"sms","number":"+8610086","text":"测试短信","timestamp":"2026-09-30 21:30:00","message_id":"20260930213000_+8610086_1"}
```

## Air780EP/Air780EPV LuatOS

完整脚本位于 [`luatos/sms_gateway/main.lua`](luatos/sms_gateway/main.lua)。使用 LuaTools 将
该目录的 `main.lua` 与支持 `sms` 的 LuatOS-SoC 固件一起烧录。脚本会：

- 初始化 `uart.VUART_0` 为 115200/8N1；
- 输出一次 `ready`；
- 在固件支持时显式开启 `sms.autoLong(true)`，并注册
  `sms.setNewSmsCb(function(num, txt, metas) ...)`；
- 优先使用 `metas` 中的短信时间，缺失时回退到 `os.date`；
- 使用固件内置 `json.encode` 保证中文、特殊字符和换行正确转义。

API 依据：[LuatOS SMS](https://docs.openluat.com/osapi/core/sms/)、
[UART](https://docs.openluat.com/osapi/core/uart/)、
[JSON](https://docs.openluat.com/osapi/core/json/)。

## 识别 VUART 设备

项目采用“单一 UCI 配置项”，不盲扫并打开所有 `/dev/ttyACM*`，因为候选端口还可能是
AT 或调试口，而且 `ready` 是启动事件。首次部署时：

1. 停止服务：`/etc/init.d/sms2telegram stop`。
2. 执行 `ls -l /dev/ttyACM*`，逐个候选口以 115200/8N1 读取。
3. 读取期间重启 Air780EPV；出现 `{"type":"ready","project":"sms_gateway",...}` 的端口
   就是 `uart.VUART_0`。
4. 将该路径只写入 `sms_device`。若系统提供稳定的 hotplug/udev 符号链接，优先配置该链接。

例如确认 VUART 是 `/dev/ttyACM2`：

```sh
uci set sms2telegram.main.sms_device='/dev/ttyACM2'
uci set sms2telegram.main.device='/dev/ttyACM0' # 可选 AT 诊断口
uci commit sms2telegram
```

## 构建与部署

```sh
sh scripts/build-ipk.sh
scp dist/sms2telegram_2.0.0_all.ipk root@ROUTER:/tmp/
ssh root@ROUTER 'opkg install /tmp/sms2telegram_2.0.0_all.ipk'
```

配置 Telegram 和路由出口：

```sh
uci set sms2telegram.main.bot_token='123456:replace_with_real_token'
uci set sms2telegram.main.chat_id='-1001234567890'
uci set sms2telegram.main.allowed_wan_device='eth0'
uci set sms2telegram.main.sms_device='/dev/ttyACM2'
uci commit sms2telegram
/etc/init.d/sms2telegram restart
```

`device` 是可选 AT 诊断口；不需要信号/注册状态时可设为空。`sms_device` 必须是 VUART，且
两者不能相同。服务由 procd 拉起，串口读/open/HUP 失败后按 `retry_initial` 到
`retry_max` 自动退避重连。非法 JSON 只记录 warning。Telegram 失败时消息留在内存队列，
继续读取串口并按相同策略重试。最近 200 条“号码 + 时间 + 正文”用于内存去重。

```sh
logread -e sms2telegram
/etc/init.d/sms2telegram status
```

典型日志：

```text
[sms-uart] connected: /dev/ttyACM2
[sms-uart] Air780EPV ready
[sms] received from 10086
[sms] forwarded to Telegram
[sms] duplicate ignored
[sms-uart] disconnected: serial hangup
[sms-uart] reconnecting in 15s
```

## 测试

本机不依赖串口硬件的测试：

```sh
lua tests/test_core.lua src
lua tests/test_at.lua src
lua tests/test_serial.lua src
lua tests/test_vuart.lua src
lua tests/test_worker.lua src
sh tests/test_openwrt.sh
sh tests/test_router_smoke.sh
sh scripts/build-ipk.sh
sh tests/test_package.sh dist/sms2telegram_2.0.0_all.ipk
```

路由器联调（先重启模组，让它重新输出 `ready`）：

```sh
AT_DEVICE=/dev/ttyACM0 SMS_DEVICE=/dev/ttyACM2 \
  STTY_BIN=/usr/bin/stty sh tests/router-smoke.sh
```

必须完成以下实机用例：

1. 发送 `hello`，VUART 得到一行 `type=sms` JSON，Telegram 正常收到。
2. 发送 `测试中文短信123`，确认 UTF-8 无乱码。
3. 发送 `【测试】验证码 123456，5分钟内有效。`，确认内容完全一致。
4. 发送长短信，确认 LuatOS 合并后只输出一次完整正文。
5. 运行中拔插 USB，确认出现 disconnected/reconnecting/connected，随后仍可收短信。
6. 重启 Air780EPV，确认收到新的 `ready`，NanoPi 服务无需重启。
7. 向 VUART 测试源注入 `abc` 或 `{bad json`，确认只记录 warning，进程不退出。

## 已知风险

- `ready` 只在 LuatOS 启动时发送，因此首次辨认端口时需要在监听期间重启模组。
- 待转发队列和 200 条去重缓存只在内存中；NanoPi 进程或整机在 Telegram 故障期间重启，
  尚未发送的事件无法恢复。只有实测需要崩溃一致性时再增加小型磁盘 spool。
- 长短信合并和 GSM7/UCS2 解码取决于所烧录 LuatOS 固件，建议使用官方当前支持
  `sms.setNewSmsCb`/`sms.autoLong` 的固件。

# sms2telegram OpenWrt 使用指南

本版本只从 Air780EP/Air780EPV LuatOS 的 `uart.VUART_0` 接收单行 JSON，不再用
`AT+CNMI`、`+CMTI`、`AT+CMGL/CMGR` 或 PDU 解析收短信，也不再打开 AT 口。

## 安装

先用 LuaTools 烧录仓库 `luatos/sms_gateway/main.lua`，再安装 IPK：

```sh
opkg install /tmp/sms2telegram_2.1.0_all.ipk
uci set sms2telegram.main.bot_token='123456:replace_with_real_token'
uci set sms2telegram.main.chat_id='-1001234567890'
uci set sms2telegram.main.sms_device='/dev/ttyACM2'
uci set sms2telegram.main.allowed_wan_device='eth0'
uci commit sms2telegram
/etc/init.d/sms2telegram restart
```

首次识别 VUART：停止服务，逐个监听 `/dev/ttyACM*`，监听期间重启模组；输出
`{"type":"ready","project":"sms_gateway",...}` 的端口就是 `sms_device`。OpenClash 等
代理可以继续使用，但默认路由必须是允许的 `eth0`，
不能走 SIM 数据口 `eth2`。

## 运维

```sh
logread -e sms2telegram
/etc/init.d/sms2telegram status
/etc/init.d/sms2telegram restart
/etc/init.d/sms2telegram enable
/etc/init.d/sms2telegram stop
opkg remove sms2telegram
```

服务会自动处理半条/多条 JSON、空行、非法 JSON、USB 断开和重新枚举。Telegram 失败会
保留内存队列并退避重试；收到的短信持久化在 `/etc/sms2telegram/messages.jsonl`，文件
权限为 `0600`。日志不会输出 Telegram 凭据，也不会重复打印短信正文。

机器人命令：

- `/status` 查看服务状态、已保存短信数量和保留策略；
- `/list` 列出全部短信，`/list 关键词` 按号码、时间或正文过滤；
- `/clear` 删除全部已保存短信；
- `/cycle 30` 只保留最近 30 天短信；
- `/cycle off` 关闭循环清理并保留全部短信；
- `/cycle` 查看当前保留策略。

实机至少验证英文、中文、验证码、长短信、USB 拔插、模组重启和非法 JSON 七个场景。
待发送队列与最近 200 条去重记录仍只在内存中；持久化短信可通过 `/list` 查询，但不会在
进程重启后自动重新发送。

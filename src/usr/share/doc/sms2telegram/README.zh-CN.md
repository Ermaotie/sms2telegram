# sms2telegram OpenWrt 使用指南

本版本只从 Air780EP/Air780EPV LuatOS 的 `uart.VUART_0` 接收单行 JSON，不再用
`AT+CNMI`、`+CMTI`、`AT+CMGL/CMGR` 或 PDU 解析收短信。AT 口仅保留信号和注册状态查询。

## 安装

先用 LuaTools 烧录仓库 `luatos/sms_gateway/main.lua`，再安装 IPK：

```sh
opkg install /tmp/sms2telegram_2.0.0_all.ipk
uci set sms2telegram.main.bot_token='123456:replace_with_real_token'
uci set sms2telegram.main.chat_id='-1001234567890'
uci set sms2telegram.main.sms_device='/dev/ttyACM2'
uci set sms2telegram.main.device='/dev/ttyACM0'
uci set sms2telegram.main.allowed_wan_device='eth0'
uci commit sms2telegram
/etc/init.d/sms2telegram restart
```

首次识别 VUART：停止服务，逐个监听 `/dev/ttyACM*`，监听期间重启模组；输出
`{"type":"ready","project":"sms_gateway",...}` 的端口就是 `sms_device`。它不能与 AT
诊断口 `device` 相同。OpenClash 等代理可以继续使用，但默认路由必须是允许的 `eth0`，
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
保留内存队列并退避重试；日志不会输出 Telegram 凭据，也不会重复打印短信正文。

实机至少验证英文、中文、验证码、长短信、USB 拔插、模组重启和非法 JSON 七个场景。
待发送队列与最近 200 条去重记录只在内存中，NanoPi 进程重启会丢失尚未转发的事件。

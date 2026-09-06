# sms2telegram OpenWrt 使用指南

本服务从 Air780EPV 读取短信，并通过路由器的 Telegram 连接转发。安装后由
OpenWrt `procd` 管理并随系统启动。

模块使用 PDU 模式读取短信，并优先按 TPDU 长度和 DCS 编码解析。若验证码平台
产生异常时间戳并伴随 GSM 7-bit 位移，服务会从多个位移中选择可读度最高的正文；
恢复成功时继续转发，并将时间标为“未知（原始短信时间异常）”。

## 安装和配置

首次使用前，请先在 Telegram 中打开 Bot 并发送 `/start`。Bot 无法主动联系一个
从未开始过会话的用户；此时 Telegram 会返回 `chat not found`。

在路由器上执行：

```sh
opkg install /tmp/sms2telegram_1.0.3_all.ipk
uci set sms2telegram.main.bot_token='123456:replace_with_real_token'
uci set sms2telegram.main.chat_id='-1001234567890'
uci commit sms2telegram
/etc/init.d/sms2telegram restart
```

上面的 Token 和 Chat ID 仅是格式占位符。请替换为真实凭据；不要把真实凭据
粘贴到日志、工单或截图中。配置文件由 root 保护，修改后用 `uci commit` 保存。

本路由器的允许出口必须保持为 `eth0`：配置中的
`allowed_wan_device` 不得改成其他接口。`eth2` 是调制解调器的 RNDIS/SIM
数据接口，明确禁止用于 Telegram 出口；服务发现默认路由不是 `eth0` 时会
拒绝发送并保留短信。

未配置 Bot Token 或 Chat ID 时，服务只等待配置，不读取、删除或触碰短信。
因此可以先安装服务，再完成凭据配置。服务只在 Telegram 确认成功后删除调制
解调器中的短信，发送失败的短信会留在队列中等待重试。

确认记录保存在 `/etc/sms2telegram/delivered`，可以跨重启保留；本机 `/var`
指向临时存储，因此不用于确认记录。安装包创建权限为 `0700` 的状态目录，服务
启动时也会补建或修复目录权限；准备失败会记录 `ledger` 错误并暂停发送。
记录文件仅在运行时生成，权限为 `0600`，不包含短信正文，也不随安装包分发。

已发送但尚未成功删除的短信，在重启后只重试删除。超长短信每一段发送前都检查
出口；若后续段失败或出口改变，短信仍会保留，下次从第一段重试，因此已收到的
前几段可能重复。服务只转发入站短信，发件箱记录和短信状态报告会保留不动。

## 检查和卸载

```sh
logread -e sms2telegram
/etc/init.d/sms2telegram status
opkg remove sms2telegram
```

日志只用于记录服务状态和错误类别。请在收集 `logread` 输出或截图前确认其
中没有 Token、Chat ID 和短信正文；不要主动打印这些敏感信息。

如果服务未运行，先确认 `/dev/ttyACM0` 存在、配置中的出口仍为 `eth0`，再查看
上面的日志。卸载会停止并禁用服务；UCI 配置作为用户配置保留，便于重新安装。

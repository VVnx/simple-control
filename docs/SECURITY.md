# RC001-Viber HID Helper 安全边界

## 为什么需要 root Helper

普通 macOS 应用即使获得“输入监控”，也可能在调用 `IOHIDManagerOpen(..., kIOHIDOptionsTypeSeizeDevice)` 时收到 `kIOReturnNotPrivileged`。结果是应用能看到按键，却不能阻止 RC001 的 Keyboard Power 事件继续进入系统。root Helper 的唯一目的，是独占目标遥控器的键盘集合并屏蔽原始按键。

## 能做什么

- 只匹配 Vendor ID `0x2717`、Product ID `0x32B8`、Generic Desktop / Keyboard；
- 独占打开该 HID 集合；
- 识别 F5 与 Keyboard Power；
- 向本机客户端广播三种固定事件：`voice_down`、`voice_up`、`power`；
- 写入 `/var/run/rc001-viber-hid.status`，供权限页显示接管状态。

## 不能做什么

- 没有网络代码；
- 不读取用户文件、剪贴板、键盘文本或其他 HID 设备；
- 不执行 shell 命令；
- 不接收来自主应用或其他客户端的控制命令；
- 不生成键盘事件、不启动 Codex；这些动作留在普通用户权限的主应用中完成。

## 安装位置

- Helper：`/Applications/RC001-Viber HID Helper.app`
- LaunchDaemon：`/Library/LaunchDaemons/com.wangxi.RC001Viber.HIDHelper.plist`
- 本地事件 socket：`/var/run/rc001-viber-hid.sock`
- 状态文件：`/var/run/rc001-viber-hid.status`
- 日志：`/var/log/rc001-viber-hid.log`

Helper 应用与 LaunchDaemon 由安装器设为 `root:wheel` 且不可由普通用户修改。socket 允许普通用户连接，但服务端只发送固定事件，从不读取客户端数据。

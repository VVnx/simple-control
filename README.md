# RC001-Viber

让小米 RC001-MS 蓝牙语音遥控器在 macOS 上同时成为可配置遥控器和系统麦克风，替代本设备对应的 Karabiner 规则。

## 已验证能力

- 识别本机 `小米蓝牙语音遥控器`（VID `0x2717`，PID `0x32B8`）；
- 连接 Google ATV Voice over BLE 服务并订阅控制/音频通知；
- 接收实机 16 kHz、16-bit mono、4:1 IMA ADPCM 音频；
- 解码语音并保存为 WAV，实测首段 1.44 秒、23040 个样本，峰值约 -6.9 dB；
- 将解码音频实时升采样到 48 kHz，并写入跨进程环形缓冲区；
- 构建 Core Audio Audio Server Plug-in，向系统提供 `RC001 Remote Microphone`；
- 按实际音源声明为蓝牙麦克风，兼容会过滤通用虚拟设备的输入法麦克风选择器；
- 按设备接管 HID：语音键映射为右 Control，开关键打开 Codex；
- 通过常驻 root HID Helper 独占目标键盘集合，避免开关键继续进入 macOS；
- 使用稳定的 Developer ID 签署主应用、HID Helper 和音频驱动，避免升级后输入监控授权因临时签名变化而失效；
- 提供菜单栏状态与可视化映射页。
- 提供独立的“权限检查与授权”页面，逐项检查 HID Helper、辅助功能、蓝牙和虚拟麦克风；
- 在按键尚未独占接管时明确提示不要测试开关键，避免触发 macOS 关机菜单。

当前安装包已在实机完成系统级驱动安装、BLE 语音接收和虚拟麦克风枚举验证。

## 默认映射

| 遥控器输入 | macOS 动作 |
| --- | --- |
| 语音键（HID F5）按下/松开 | 右 Control 按下/松开，用于豆包输入法语音输入 |
| 开关键（HID Keyboard Power） | 打开 Codex |
| 遥控器麦克风 | `RC001 Remote Microphone` 系统输入设备 |

## 构建与测试

```bash
cd ~/simple-control
swift test
./build_probe_app.sh
./build_hid_helper_app.sh
./build_audio_driver.sh
./build_installer_pkg.sh
```

构建脚本会优先使用 `RC001_CODE_SIGN_IDENTITY` 指定的签名证书；未指定时自动选择本机可用的 `Developer ID Application`。没有 Developer ID 时仍可回退到 ad-hoc 签名，但输入监控权限可能在重新构建后需要再次授权。

产物位于 `dist/`：

- `RC001-Viber.app`：菜单栏应用、按键映射、BLE 语音接收；
- `RC001-Viber HID Helper.app`：只接管 RC001 键盘集合的 root Helper；
- `RC001 Remote Microphone.driver`：Core Audio 虚拟输入驱动；
- `RC001-Viber-0.1.6.pkg`：安装以上组件、注册按键接管服务并重启音频服务。

安装后首次运行需要在“隐私与安全性”中允许：

1. 蓝牙：连接遥控器并读取语音服务；
2. 输入监控：点击“+”添加 `/Applications/RC001-Viber HID Helper.app` 并开启；
3. 辅助功能：给 `/Applications/RC001-Viber.app` 生成右 Control 按键事件的权限。

输入监控只授予独立 Helper，不需要授予 RC001-Viber 主应用。权限页会读取 Helper 的实时状态；只有显示“已接管”后，才应测试开关键。

Karabiner 若仍抓取 RC001，会导致独占打开失败。迁移时应先让 Karabiner 忽略该设备或退出 Karabiner，再启动 RC001-Viber。

## 按键接管架构

`RC001-Viber HID Helper` 由系统 LaunchDaemon 以 root 运行，只匹配以下 HID 键盘集合：

- Vendor ID：`0x2717`
- Product ID：`0x32B8`
- Primary Usage：Generic Desktop / Keyboard

Helper 不联网、不读取用户文件，也不接受主应用命令。它仅通过 root 创建的本地 Unix socket 向主应用发送 `voice_down`、`voice_up`、`power` 三种事件。主应用负责生成右 Control 或打开 Codex。安全边界与安装位置详见 [`docs/SECURITY.md`](docs/SECURITY.md)。

## 运行数据

日志与诊断 WAV 保存在：

```text
~/Library/Application Support/RC001MacBridge/
```

菜单栏遥控器图标中可以打开：

- 遥控器和麦克风状态；
- “映射与状态”可视化页面；
- 录音目录；
- macOS 隐私设置。

## 项目结构

- `Sources/RC001Core/`：协议解析、IMA ADPCM 解码、WAV 与共享音频写入；
- `Sources/RC001SharedAudio/`：应用/驱动共用的无锁跨进程音频环；
- `Sources/RC001Probe/`：BLE 接收、HID 映射和菜单栏界面；
- `Sources/RC001HIDHelper/`：root HID 独占接管与最小事件转发；
- `Sources/RC001HIDBridgeProtocol/`：Helper 与主应用之间的只读事件协议；
- `Driver/`：基于 Apple NullAudio 示例改造的 Audio Server Plug-in；
- `docs/PROTOCOL.md`：设备协议与实机验证记录。

驱动基础代码来自 Apple 的 `Creating an Audio Server Driver Plug-in` 示例，按其 MIT 许可证使用；许可证保存在 `Driver/LICENSE-APPLE-SAMPLE.txt`。

## 开源协议

RC001-Viber 使用 [MIT License](LICENSE) 开源。Apple Audio Server Plug-in 示例代码的原始版权和许可声明继续保留在 `Driver/LICENSE-APPLE-SAMPLE.txt`。

# RC001 / 小米语音遥控器协议笔记

## 本机设备

- 蓝牙名称：`小米蓝牙语音遥控器`
- Vendor ID：`0x2717`（10007）
- Product ID：`0x32B8`（12984）
- 固件：2671
- macOS 原生只把它注册为 BLE HID 键盘；语音不会自动进入 Core Audio。

## Google ATV Voice over BLE 1.0

| 角色 | UUID | 属性 |
| --- | --- | --- |
| Voice Service | `AB5E0001-5A21-4F05-BC7D-AF01F617B664` | Service |
| Host -> Remote | `AB5E0002-5A21-4F05-BC7D-AF01F617B664` | Write without response |
| Remote -> Host Audio | `AB5E0003-5A21-4F05-BC7D-AF01F617B664` | Notify |
| Remote -> Host Control | `AB5E0004-5A21-4F05-BC7D-AF01F617B664` | Notify |

控制命令：

- `GET_CAPS = 0x0A`
- `MIC_OPEN = 0x0C`
- `MIC_CLOSE = 0x0D`
- `AUDIO_STOP = 0x00`
- `AUDIO_START = 0x04`
- `START_SEARCH = 0x08`
- `AUDIO_SYNC = 0x0A`
- `CAPS_RESP = 0x0B`

音频数据为 8 kHz 或 16 kHz、16-bit mono，使用 4:1 IMA ADPCM；每字节先解码高四位，再解码低四位。`AUDIO_SYNC` 可重置 predictor 和 step index。

## 实机验证结果（2026-08-14）

1. CoreBluetooth 能取回已连接遥控器：通过。
2. 真实设备暴露 `AB5E...` Voice Service：通过。
3. 音频/控制 Notify 订阅：通过。
4. `GET_CAPS` 返回 `CAPS_RESP`：`01 00 02 00 00 78 00 00`，支持 16 kHz ADPCM，帧长 120 字节。
5. 实机按语音键直接返回 `AUDIO_START 04 03 02 <stream-id>`，不需要主机先收到 `START_SEARCH`。
6. 每个 120 字节 ADPCM 帧解码为 240 个 PCM 样本；第一段收到 96 帧、23040 样本、1.44 秒。
7. WAV 经 macOS `afinfo` 验证为 16 kHz、Int16、单声道；幅度峰值约 -6.9 dB，RMS 约 -36.0 dB。

## 后续系统集成

- 按键层：IOHIDManager 按 VID/PID 独占设备，读取 16-bit Keyboard Usage 数组；`0x3E` 为 F5，`0x66` 为 Keyboard Power。
- 音频层：常驻进程负责 BLE 握手、ADPCM 解码，并把 8/16 kHz PCM 实时升采样到 48 kHz。
- 共享层：C11 原子计数器保护 10 秒环形缓冲区；每次 `AUDIO_START` 增加 generation，驱动从该流起点读取。
- 虚拟麦克风：Audio Server Plug-in 从共享环读取 Float32 stereo PCM，并注册 `RC001 Remote Microphone`。

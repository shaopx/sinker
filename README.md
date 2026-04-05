# Sinker

通过 **ADB TCP 隧道**将文件从 PC 安全传输到 Android 设备的工具。

不使用 `adb push`，而是通过 `adb forward` 建立 TCP 隧道后经 Socket 传输，规避监控软件对 `adb push` 命令的检测。

---

## 特性

- **隐蔽传输**：仅使用 `adb forward`（端口转发），监控软件看不到实际传输内容
- **ZIP 压缩**：自动压缩，节省传输时间
- **可选加密**：支持 XOR 混淆（~800MB/s）或 AES-256-GCM（密码保护）
- **大文件支持**：全流式传输，1GB+ 目录无 OOM，内存峰值仅约 1MB
- **完整性校验**：SHA-256 校验，确保数据无损
- **自定义协议**：14 字节二进制包头 + CRC-16 校验

---

## 项目结构

```
sinker/
├── packages/
│   ├── sinker_core/        # 共享核心库（协议、加密、压缩、传输）
│   └── sinker_adb/         # ADB 命令封装（PC 专用）
└── apps/
    ├── sinker_cli/         # PC 命令行工具（Dart）
    └── sinker_android/     # Android 接收端 App（Flutter）
```

**Monorepo**：使用 Dart Pub Workspaces（Dart 3.6+）管理，`sinker_core` 在 PC 和 Android 两端共用。

---

## 传输流程

```
PC (CLI)                                 Android (App)
────────                                 ─────────────
1. ZIP 压缩（写入临时文件）
2. 可选加密（XOR / AES-256-GCM）
3. adb forward tcp:18900 tcp:18900  ←→  App 监听 18900 端口
4. TCP 连接 + 协议握手
5. 分块流式发送 ────────────────────→   流式写入临时文件
6. SHA-256 完整性校验                    校验通过
                                         解密 → 解压 → 保存到 Downloads
```

---

## 编译与安装

### 前置要求

- [Dart SDK](https://dart.dev/get-dart) ≥ 3.6（或随 Flutter 安装）
- [Flutter SDK](https://flutter.dev) ≥ 3.x（用于编译 Android App）
- ADB 工具（随 Android SDK 安装）
- Android 手机，已开启 USB 调试

### 编译 PC 端 CLI

```bash
# 克隆仓库
git clone https://github.com/shaopx/sinker.git
cd sinker

# 安装依赖
dart pub get

# 编译为独立可执行文件
# macOS / Linux
dart compile exe apps/sinker_cli/bin/sinker.dart -o build/sinker

# Windows（需在 Windows 环境执行）
dart compile exe apps/sinker_cli/bin/sinker.dart -o build/sinker.exe
```

### 编译 Android APK

```bash
cd apps/sinker_android
flutter build apk --release

# 安装到手机
adb install build/outputs/flutter-apk/app-release.apk
```

---

## 使用方法

### 1. 启动 Android 接收端

- 打开 Sinker App
- 首次运行授予"管理所有文件"权限
- 点击 **Start Receiving**，状态显示 `Listening on port 18900...`

### 2. PC 端发送文件

```bash
# 发送单个文件
./sinker send /path/to/file.pdf

# 发送整个目录
./sinker send /path/to/photos/

# 指定目标路径
./sinker send ./docs/ --to /sdcard/Download/sinker/

# 使用 XOR 加密（快速）
./sinker send ./docs/ --encrypt xor

# 使用 AES-256-GCM 加密（安全，但慢）
./sinker send ./docs/ --encrypt aes -p mypassword

# 详细输出 / 模拟运行
./sinker send ./docs/ --verbose
./sinker send ./docs/ --dry-run
```

文件保存到 Android `/sdcard/Download/sinker/`，可在系统"文件"App 的 Download 目录找到。

### 3. 其他命令

```bash
# 列出已连接设备
./sinker devices

# 多设备时指定目标
./sinker send file.pdf --device DEVICE_SERIAL

# 配置管理
./sinker config --list
./sinker config --set default_port=18900
./sinker config --set target_dir=/sdcard/Download/sinker/
```

---

## 传输协议

### 包头格式（14 字节，大端序）

| 偏移 | 大小 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | magic | `0x534E4B52`（"SNKR"） |
| 4 | 1 | version | 协议版本（`0x01`） |
| 5 | 1 | message_type | 消息类型 |
| 6 | 4 | payload_length | 载荷长度 |
| 10 | 2 | sequence_number | 序列号 |
| 12 | 2 | checksum | CRC-16 校验（头部前 12 字节） |

### 消息流程

```
PC ──HELLO──────────────────→ Android
PC ←─HELLO_ACK────────────── Android
PC ──TRANSFER_START─────────→ Android
PC ←─TRANSFER_ACK─────────── Android
PC ──DATA_CHUNK × N─────────→ Android
PC ──TRANSFER_END────────────→ Android
PC ←─TRANSFER_COMPLETE─────── Android
PC ──BYE─────────────────────→ Android
```

---

## 加密说明

| 模式 | 速度 | 安全性 | 适用场景 |
|------|------|--------|---------|
| `none`（默认） | 最快 | 无 | 局域网/USB 可信环境 |
| `xor` | ~800MB/s | 混淆 | 规避内容检测 |
| `aes` | ~2MB/s | AES-256-GCM | 需要密码保护 |

---

## License

MIT

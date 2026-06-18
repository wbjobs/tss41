# 音频配对系统 (Audio Pairing System)

一个基于环境噪音指纹的跨设备配对系统，使用MFCC特征提取和DTW动态时间规整算法，实现iOS、Android设备之间的安全配对。

## 系统架构

```
┌─────────────┐     WebSocket     ┌─────────────┐
│   iOS App   │ ◀─────────────▶ │  Node.js    │
│  (Swift)    │                 │   Backend   │
└─────────────┘                 └─────────────┘
                                         │
                                         │ spawn Python
                                         ▼
                                  ┌─────────────┐
                                  │  MFCC+DTW   │
                                  │  Processor   │
                                  └─────────────┘
                                         │
┌─────────────┐     WebSocket     ┌─────────────┐
│ Android App │ ◀─────────────▶ │  Session    │
│  (Kotlin)  │                 │  Pool      │
└─────────────┘                 └─────────────┘
```

## 核心技术栈

### 后端 (Node.js + Python)
- **WebSocket服务器**: 使用 `ws` 库实现长连接
- **Session管理**: 配对Session池，30秒超时自动销毁
- **AES-256-GCM**: 端到端加密
- **信号处理**: Python + NumPy实现
  - MFCC特征提取（梅尔频率倒谱系数）
  - DTW动态时间规整距离计算

### iOS客户端 (Swift)
- **AVFoundation**: 音频录制
- **Accelerate**: 高性能信号处理
- **Starscream**: WebSocket客户端
- **CryptoKit**: AES加密
- **实时波形图**: 自定义波形视图

### Android客户端 (Kotlin)
- **AudioRecord/MediaRecorder**: 音频录制
- **Java-WebSocket**: WebSocket客户端
- **Gson**: JSON序列化
- **AES-GCM**: 端到端加密

## 工作流程

### 配对流程

```
1. 两台设备同时点击"开始配对"
   │
   ▼
2. 连接WebSocket，创建/加入配对Session
   │
   ▼
3. 服务器广播"开始录音"指令
   │
   ▼
4. 两端同时录制3秒环境噪音
   │  ├─ 实时显示音频波形
   │  └─ 16kHz单声道PCM浮点格式
   │
   ▼
5. 客户端上传原始音频数据（Base64编码）
   │
   ▼
6. 服务器调用Python脚本：
   ├─ 对两组音频提取MFCC特征
   ├─ 计算DTW距离
   └─ 判断是否匹配（距离 < 阈值）
   │
   ▼
7. 匹配成功：
   ├─ 生成一次性AES-256密钥
   ├─ 通过WebSocket下发给两端
   └─ 建立端到端加密通信通道
   │
   ▼
8. 客户端可发送加密消息
```

### 音频参数

| 参数 | 值 |
|------|----|
| 采样率 | 16000 Hz |
| 声道 | 单声道 |
| 格式 | PCM Float32 |
| 录音时长 | 3秒 |
| MFCC系数 | 13维 |
| 梅尔滤波器组 | 40个 |
| DTW阈值 | 1000.0 |

## 项目结构

```
tss41/
├── backend/                    # 后端服务
│   ├── server.js           # WebSocket主服务器
│   ├── sessionPool.js    # Session池管理
│   ├── cryptoUtils.js     # AES加密工具
│   ├── pythonBridge.js  # Python脚本桥接
│   ├── signal_processing/
│   │   └── mfcc_dtw.py  # MFCC+DTW算法
│   └── package.json      # 依赖配置
│
├── ios/                       # iOS客户端
│   ├── Package.swift     # Swift包配置
│   └── Sources/
│       ├── AudioRecorder.swift       # 录音管理
│       ├── MFCCExtractor.swift   # MFCC提取
│       ├── WaveformView.swift    # 波形显示
│       ├── WebSocketManager.swift # WebSocket管理
│       ├── CryptoUtils.swift     # 加密工具
│       └── PairingViewController.swift # 主界面
│
├── android/                   # Android客户端
│   ├── build.gradle.kts    # Gradle配置
│   └── app/src/main/
│       ├── AndroidManifest.xml
│       ├── java/com/audiopairing/client/
│       │   ├── AudioRecorder.kt       # 录音管理
│       │   ├── MFCCExtractor.kt   # MFCC提取
│       │   ├── WaveformView.kt    # 波形显示
│       │   ├── WebSocketManager.kt # WebSocket管理
│       │   ├── CryptoUtils.kt     # 加密工具
│       │   └── MainActivity.kt      # 主活动
│       └── res/                  # 资源文件
│
└── README.md
```

## 快速开始

### 1. 启动后端服务

```bash
cd backend

# 安装依赖
npm install

# 安装Python依赖
pip install numpy

# 启动服务
npm start

# 或指定Python路径
PYTHON_EXECUTABLE=python3 npm start
```

### 2. 配置环境变量

```bash
PORT=8080                    # 服务器端口
PYTHON_EXECUTABLE=python3      # Python可执行文件路径
DTW_THRESHOLD=1000.0         # DTW匹配阈值
SESSION_TIMEOUT=30000          # Session超时时间（毫秒）
```

### 3. iOS客户端

```bash
cd ios

# 安装依赖
swift package resolve

# 打开Xcode工程
open Package.swift
```

修改 `PairingViewController.swift` 中的服务器地址：
```swift
private let serverURL = URL(string: "ws://your-server-ip:8080")!
```

### 4. Android客户端

```bash
cd android

# 使用Android Studio打开项目
# 或使用命令行构建
./gradlew assembleDebug
```

修改 `MainActivity.kt` 中的服务器地址：
```kotlin
private val serverUrl = "ws://your-server-ip:8080"
```

## WebSocket消息协议

### 客户端 -> 服务器

| 消息类型 | 说明 | 载荷 |
|---------|------|------|
| `register` | 注册客户端 | `{ platform, deviceInfo }` |
| `start_pairing` | 开始配对 | `{}` |
| `audio_data` | 上传音频数据 | `{ audioData, sampleRate, sessionId }` |
| `cancel_pairing` | 取消配对 | `{ sessionId }` |
| `send_encrypted` | 发送加密消息 | `{ encryptedData }` |
| `heartbeat` | 心跳 | `{ timestamp }` |
| `stats` | 获取统计 | `{}` |

### 服务器 -> 客户端

| 消息类型 | 说明 | 载荷 |
|---------|------|------|
| `connected` | 连接成功 | `{ clientId }` |
| `session_created` | Session已创建 | `{ sessionId, status }` |
| `session_joined` | 已加入Session | `{ sessionId, status }` |
| `partner_joined` | 伙伴已加入 | `{ sessionId, partnerPlatform }` |
| `start_recording` | 开始录音 | `{ sessionId, duration }` |
| `audio_received` | 音频已接收 | `{ sessionId }` |
| `partner_audio_received` | 伙伴音频已接收 | `{ sessionId }` |
| `matching_started` | 开始匹配 | `{ sessionId }` |
| `pairing_success` | 配对成功 | `{ sessionId, aesKey, partnerId, partnerPlatform, matchScore }` |
| `pairing_failed` | 配对失败 | `{ sessionId, reason, matchScore }` |
| `pairing_cancelled` | 配对已取消 | `{ sessionId, reason }` |
| `session_timeout` | Session超时 | `{ sessionId }` |
| `encrypted_message` | 收到加密消息 | `{ fromClientId, sessionId, encryptedData }` |
| `message_delivered` | 消息已送达 | `{ sessionId }` |
| `partner_disconnected` | 伙伴断开连接 | `{ sessionId }` |

## 加密方案

### 密钥交换

```
┌─────────┐
│设备A  │
└───┬───┘
    │ 发送配对请求
    ▼
┌─────────────────┐
│  服务器      │
│  - 生成AES-256密钥
│  - 计算DTW匹配
└───┬──────────┘
    │ 密钥下发（WebSocket加密通道
    ▼
┌─────────┐  ┌─────────┐
│  设备A  │  │  设备B  │
└─────────┘  └─────────┘
      │              │
      └──────┬───────┘
             │
          端到端加密通信
          (AES-256-GCM)
```

### AES-256-GCM参数：
- 密钥长度: 32字节
- IV长度: 12字节
- Auth Tag: 16字节
- 密钥分发: 通过WebSocket下发（仅一次

## 部署建议

### 阈值调优

1. **DTW阈值**: 根据实际环境调整 `DTW_THRESHOLD`
   - 安静环境: 500-800
   - 嘈杂环境: 1000-1500

2. **录音时长**: 可调整 `recordingDuration`
   - 最短2秒，最长5秒

3. **Session超时**: 根据网络状况调整

### 安全增强

- [ ] 添加TLS支持WebSocket
- [ ] 实现客户端证书认证
- [ ] 添加设备指纹绑定
- [ ] 实现密钥轮换机制

## 许可证

MIT License

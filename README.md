# Clicky

Clicky 是一个仅驻留在 macOS 菜单栏的屏幕语音助手。按住 `Control + Option` 说话后，它会：

1. 通过腾讯云实时 ASR 转写语音；
2. 截取当前屏幕并将文字与截图发送给 MiniMax；
3. 在面板中流式显示回答，并通过 MiniMax 流式 TTS 播放；
4. 在需要定位可见目标时，让蓝色指针移动到模型返回的位置。

这个仓库是在 [farzaa/clicky](https://github.com/farzaa/clicky) 基础上的个人改造版，保留原项目的 MIT License。目前的模型、语音、代理服务、界面和指向链路已经与原项目不同。

## 当前能力

- macOS 菜单栏应用，无 Dock 图标和普通主窗口
- `Control + Option` 全局按住说话
- 腾讯云实时语音识别
- MiniMax-M3 多模态问答与屏幕理解
- MiniMax 流式 TTS，支持音色搜索、试听、音量、语速和音调设置
- 最近对话记录与复制按钮
- 简短、默认、详细三种回答长度
- 多显示器截图和归一化坐标指向
- 本地 Node 代理或 Cloudflare Worker 两种部署方式

Clicky 当前只负责问答、屏幕解释和视觉指引，不会替用户点击、输入或执行脚本。坐标由视觉模型直接判断，属于辅助指引，不保证像原生 UI 自动化一样精确。项目也没有内置互联网搜索。

## 系统要求

- macOS 14.2 或更高版本
- 较新的 Xcode（项目当前使用新版 Xcode 维护）
- Node.js 22 或更高版本
- MiniMax API Key
- 腾讯云 ASR 的 `AppID`、`SecretId` 和 `SecretKey`

## 快速启动

### 1. 配置本地代理

默认配置使用 `http://localhost:8787`，API Key 不写进 App。

```bash
cd worker
npm install
cp .dev.vars.example .dev.vars
```

编辑 `worker/.dev.vars`，至少填写：

```text
MINIMAX_API_KEY=你的_MiniMax_Key
TENCENT_ASR_APP_ID=你的腾讯云_AppID
TENCENT_ASR_SECRET_ID=你的腾讯云_SecretId
TENCENT_ASR_SECRET_KEY=你的腾讯云_SecretKey
```

`TENCENT_ASR_APP_ID` 是腾讯云账号/项目对应的数字 AppID，不是 SecretId。SecretId 和 SecretKey 在腾讯云访问管理中创建。

启动代理：

```bash
npm run local
```

浏览器直接访问 `http://localhost:8787/` 显示 `Method not allowed` 是正常的，因为代理只接受指定的 `POST` 路由。

### 2. 在 Xcode 运行 App

```bash
open leanring-buddy.xcodeproj
```

在 Xcode 中：

1. 选择 `leanring-buddy` scheme 和 `My Mac`；
2. 在 Signing & Capabilities 中选择自己的 Team；
3. 按 `Cmd + R` 构建并运行。

App 会出现在屏幕顶部菜单栏，不会出现在 Dock。首次运行需要授予：

- 麦克风：录制语音
- 辅助功能：监听全局 `Control + Option`
- 屏幕与系统录音：截取当前屏幕

权限通常与 App 的签名和安装位置绑定。开发时请始终从同一个 Xcode 工程运行，不要在终端使用 `xcodebuild`，否则可能生成不同实例并需要重新授权。

### 3. 开始使用

- 点击菜单栏中的 Clicky 图标打开面板；
- 按住 `Control + Option` 说话，松开后提交；
- 语音设置窗口可以搜索和试听 MiniMax 音色；
- 只在明确询问当前屏幕位置、按钮、图标、文件等目标时才请求指向。

## 配置项

本地代理从 `worker/.dev.vars` 读取配置；Cloudflare Worker 使用 secrets 和 vars。

| 变量 | 必需 | 默认值 | 用途 |
|---|---:|---|---|
| `MINIMAX_API_KEY` | 是 | - | MiniMax 聊天、音色和 TTS |
| `TENCENT_ASR_APP_ID` | 是 | - | 腾讯云实时 ASR AppID |
| `TENCENT_ASR_SECRET_ID` | 是 | - | 生成腾讯 ASR 临时签名 |
| `TENCENT_ASR_SECRET_KEY` | 是 | - | 生成腾讯 ASR 临时签名 |
| `MINIMAX_API_HOST` | 否 | `https://api.minimax.io` | MiniMax API 域名 |
| `MINIMAX_CHAT_MODEL` | 否 | `MiniMax-M3` | 多模态聊天模型 |
| `MINIMAX_THINKING_TYPE` | 否 | `disabled` | `disabled`、`adaptive` 或 `omit` |
| `MINIMAX_TTS_MODEL` | 否 | `speech-2.8-turbo` | 语音合成模型 |
| `MINIMAX_TTS_VOICE_ID` | 否 | `Chinese (Mandarin)_Warm_Bestie` | 初始音色；面板设置会覆盖它 |
| `MINIMAX_TTS_VOLUME` | 否 | `1.0` | 初始合成音量；面板设置会覆盖它 |
| `TENCENT_ASR_ENGINE_MODEL_TYPE` | 否 | `16k_zh_en` | 腾讯 ASR 引擎 |
| `TENCENT_ASR_ENABLE_HOTWORDS` | 否 | `0` | 是否把上下文关键词发送给腾讯 ASR |

App 读取 [Info.plist](leanring-buddy/Info.plist) 中的：

- `WorkerBaseURL`：代理基础地址，默认 `http://localhost:8787`
- `VoiceTranscriptionProvider`：当前为 `tencent`

## 使用 Cloudflare Worker

本地代理不是强制要求。需要开机后无需手动启动 Node 服务时，可以部署 Cloudflare Worker：

```bash
cd worker
npm install
npx wrangler secret put MINIMAX_API_KEY
npx wrangler secret put TENCENT_ASR_APP_ID
npx wrangler secret put TENCENT_ASR_SECRET_ID
npx wrangler secret put TENCENT_ASR_SECRET_KEY
npx wrangler deploy
```

部署完成后，将 `leanring-buddy/Info.plist` 的 `WorkerBaseURL` 改为 Worker 地址。模型名称等非敏感默认值在 [wrangler.toml](worker/wrangler.toml) 中配置。

代理提供以下路由：

| 路由 | 用途 |
|---|---|
| `POST /chat` | MiniMax-M3 多模态流式问答 |
| `POST /tts` | 完整 MP3 合成，主要用于音色试听 |
| `POST /tts-stream` | 将 MiniMax SSE 音频帧转换为流式 MP3 |
| `POST /voices` | 获取 MiniMax 系统和账号音色 |
| `POST /transcribe-url` | 生成腾讯云实时 ASR 短期 WebSocket 签名地址 |

## 数据与隐私

- API Key 只保存在本地 `worker/.dev.vars` 或 Cloudflare secrets 中，不写进 App 包。
- 用户语音会发送给腾讯云 ASR。
- 用户文字、最近对话上下文和屏幕截图会经代理发送给 MiniMax。
- 项目不再包含原作者的 PostHog 遥测，不会把转写或模型回答发送到分析平台。
- `.gitignore` 已排除本地凭据、Node 依赖、构建产物、日志和生成音频。

## 架构

```text
macOS Clicky.app
  ├─ AVAudioEngine ──> Tencent ASR WebSocket
  ├─ ScreenCaptureKit ──> JPEG screenshots
  ├─ /chat ──> MiniMax-M3 SSE text
  ├─ /tts-stream ──> MiniMax TTS SSE/MP3
  └─ NSStatusItem + NSPanel + transparent cursor overlay

Proxy (local Node or Cloudflare Worker)
  ├─ stores API credentials
  ├─ forwards MiniMax requests
  └─ signs short-lived Tencent ASR URLs
```

核心文件：

```text
leanring-buddy/
  leanring_buddyApp.swift        菜单栏 App 入口
  CompanionManager.swift         语音、截图、LLM、TTS 和指向状态机
  MenuBarPanelManager.swift      NSStatusItem 与浮动面板
  CompanionPanelView.swift       主控制面板和对话历史
  VoiceSettingsView.swift        音色浏览、试听和参数设置
  ClaudeAPI.swift                MiniMax 兼容的流式视觉客户端
  ElevenLabsTTSClient.swift      MiniMax TTS 客户端（历史文件名）
  StreamingMP3AudioPlayer.swift  增量 MP3 播放
  TencentASRStreamingTranscriptionProvider.swift
  OverlayWindow.swift            蓝色指针覆盖层
worker/
  local-server.mjs               本地代理
  src/index.ts                   Cloudflare Worker
```

完整的工程约定和文件职责见 [AGENTS.md](AGENTS.md)。

## 检查 Worker

```bash
cd worker
npm test
npm run typecheck
node --check local-server.mjs
```

Swift App 请通过 Xcode 界面构建。仓库不再保留默认生成的 Xcode Unit Test 和 UI Test target；需要测试新功能时，应按实际功能重新建立有价值的测试。

## 上游与许可证

原始项目：[farzaa/clicky](https://github.com/farzaa/clicky)。本仓库继续使用 [MIT License](LICENSE)。

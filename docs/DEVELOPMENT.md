# 安装、配置与开发

## 安装与启动

需要 macOS 14.2+、Xcode、Node.js 22+、MiniMax API Key，以及腾讯云 ASR 的 AppID、SecretId 和 SecretKey。

### 本地代理

在仓库根目录执行：

```bash
cd worker
npm install
cp .dev.vars.example .dev.vars
```

编辑 `worker/.dev.vars` 中的凭据，不要提交这个文件：

```dotenv
MINIMAX_API_KEY=你的_MiniMax_Key
TENCENT_ASR_APP_ID=你的腾讯云_AppID
TENCENT_ASR_SECRET_ID=你的腾讯云_SecretId
TENCENT_ASR_SECRET_KEY=你的腾讯云_SecretKey
```

推荐模型与本地精确定位配置：

```dotenv
MINIMAX_CHAT_MODEL=MiniMax-M3.1-Flash
MINIMAX_THINKING_TYPE=adaptive
MINIMAX_REASONING_EFFORT=low
MINIMAX_MAX_TOKENS=8192
MINIMAX_POINTING_MODE=computer
MINIMAX_POINTING_PRECISION=verified
```

`verified` 需要 macOS 的 Swift/AppKit SDK；首次运行会编译本地 Vision 辅助程序。模板默认保留 `custom/raw`，使用上述精确定位需显式修改这两个配置项。

在 `worker/` 中运行 `npm run local`，并保持服务运行。配置在启动时读取，修改后需重启代理。若已经自行配置 `com.clicky.local-proxy` 登录服务，可用：

```bash
launchctl kickstart -k gui/$(id -u)/com.clicky.local-proxy
```

浏览器访问 `http://localhost:8787/` 返回 `Method not allowed` 是正常的，该服务接收 App 的 POST 请求。

### macOS App

在仓库根目录执行 `open leanring-buddy.xcodeproj`，选择 `leanring-buddy` scheme 和 `My Mac`，在 Signing & Capabilities 中选择自己的 Team，然后按 **Cmd + R**。

本地代理地址由 `leanring-buddy/Info.plist` 的 `WorkerBaseURL` 设置。首次运行按提示授予麦克风、辅助功能、屏幕录制及屏幕内容访问权限。

保持签名身份与安装路径稳定。通过 Xcode 界面构建、测试；不要使用终端 `xcodebuild`，本项目曾因此遇到权限失效。测试后先进行一次普通构建，再安装 App，避免安装测试宿主。

## 模型配置

默认 MiniMax-M3.1-Flash、low 思考深度。M3.1 使用 `thinking.type=adaptive`，不支持关闭思考；effort 支持 `low/medium/high/xhigh/max`。思考与答案共用输出预算，代理保留至少 8192 tokens。MiniMax-M3 仍兼容 `disabled/adaptive/omit`。

旧配置 `MINIMAX_THINKING_TYPE=low` 会迁移，显式 `MINIMAX_REASONING_EFFORT` 优先；M3.1 遇到旧 `disabled` 会升级为 adaptive。模型设置由代理负责，不在 App 面板中切换。

## 定位与屏幕操作

| 配置 | 行为 |
| --- | --- |
| `MINIMAX_POINTING_MODE=custom` | 使用 `point_to_screen` 自定义函数，校验目标框并取中心。 |
| `MINIMAX_POINTING_MODE=computer` | 使用固定版本的 OSWorld M3 动作协议解析当前截图中的目标。 |
| `MINIMAX_POINTING_PRECISION=verified` | 本地 macOS 代理追加 Vision 文字核对与控件像素中心校准。 |
| `MINIMAX_POINTING_PRECISION=raw` | 不追加本地校准，用于基线比较或远端运行。 |

computer 通道兼容 M3.1 Flash。参考代码固定于 [OSWorld M3 Agent c0f31bb](https://github.com/xlang-ai/OSWorld/tree/c0f31bbeec1252599f46b2932fdb1fab7292c23e/mm_agents/m3)，原文与 Apache-2.0 许可证保存在 `worker/third-party/`。这是经过适配的定位集成，不是完整官方评测环境。

定位只输出位置，不直接派发系统输入。开启 Screen Control 后，本地控制器按用户明确的一步指令执行点击、双击、右键、滚动、打开已安装应用或关闭当前窗口。指向请求不会变成点击；当前版本没有自主多步循环、键盘输入或拖绘。

独立目标只使用当前截图；“点它”“再指一次”等追问先从最近最多十轮文字中解析目标，再重新定位，不复用旧坐标或历史截图。没有目标或目标不明确时会澄清。开关关闭、重新按住 Control + Option 或设置中的停止按钮均可取消尚未执行的动作。

verified 对明确的英文控件名称做 OCR 核对，排除否定对象，再结合截图像素确定附近控件中心。校准缺失或不可用时不静默回退到粗坐标。截图经 stdin 传给本地辅助程序，不保存到磁盘或日志。首次系统 Vision 初始化可能较慢。

Cloudflare Worker 保留 `custom/raw` 默认值，不支持这套本地 verified 校准。改回 `raw` 可比较基线，改回 `custom` 可使用自定义函数通道，均需重启代理。

## 检查与测试

在 `worker/` 执行离线回归：

```bash
npm test
npm run typecheck
node --check local-server.mjs
```

App 测试使用 Xcode **Cmd + U**。原生鼠标验收只存在于测试目标内，使用一次性窗口；具体 opt-in 与签名约定见 [AGENTS.md](../AGENTS.md)。产品不提供实验台或练习板。

以下测试会调用当前配置的 MiniMax API，并消耗用量。合成场景不读取桌面，在 `worker/` 执行：

```bash
swift -module-cache-path /private/tmp/matilda-swift-module-cache test/fixtures/make-grounding-fixture.swift /private/tmp/matilda-grounding-fixture.png
MATILDA_TEST_POINTING_MODE=computer node test/check-live-grounding.mjs /private/tmp/matilda-grounding-fixture.png
MATILDA_TEST_POINTING_MODE=custom node test/check-live-grounding.mjs /private/tmp/matilda-grounding-fixture.png
```

仅在确认允许将所选图片发送给 MiniMax 后，使用截图重放与连续对话检查：

```bash
MATILDA_TEST_PRECISION=verified MATILDA_TEST_JPEG=1 node test/check-live-user-grounding.mjs /path/to/replay-images 5
node test/check-pointing-variants.mjs /path/to/replay-images
node test/check-live-voice-pointing.mjs
node test/check-live-pointing-followups.mjs /path/to/approved-1920x1295-csv.png 2
```

限定样本的历史成绩和实际系统输入验收分别记录在 [更新记录](MAIN_CHANGES.md)。合成图、重放图片命中率与任意桌面准确率并不等同，输入派发也不等于业务任务完成。

## 可选：远端代理

希望将代理放在远端时，可部署 Cloudflare Worker。在 `worker/` 执行：

```bash
npx wrangler secret put MINIMAX_API_KEY
npx wrangler secret put TENCENT_ASR_APP_ID
npx wrangler secret put TENCENT_ASR_SECRET_ID
npx wrangler secret put TENCENT_ASR_SECRET_KEY
npx wrangler deploy
```

将 App 的 `WorkerBaseURL` 改为自己的 Worker 地址。该方式不提供本地 macOS 的精确校准能力。

## 数据与工程

语音发送到腾讯云 ASR；当前截图、问题和最近文字上下文经代理发送到 MiniMax；TTS 使用 MiniMax。凭据只存于本地 `.dev.vars` 或 Worker secrets，不打包进 App。对话仅保存在进程内存中；Release 不将转写、模型回答或屏幕文字记录到明文日志。

代理路由为 `/chat`、`/tts`、`/tts-stream`、`/voices`、`/transcribe-url`。架构与开发约定见 [AGENTS.md](../AGENTS.md)，形象素材与本地动画约定见 [素材说明](COMPANION_MOTION_ASSETS.md)。

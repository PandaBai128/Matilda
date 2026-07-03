Update: April 27, 2026.

Hi there! I'm Farza, the guy that made Clicky.

The existing codebase remains open source. Tinker with it, make it yours, start a company out of it, do whatever you want I don't mind. But, for all the new stuff I'm hacking on, gonna keep it private. To get the latest Clicky, you can go [here](https://www.heyclicky.com/).

I also tweeted about this [here](https://x.com/FarzaTV/status/2043402737828962489).

Go crazy with this repo!! It's an MIT license.

# Hi, this is Clicky.
It's an AI teacher that lives as a buddy next to your cursor. It can see your screen, talk to you, and even point at stuff. Kinda like having a real teacher next to you.

Download it [here](https://www.clicky.so/) for free.

Here's the [original tweet](https://x.com/FarzaTV/status/2041314633978659092) that kinda blew up for a demo for more context.

![Clicky — an ai buddy that lives on your mac](clicky-demo.gif)

This is the open-source version of Clicky for those that want to hack on it, build their own features, or just see how it works under the hood.

## Get started with Claude Code

The fastest way to get this running is with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Once you get Claude running, paste this:

```
Hi Claude.

Clone https://github.com/farzaa/clicky.git into my current directory.

Then read the CLAUDE.md. I want to get Clicky running locally on my Mac.

Help me set up everything — the Cloudflare Worker with my own API keys, the proxy URLs, and getting it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the local proxy)
- API keys for: [MiniMax](https://platform.minimax.io) and [Tencent Cloud ASR](https://cloud.tencent.com/product/asr)

### 1. Set up the local proxy

The local proxy holds your API keys. The app talks to `http://localhost:8787`, and the proxy talks to MiniMax/Tencent. This way your keys do not ship in the app binary.

```bash
cd worker
npm install
cp .dev.vars.example .dev.vars
```

Open `worker/.dev.vars` and fill in:

```text
MINIMAX_API_KEY=...
TENCENT_ASR_APP_ID=...
TENCENT_ASR_SECRET_ID=...
TENCENT_ASR_SECRET_KEY=...
MINIMAX_TTS_MODEL=speech-2.8-turbo
MINIMAX_TTS_VOICE_ID=Chinese (Mandarin)_Warm_Bestie
TENCENT_ASR_ENGINE_MODEL_TYPE=16k_zh_en
```

Start the proxy:

```bash
npm run local
```

The app defaults to `http://localhost:8787` via `WorkerBaseURL` in `leanring-buddy/Info.plist`.

### 2. Optional: deploy to Cloudflare later

If you want to run the proxy remotely later, create a Cloudflare account and add the secrets:

```bash
npx wrangler secret put MINIMAX_API_KEY
npx wrangler secret put TENCENT_ASR_APP_ID
npx wrangler secret put TENCENT_ASR_SECRET_ID
npx wrangler secret put TENCENT_ASR_SECRET_KEY
npx wrangler deploy
```

It'll give you a URL like `https://your-worker-name.your-subdomain.workers.dev`. Copy that.

### 3. Update the proxy URLs in the app

The app reads the proxy URL from `WorkerBaseURL` in `leanring-buddy/Info.plist`. It is already set to local development:

```xml
<key>WorkerBaseURL</key>
<string>http://localhost:8787</string>
```

### 4. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. But here's the short version:

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk streams audio over a websocket to Tencent Cloud ASR, sends the transcript + screenshot to MiniMax via streaming SSE, and plays the response through MiniMax TTS. The model can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors. All three APIs are proxied or signed through a Cloudflare Worker.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI
  ClaudeAPI.swift           # MiniMax-compatible streaming vision client
  ElevenLabsTTSClient.swift # Text-to-speech playback
  OverlayWindow.swift       # Blue cursor overlay
  TencentASR*.swift         # Tencent Cloud real-time transcription
  AssemblyAI*.swift         # Legacy real-time transcription fallback
  BuddyDictation*.swift     # Push-to-talk pipeline
worker/                  # Cloudflare Worker proxy
  src/index.ts              # Routes: /chat, /tts, /transcribe-url
CLAUDE.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).

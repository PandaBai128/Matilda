# 壮壮 (Matilda) - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app displayed as “壮壮”, with `Matilda` used as the English product and executable name. It lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar portrait opens a custom floating panel with companion voice controls. Push-to-talk (`ctrl + option`) captures voice input, Tencent Cloud ASR transcribes it, and the app sends the transcript plus current screenshots to MiniMax. MiniMax text is processed incrementally for TTS, while the complete answer is added to panel history after generation finishes. The Zhuangzhuang portrait follows the cursor, animates for listening and processing, and can fly beside a visible target while a blue pulse marks the model coordinate.

API keys live in the proxy layer: `worker/.dev.vars` for local development or Cloudflare Worker secrets for remote deployment. Nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: MiniMax-M3 via the local Node or Cloudflare Worker proxy with Anthropic-compatible SSE streaming
- **Speech-to-Text**: Tencent Cloud ASR real-time streaming via signed websocket URL, with Apple Speech as the local fallback
- **Text-to-Speech**: MiniMax T2A via the proxy. LLM text is segmented at sentence boundaries as it streams; MiniMax audio frames are parsed incrementally and played through a cancellable Audio Queue before each MP3 finishes downloading.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: The vision model embeds normalized `[POINT_V2:x,y:label:screenN]` tags using a fixed 0–1000 coordinate space. The overlay parses these, maps coordinates to the correct monitor, animates the Zhuangzhuang portrait along a bezier arc, and leaves the exact target visible under a blue pulse marker. Legacy `[POINT:...]` tags are stripped but never move the companion.
- **Concurrency**: UI state is isolated to `@MainActor`. Streaming MP3 parsing and Audio Queue lifecycle work run on dedicated serial queues so playback and cancellation cannot block the menu bar UI.

### API Proxy (Local Node or Cloudflare Worker)

MiniMax requests go through either `worker/local-server.mjs` or the Cloudflare Worker in `worker/src/index.ts`. The proxy also signs a short-lived Tencent ASR WebSocket URL; the app then streams microphone audio directly to that signed Tencent endpoint.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.minimax.io/anthropic/v1/messages` | MiniMax-M3 vision + streaming chat |
| `POST /tts` | `api.minimax.io/v1/t2a_v2` | MiniMax TTS audio |
| `POST /tts-stream` | `api.minimax.io/v1/t2a_v2` | MiniMax streaming TTS converted from SSE hex frames to chunked MP3 |
| `POST /voices` | `api.minimax.io/v1/get_voice` | List system and account-specific MiniMax voices |
| `POST /transcribe-url` | Signed `asr.cloud.tencent.com` websocket URL | Fetches a short-lived Tencent Cloud ASR websocket URL |

Required proxy credentials: `MINIMAX_API_KEY`, `TENCENT_ASR_APP_ID`, `TENCENT_ASR_SECRET_ID`, `TENCENT_ASR_SECRET_KEY`
Optional proxy configuration: `MINIMAX_API_HOST`, `MINIMAX_CHAT_MODEL`, `MINIMAX_THINKING_TYPE`, `MINIMAX_TTS_MODEL`, `MINIMAX_TTS_VOICE_ID`, `MINIMAX_TTS_VOLUME`, `TENCENT_ASR_ENGINE_MODEL_TYPE`, `TENCENT_ASR_ENABLE_HOTWORDS`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Companion Overlay**: A full-screen transparent `NSPanel` hosts the Zhuangzhuang portrait. It's non-activating, joins all Spaces, and never steals focus. SwiftUI continuously animates the approved portrait for idle breathing, occasional blinking, listening head tilt with an audio-reactive waveform, processing thought dots, and target navigation. The portrait has persisted small/medium/large sizing; a separate pulse marker preserves the exact target coordinate without covering it.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for Streaming ASR**: A single long-lived `URLSession` is shared across streaming ASR sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session can corrupt the OS connection pool and cause "Socket is not connected" errors after a few rapid reconnections.

**Transient Companion Mode**: When "Show 壮壮" is off, pressing the hotkey fades in the companion overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~68 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1050 | Central state machine. Owns dictation, shortcut monitoring, screen capture, vision API, streaming TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, persisted response-length and TTS settings, and cursor visibility. Coordinates the full push-to-talk → screenshot → MiniMax → TTS → optional pointing pipeline. |
| `PointingRequestPolicy.swift` | ~135 | Policies that request visual guidance for visible targets, including narrowly scoped close-page follow-ups, and high-resolution screenshots for on-screen text extraction while excluding non-visual topics. |
| `MenuBarPanelManager.swift` | ~235 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel, opens the standalone voice settings window, and installs click-outside-to-dismiss monitoring. |
| `CompanionPanelView.swift` | ~1050 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, brief/normal/detailed response control, recent conversation history with copy controls, model picker, selected voice summary, portrait visibility and size controls, permissions UI, and quit button. Dark aesthetic using `DS` design system. |
| `VoiceSettingsView.swift` | ~362 | Searchable and source-filtered MiniMax voice browser with cancellable per-voice preview, editable preview text, supported volume, speed, and pitch controls, and visible TTS errors. |
| `VoiceSettingsWindowManager.swift` | ~53 | Owns the standalone resizable NSPanel that hosts `VoiceSettingsView`. |
| `OverlayWindow.swift` | ~785 | Full-screen transparent overlay hosting the Zhuangzhuang portrait, listening waveform, thought dots, and target pulse. Handles continuous state animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionScreenCaptureUtility.swift` | ~125 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~903 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~72 | Protocol surface and provider factory for voice transcription backends. Resolves Tencent ASR or the Apple Speech fallback based on `VoiceTranscriptionProvider` in Info.plist. |
| `TencentASRStreamingTranscriptionProvider.swift` | ~370 | Streaming transcription provider. Fetches a signed Tencent Cloud ASR websocket URL from the Worker, opens the realtime ASR websocket, streams PCM16 audio, tracks sentence transcripts, and delivers finalized text on key-up. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~70 | Converts live microphone buffers to PCM16 mono audio for Tencent ASR streaming. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~179 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~295 | MiniMax-compatible vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `ElevenLabsTTSClient.swift` | ~448 | MiniMax TTS client. Streams response speech through the Worker, retains cancellation-safe complete-file voice previews, and coordinates ordered sentence playback. |
| `StreamingMP3AudioPlayer.swift` | ~375 | Incremental MP3 parser and Audio Queue player used by response TTS. Runs parsing, queue callbacks, and cancellation cleanup off the main actor while reusing one output queue across sentence streams. |
| `StreamingSpeechSegmenter.swift` | ~163 | Converts accumulated LLM text into complete speakable sentences, skips fenced code and point tags, and feeds ordered segments into the MiniMax TTS playback queue. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~32 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~415 | Cloudflare Worker proxy. Routes include MiniMax chat, complete and streaming TTS, voice catalog, and Tencent ASR signed websocket URLs. |
| `worker/src/minimax-sse-audio.ts` | ~86 | Incremental MiniMax SSE audio decoder and Cloudflare stream adapter with upstream cancellation propagation. |
| `worker/src/minimax-tts-capabilities.ts` | ~3 | MiniMax TTS model capability checks used to gate unsupported request settings. |
| `worker/local-server.mjs` | ~500 | Local Node proxy alternative with upstream cancellation, response backpressure handling, and the same API routes as the Worker. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

After running tests, build the app once more with the Xcode UI before installing it so the installed bundle is not the test host. Keep exactly one usable installation at `~/Applications/Matilda.app`: quit the previous process, replace that bundle, unregister and remove stale `Clicky.app` and `Matilda.app` bundles from DerivedData and temporary locations, then launch the installed copy. Verify Spotlight, Launch Services, and running processes resolve only to that installation before asking the user to grant permissions.

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put MINIMAX_API_KEY
npx wrangler secret put TENCENT_ASR_APP_ID
npx wrangler secret put TENCENT_ASR_SECRET_ID
npx wrangler secret put TENCENT_ASR_SECRET_KEY

# Deploy
npx wrangler deploy

# Local Node proxy (copy the safe template first)
cp .dev.vars.example .dev.vars
npm run local
```

The `leanring-buddyTests` target contains regression coverage for coordinates, permission routing, pointing policy, streaming speech segmentation, and TTS cancellation. Run it through the Xcode UI. The repository intentionally has no UI-test target. Worker transport tests remain under `worker/test` and run with `npm test`.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.

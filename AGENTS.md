# 壮壮 (Matilda) - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app displayed as “壮壮”, with `Matilda` used as the English product and executable name. It lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar portrait opens a custom floating panel with companion voice controls. Push-to-talk (`ctrl + option`) captures voice input, Tencent Cloud ASR transcribes it, and the app sends the transcript plus current screenshots to MiniMax. MiniMax text is processed incrementally for TTS, while the complete answer is added to panel history after generation finishes. The Zhuangzhuang portrait follows the cursor, animates for listening and processing, and can fly beside a visible target while a configurable pulse marks the model coordinate.

API keys live in the proxy layer: `worker/.dev.vars` for local development or Cloudflare Worker secrets for remote deployment. Nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: MiniMax-M3.1-Flash (low reasoning effort by default) via the local Node or Cloudflare Worker proxy with Anthropic-compatible SSE streaming; MiniMax-M3 remains compatible. M3.1 always thinks; the proxy sets `thinking.type=adaptive`, `output_config.effort`, and a configurable output budget of at least 8192 tokens so thinking cannot silently consume the app's old 1024-token allowance.
- **Speech-to-Text**: Tencent Cloud ASR real-time streaming via signed websocket URL, with Apple Speech as the local fallback
- **Text-to-Speech**: MiniMax T2A via the proxy. LLM text is segmented at sentence boundaries as it streams; MiniMax audio frames are parsed incrementally and played through a cancellable Audio Queue before each MP3 finishes downloading.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Companion Persona**: 壮壮 speaks as a quiet, observant, clever adult companion whose warmth is selective and especially close to the user. Subtle innocent mischief may appear occasionally, but answers stay primary; the persona never invents memories, uses baby talk, barks, performs cartoon-dog gestures, or pressures the user emotionally.
- **Codex Usage**: A read-only local monitor uses the existing Codex OAuth sign-in to fetch the account usage snapshot. Adaptive refresh is the default: 2 minutes for recent interaction, then 5, 15, or 30 minutes as the app becomes idle; fixed 2/5/15/30-minute choices are persisted in settings. It caches only the last successful quota snapshot, never credentials, and keeps the last value visible when a refresh fails.
- **Element Pointing**: For explicitly authorized pointing requests, the proxy supplies the read-only MiniMax function `point_to_screen`. It accepts a visible target's tight bounding box in normalized 0–1000 coordinates plus its 1-based screenshot number. The proxy validates the tool input and emits `[POINT_V2:x,y:label:screenN]` at the box center for the existing overlay. Invalid, missing, duplicate or ambiguous calls emit none; model-written tags cannot bypass validation. The app maps the validated point to the correct monitor, animates the portrait along a bezier arc, and marks the exact target. This is a custom function-call integration, not the Claude-specific `computer_*` protocol, and grants no clicking, typing, dragging or drawing capability.
- **Concurrency**: UI state is isolated to `@MainActor`. Streaming MP3 parsing and Audio Queue lifecycle work run on dedicated serial queues so playback and cancellation cannot block the menu bar UI. One event-driven cursor tracker is shared by all display overlays; its 60fps smoothing timer exists only while the mouse is moving and stops about 200ms after movement settles.

### API Proxy (Local Node or Cloudflare Worker)

MiniMax requests go through either `worker/local-server.mjs` or the Cloudflare Worker in `worker/src/index.ts`. The proxy also signs a short-lived Tencent ASR WebSocket URL; the app then streams microphone audio directly to that signed Tencent endpoint.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.minimax.io/anthropic/v1/messages` | MiniMax-M3.1-Flash vision, read-only pointing tool + streaming chat |
| `POST /tts` | `api.minimax.io/v1/t2a_v2` | MiniMax TTS audio |
| `POST /tts-stream` | `api.minimax.io/v1/t2a_v2` | MiniMax streaming TTS converted from SSE hex frames to chunked MP3 |
| `POST /voices` | `api.minimax.io/v1/get_voice` | List system and account-specific MiniMax voices |
| `POST /transcribe-url` | Signed `asr.cloud.tencent.com` websocket URL | Fetches a short-lived Tencent Cloud ASR websocket URL |

Required proxy credentials: `MINIMAX_API_KEY`, `TENCENT_ASR_APP_ID`, `TENCENT_ASR_SECRET_ID`, `TENCENT_ASR_SECRET_KEY`
Optional proxy configuration: `MINIMAX_API_HOST`, `MINIMAX_CHAT_MODEL`, `MINIMAX_THINKING_TYPE`, `MINIMAX_REASONING_EFFORT`, `MINIMAX_MAX_TOKENS`, `MINIMAX_TTS_MODEL`, `MINIMAX_TTS_VOICE_ID`, `MINIMAX_TTS_VOLUME`, `TENCENT_ASR_ENGINE_MODEL_TYPE`, `TENCENT_ASR_ENABLE_HOTWORDS`

**MiniMax Request Contract**: Local Node and Cloudflare share `worker/minimax-chat.mjs`. M3.1 effort accepts low/medium/high/xhigh/max; local defaults use low rather than the upstream max. Legacy `MINIMAX_THINKING_TYPE=low` is migrated, and stale disabled configuration is upgraded to adaptive for M3.1. M3 keeps disabled/adaptive/omit. SSE thinking and tool JSON stay out of speech; empty, truncated or disconnected replies fail rather than silently completing. A valid tool-only response supplies spoken text. Preserve cancellation and response backpressure when editing this bridge. Local configuration is read on proxy startup, so file edits require a proxy restart; no Mac App rebuild is needed for proxy-only changes.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses a variable-width `NSStatusItem` for the portrait and optional Codex allowance, plus a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks. The dropdown keeps Companion, Response, and Recent as distinct aligned sections; manual Talk is a compact shortcut-row action rather than a primary full-width button. Codex configuration lives in its own settings window opened from the footer, not in a dropdown card.

**Codex Usage Visibility**: Codex usage is intentionally secondary to the companion. The menu bar shows only limits returned by Codex: currently the weekly window. Five-hour parsing and persistence are retained so the setting and second menu value appear automatically if that duration returns in the API; there must be no disabled toggle, empty column, or placeholder while it is absent. At zero remaining, an optional compact countdown replaces `0%`. Authentication is read from Codex's local `auth.json` without logging, copying, refreshing, or modifying the token. Refresh failures preserve the last successful non-expired snapshot; an event-driven expiration task removes each quota window when its reset time passes even if the network remains unavailable.

**Codex Usage Refresh**: Launch and wake perform an immediate refresh. Opening the companion panel or Codex Usage settings records interaction and moves Adaptive mode to its 2-minute tier; it then backs off to 5 minutes after 5 minutes, 15 minutes after 1 hour, and 30 minutes after 4 hours or when there has been no interaction. Low Power Mode and serious/critical thermal pressure use 30 minutes in Adaptive mode. The sleeping schedule and in-flight fetch use separate tasks: changing the persisted frequency or recording interaction only cancels and replaces the sleep, never the network request. Concurrent refresh triggers coalesce onto the same fetch, so a wake refresh cannot be lost behind an existing request. Fixed choices remain fixed even under system constraints.

**Companion Overlay**: A full-screen transparent `NSPanel` exists for each display, but all panels share one `CompanionCursorTracker`. Global and local mouse events select the active display; only that display mounts the portrait animation subtree. Fast follows events directly, while Medium and Slow use one short-lived 60fps interpolation timer that stops about 200ms after movement settles. Idle and responding have no permanent timeline: a sleeping task wakes only for a brief natural blink. Listening runs at 24fps, processing and the target marker at 12fps, and pointing at 24fps; flight uses a short-lived 60fps timer. Event-driven auto-hide consumes the values emitted by the combined voice, pointing, enabled, and delay publishers, cancels and reschedules one delayed task, then removes the portrait subtree instead of leaving transparent animation running. Natural blinking and barking use transparent expression frames derived from the approved portrait. Persisted settings control size, distance, follow response, glow, auto-hide, and target marker appearance. The marker and center dot preserve the exact model coordinate even at screen edges; only the portrait and label are edge constrained.

**Response Lifecycle**: Each response has a generation identifier and one completion path shared by success, failure, cancellation, timeout, sleep/wake interruption, and TTS failure. Old generations cannot end a newer interaction. A bounded whole-response watchdog and bounded streaming-playback drain prevent a lost network or Audio Queue completion callback from leaving `voiceState` active forever and permanently blocking auto-hide.

**Companion Persona Boundary**: The digital companion provides emotional continuity with the real 壮壮 without claiming literal identity or private memories. It expresses closeness through steady presence, attention, and current-session conversation context. Personality is deliberately restrained so screen guidance and accurate answers remain clear; no catchphrases or mandatory jokes are used.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for Streaming ASR**: A single long-lived `URLSession` is shared across streaming ASR sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session can corrupt the OS connection pool and cause "Socket is not connected" errors after a few rapid reconnections.

**Transient Companion Mode**: When "Show 壮壮" is off, pressing the hotkey fades in the companion overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~75 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates the companion and Codex usage monitors. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1400 | Central state machine. Owns dictation, shortcut monitoring, screen capture, vision API, streaming TTS, generation-aware response cleanup, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, persisted response-length, TTS, and companion appearance settings. Coordinates the full push-to-talk → screenshot → MiniMax → TTS → optional pointing pipeline. |
| `MatildaCompanionPersona.swift` | ~50 | Pure system-prompt module defining 壮壮's restrained personality, relationship boundary, spoken-response rules, and pointing behavior. |
| `PointingRequestPolicy.swift` | ~135 | Policies that request visual guidance for visible targets, including narrowly scoped close-page follow-ups, and high-resolution screenshots for on-screen text extraction while excluding non-visual topics. |
| `MenuBarPanelManager.swift` | ~400 | Variable-width NSStatusItem + custom NSPanel lifecycle. Hosts the portrait and optional Codex usage values, manages the floating companion panel, opens standalone settings windows, and installs click-outside-to-dismiss monitoring. |
| `CompanionPanelView.swift` | ~1160 | SwiftUI dropdown organized into aligned Companion, Response, and Recent sections. Keeps manual Talk compact beside the global shortcut, retains permissions/history controls, and links to standalone appearance, voice, and Codex usage settings. |
| `CodexUsageClient.swift` | ~120 | Read-only client for the Codex usage endpoint. Loads the existing local OAuth sign-in, sends the account-aware request, and never persists or changes credentials. |
| `CodexUsageSnapshot.swift` | ~90 | Decodes Codex quota windows by duration, including the current weekly limit and dormant five-hour compatibility. |
| `CodexUsageMonitor.swift` | ~340 | Main-actor adaptive/fixed refresh lifecycle with separate scheduler and coalesced fetch tasks, wake and interaction rescheduling, event-driven quota expiration, safe last-successful snapshot cache, stale detection, and user-facing failure state. |
| `CodexUsageFormatting.swift` | ~65 | Compact menu-bar percentages, reset countdowns, and refresh-age text. |
| `CodexUsageRefreshPolicy.swift` | ~90 | Pure scheduling module for Adaptive backoff and fixed 2/5/15/30-minute refresh choices. |
| `CodexUsageGlyph.swift` | ~25 | Reusable code-native blue usage-bar glyph shared by the Codex settings header and dropdown footer. |
| `CodexUsageSettings.swift` | ~80 | Persisted menu bar visibility, per-window visibility, exhausted-limit countdown, and refresh-frequency preferences. |
| `CodexUsageSettingsView.swift` | ~325 | Standalone Codex usage overview, refresh-frequency picker, and display settings UI; hides five-hour controls unless Codex returns that window. |
| `CodexUsageSettingsWindowManager.swift` | ~50 | Owns the standalone resizable NSPanel that hosts `CodexUsageSettingsView`. |
| `AppearanceSettingsView.swift` | ~390 | Standalone live appearance preview with persisted size, cursor distance, follow response, idle auto-hide, target marker, label color, glow color, and glow intensity controls. |
| `AppearanceSettingsWindowManager.swift` | ~53 | Owns the standalone resizable NSPanel that hosts `AppearanceSettingsView`. |
| `VoiceSettingsView.swift` | ~362 | Searchable and source-filtered MiniMax voice browser with cancellable per-voice preview, editable preview text, supported volume, speed, and pitch controls, and visible TTS errors. |
| `VoiceSettingsWindowManager.swift` | ~53 | Owns the standalone resizable NSPanel that hosts `VoiceSettingsView`. |
| `CompanionOverlayRuntime.swift` | ~430 | Shared event-driven mouse tracker, short-lived follow interpolation, cancellable auto-hide controller with inspectable blocker state, active-display selection, animation cadence policy, and exact marker geometry. |
| `OverlayWindow.swift` | ~965 | Full-screen transparent overlay hosting the Zhuangzhuang portrait, low-power blink, active voice animations, bark animation, and configurable target pulse. Handles element pointing with short-lived bezier flight timers and per-display coordinate conversion. |
| `SystemSpeechFallbackController.swift` | ~70 | Retains macOS system speech through failure playback and provides neutral network/general response failure messages before returning voice state to idle. |
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
| `worker/minimax-chat.mjs` | ~200 | Shared model/effort configuration, read-only pointing tool schema, bounding-box validation, and SSE-to-App bridge. |
| `worker/minimax-chat.d.mts` | ~20 | Type declarations for the shared chat bridge used by the Cloudflare Worker. |
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

The `leanring-buddyTests` target contains regression coverage for coordinates, permission routing, pointing policy, the companion persona boundary, menu-bar usage width, streaming speech segmentation, TTS cancellation, Codex quota-window decoding, Adaptive/fixed refresh scheduling and persistence, in-flight refresh rescheduling, runtime quota expiration, refresh failure behavior, and exhausted-limit formatting. Run it through the Xcode UI. The repository intentionally has no UI-test target. Worker transport tests remain under `worker/test` and run with `npm test`.

`worker/test/minimax-chat.test.mjs` and the local proxy tests cover M3.1 parameter migration, stream completion, cancellation, and structured screen-pointing validation. `worker/test/check-live-grounding.mjs` is an explicit live test (not part of `npm test`) using a synthetic UI generated by `worker/test/fixtures/make-grounding-fixture.swift`; it checks points against known control bounds, secondary screens, and absent targets without capturing the user's desktop. See README for invocation. Synthetic hits are evidence for this fixture, not a guarantee of arbitrary desktop accuracy.

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
- Do not add a five-hour Codex placeholder or disabled setting while Codex omits that quota window; reveal it only when the response contains the real five-hour duration
- Do not move Codex usage into a card in the main dropdown; keep it subordinate in the menu bar and its standalone settings window

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

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
- **Experimental Screen Control**: A separate local single-step controller, disabled by default, executes explicit user click/double-click/right-click/scroll/open-installed-app/close-current-window commands without redundant authorization. The pointing tool remains read-only; screenshot content/model text never independently authorizes an OS event. Settings live in a standalone Screen Control window (dropdown entry or app-active Command+,). There is no autonomous action loop, typing, dragging or drawing.
- **Concurrency**: UI state is isolated to `@MainActor`. Streaming MP3 parsing and Audio Queue lifecycle work run on dedicated serial queues so playback and cancellation cannot block the menu bar UI. One event-driven cursor tracker is shared by all display overlays; its 60fps smoothing timer runs only during movement and a bounded settling tail of at most one second. A 200ms movement-idle threshold is not a forced position snap.

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
Optional proxy configuration: `MINIMAX_API_HOST`, `MINIMAX_CHAT_MODEL`, `MINIMAX_THINKING_TYPE`, `MINIMAX_REASONING_EFFORT`, `MINIMAX_MAX_TOKENS`, `MINIMAX_POINTING_MODE`, `MINIMAX_POINTING_PRECISION`, `MINIMAX_TTS_MODEL`, `MINIMAX_TTS_VOICE_ID`, `MINIMAX_TTS_VOLUME`, `TENCENT_ASR_ENGINE_MODEL_TYPE`, `TENCENT_ASR_ENABLE_HOTWORDS`

**MiniMax Request Contract**: Local Node and Cloudflare share `worker/minimax-chat.mjs`. M3.1 effort accepts low/medium/high/xhigh/max; local defaults use low rather than the upstream max. Legacy `MINIMAX_THINKING_TYPE=low` is migrated, and stale disabled configuration is upgraded to adaptive for M3.1. M3 keeps disabled/adaptive/omit. SSE thinking and tool JSON stay out of speech; empty, truncated or disconnected replies fail rather than silently completing. A valid tool-only response supplies spoken text. Preserve cancellation and response backpressure when editing this bridge. Local configuration is read on proxy startup, so file edits require a proxy restart; no Mac App rebuild is needed for proxy-only changes.

**Computer Protocol Trial**: `MINIMAX_POINTING_MODE=computer` selects the pinned public OSWorld M3 prompt/action protocol as a read-only API grounding baseline; `custom` (template/remote default) retains `point_to_screen`. The local user trial enabled computer mode on 2026-10-20, still using M3.1 Flash low. Only explicit pointing requests use the reference system prompt and one selected current screenshot; normal chat remains unchanged. `mouse_move` and predicted `left_click` coordinates only become overlay tags, never OS actions. Reject all other/multiple/malformed actions without falling back to custom grounding. Do not leak raw Action/XML into TTS or claim this is the full M3.1 official benchmark harness. See docs/DEVELOPMENT.md for scope, fixed source revision, test commands, and rollback.

**Conversational Pointing**: Natural imperatives such as “你指给我”, “指一指” and “再指一次” authorize the same read-only marker, not OS actions. Explicit speech-only requests remain still. Self-contained named targets use only the current screenshot; dependent follow-ups retain the available session history (up to ten exchanges). The computer proxy resolves the intended target in a separate text-only model request, then grounds that self-contained description in the current image and validates it locally. Never reuse old coordinates, treat landmarks as targets, or silently discard the referent. An unresolved referent asks which object; visual absence is judged only from the fresh screenshot. History stays in process memory and is not logged or persisted; app restart clears it. Do not restore the former one-exchange limit or strip follow-up history for precision isolation: isolate geometry, not target identity.

**Context Cost Decision**: The user explicitly chose to keep ten conversational exchanges after confirming that historical screenshots are not resent. Do not add a new length budget, automatic summarization or aggressive history reduction for this change. Screen operations may acquire a fresh image after each action to verify results, but must not accumulate all previous step images into each request.

**Local Precision Validation**: The local macOS proxy now enables `MINIMAX_POINTING_PRECISION=verified`. It preserves the App's low pointing temperature, verifies explicitly named English control text with local Vision OCR (excluding negated alternatives and incidental window names), then centers on a nearby compact fill region from the actual screenshot pixels. There are no test-label-to-coordinate tables in production. OCR receives image bytes only through stdin; neither screenshots nor recognized text are logged or persisted. Sharp is a declared runtime dependency; the small Vision helper requires local Swift/AppKit SDK tooling and is compiled in a private temporary cache. Missing OCR anchors, invalid actions or unavailable validation must not silently fall back to coarse coordinates. `raw` preserves the reference baseline. This enhancement is local Node/macOS only; the Worker keeps custom/raw defaults and rejects verified mode without a provider. Do not call the enhanced pipeline an unmodified official harness.

**Earlier Click Test Boundary**: `PointingReplayHost.swift` is a separate disposable native fixture that accepts mouse events only inside its own window and records hit/miss against known target regions. It never posts CGEvents, clicks business applications or expands accessibility permissions. Test input coordinates come from real model replies; expected regions are used solely by the judge, never supplied to the model or production refinement. At that earlier stage, OS-wide clicks were unverified because CUA returned noWindowsAvailable, and the shipped companion only pointed. Those historical results must not be relabeled as native CGEvent acceptance.

**User-Authorized Single-Step Contract**: With Screen Control enabled, a clear current user command is sufficient authorization. Do not restore application blacklists, risk-keyword filters, generic-confirmation-button bans, strict AX name/role/owner requirements, foreground-window boundary restrictions, pointer-distance gates or an artificial flight wait. Codex, desktop, Dock, menu bar and visually identified custom controls are not excluded categories. AX is optional observation, not a click prerequisite. Normal polite commands such as “能不能帮我点一下” execute directly; guidance and negated commands do not. Keep the persisted master switch, cancellation, validated on-screen coordinates and fresh-image target identity. If the scene/target changes or cannot be located, clarify the actual target, not ask for blanket permission. A short-lived answer “是的” to that genuine clarification reruns grounding against the current image; it never reuses old coordinates. Closing the current window uses its system AX close button immediately; any resulting save/password/biometric dialog remains a separate user step. Installed-app lookup is not a whitelist. Report input/state honestly. These rules supersede the first version's deliberately over-restrictive behavior documented historically in MAIN_CHANGES section 15.

**Developer Testing Boundary**: The manual pointing-lab HTML page and shipped native practice/self-test UI were removed at the user's request. Screen Control contains only the real operation switch, status and stop action. Do not restore a public practice board or ship test-only capture/model helpers. Keep useful automated regressions under test targets and `worker/test`; known target bounds judge predictions, never adjust production coordinates. Earlier native-practice results remain historical evidence, not acceptance for later changes. Preserve the user's pre-test switch preference after controlled tests.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses a variable-width `NSStatusItem` for the portrait and optional Codex allowance, plus a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks. The dropdown keeps Companion, Response, and Recent as distinct aligned sections; manual Talk is a compact shortcut-row action rather than a primary full-width button. Codex configuration lives in its own settings window opened from the footer, not in a dropdown card.

**Codex Usage Visibility**: Codex usage is intentionally secondary to the companion. The menu bar shows only limits returned by Codex: currently the weekly window. Five-hour parsing and persistence are retained so the setting and second menu value appear automatically if that duration returns in the API; there must be no disabled toggle, empty column, or placeholder while it is absent. At zero remaining, an optional compact countdown replaces `0%`. Authentication is read from Codex's local `auth.json` without logging, copying, refreshing, or modifying the token. Refresh failures preserve the last successful non-expired snapshot; an event-driven expiration task removes each quota window when its reset time passes even if the network remains unavailable.

**Codex Usage Refresh**: Launch and wake perform an immediate refresh. Opening the companion panel or Codex Usage settings records interaction and moves Adaptive mode to its 2-minute tier; it then backs off to 5 minutes after 5 minutes, 15 minutes after 1 hour, and 30 minutes after 4 hours or when there has been no interaction. Low Power Mode and serious/critical thermal pressure use 30 minutes in Adaptive mode. The sleeping schedule and in-flight fetch use separate tasks: changing the persisted frequency or recording interaction only cancels and replaces the sleep, never the network request. Concurrent refresh triggers coalesce onto the same fetch, so a wake refresh cannot be lost behind an existing request. Fixed choices remain fixed even under system constraints.

**Companion Overlay**: A full-screen transparent `NSPanel` exists for each display, but all panels share one `CompanionCursorTracker`. Fast follows events directly; Medium and Slow retain their response while moving and settle continuously instead of snapping after 200ms. A bounded tail stops the shared 60fps timer within one second. Immediate raw-cursor gaze and decaying movement energy drive local attention poses. Listening/processing hold the companion beside the user on its attention screen; releasing attention resynchronizes the current screen, including cross-screen moves. Idle/responding have no permanent timeline; a sleeping task wakes for a blink or quiet resting pose. Listening uses 24fps, processing and the target marker use 12fps. Flight uses the target NSScreen CADisplayLink at a 60fps target; position, tilt, scale and portrait share that clock. The arc/duration and exact target marker remain unchanged, with only a restrained 6% scale lift. Cancellation, disappearance and interrupted return flights stop the link. Decorative overlays remain invisible to mouse and AX hit-testing.

**Photo-Based Appearance and Feedback**: Portrait remains the default; Appearance offers a persisted `petiteBody` option based on the user's photos of a small, slender adult toy poodle. The app icon, menu-bar and panel portraits now reuse the neutral head-atlas pose at the user's request; preserve the menu-bar dimensions/layout. `CompanionLivingAvatarView` crops shared pose atlases without interpolating atlas offsets; gaze, gentle settling, listening, local step poses and quiet resting add no model calls. A first blink is due after 2.4 seconds and later blinks are 8.5 seconds apart; cursor movement must not restart that deadline. Reduce Motion disables decorative turning, step/blink motion and arc travel. Appearance has three grouped tabs and direct previews for all six head poses; selecting a pose only overrides the preview, not the companion's persisted style. The user chose a configurable visual arrival bubble: default “汪，汪汪”, actual target name, custom text up to 32 characters, or hidden. This is visual-only, never TTS, a model prompt, or business-success evidence; do not reinstate a fixed “目标” preview or remove the user's bark option based on earlier notes. `CompanionOperationFeedbackSession` rejects stale/duplicate feedback: a nod and one brief pulse follow actual input dispatch, never a prediction. Uncertainty/cancellation stops target flight/marking, and newly mounted views may replay only fresh feedback. Keep production test/practice UI removed. Asset prompts and implementation/verification status are in `docs/COMPANION_MOTION_ASSETS.md`.

**Response Lifecycle**: Each response has a generation identifier and one completion path shared by success, failure, cancellation, timeout, sleep/wake interruption, and TTS failure. Old generations cannot end a newer interaction. A bounded whole-response watchdog and bounded streaming-playback drain prevent a lost network or Audio Queue completion callback from leaving `voiceState` active forever and permanently blocking auto-hide.

**Companion Persona Boundary**: The digital companion provides emotional continuity with the real 壮壮 without claiming literal identity or private memories. It expresses closeness through steady presence, attention, and current-session conversation context. Personality is deliberately restrained so screen guidance and accurate answers remain clear; no catchphrases or mandatory jokes are used.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for Streaming ASR**: A single long-lived `URLSession` is shared across streaming ASR sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session can corrupt the OS connection pool and cause "Socket is not connected" errors after a few rapid reconnections.

**Transient Companion Mode**: When "Show 壮壮" is off, pressing the hotkey fades in the companion overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~75 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates the companion and Codex usage monitors. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1610 | Central voice/pointing lifecycle, single-step routing, truthful operation feedback, persisted appearance and session history. |
| `CompanionAppearanceMotion.swift` | ~115 | Persisted portrait/body and arrival-bubble choices, blink deadlines, bubble bounds and pure pose rules. |
| `CompanionLivingAvatarView.swift` | ~195 | Photo-based atlas rendering, local gaze/step/blink/rest poses, bounded feedback gestures and Reduce Motion. |
| `CompanionOperationFeedback.swift` | ~55 | Generation-gated performed/uncertain/cancelled presentation events; no action dispatch. |
| `leanring-buddyTests/CompanionAppearanceMotionTests.swift` | ~45 | Gaze, pose precedence, attention hold and appearance persistence regressions. |
| `leanring-buddyTests/CompanionAttentionTests.swift` | ~95 | Cursor-energy bounds, original response, continuous settling and timer-rest regressions. |
| `leanring-buddyTests/CompanionOperationFeedbackTests.swift` | ~65 | Truthful event, stale-generation, duplicate and cancellation regressions. |
| `leanring-buddyTests/CompanionMotionRenderTests.swift` | ~70 | Test-only atlas and actual-size light/dark avatar rendering for visual review, with no product UI or screen capture. |
| `MatildaCompanionPersona.swift` | ~50 | Pure system-prompt module defining 壮壮's restrained personality, relationship boundary, spoken-response rules, and pointing behavior. |
| `PointingRequestPolicy.swift` | ~180 | Natural pointing and dependent follow-up policies, speech-only exclusions, and high-resolution screen text extraction routing. |
| `ScreenOperationPolicy.swift` | ~80 | Explicit/polite action parsing, current-window closing, guidance exclusion, clarification answers and persisted opt-in key. |
| `ScreenOperationController.swift` | ~220 | Direct CGEvent dispatch, installed-app lookup, immediate AX window closing, optional state observation and local pixel comparison. |
| `ScreenOperationSettings.swift` | ~50 | Standalone Screen Control switch, operation status and immediate cancellation; no practice UI. |
| `leanring-buddyTests/ScreenOperationTests.swift` | ~200 | Policy/setting/coordinate regressions plus an opt-in real CGEvent and direct AX close acceptance test, isolated to its own disposable receiver. |
| `MenuBarPanelManager.swift` | ~400 | Variable-width NSStatusItem + custom NSPanel lifecycle. Hosts the portrait and optional Codex usage values, manages the floating companion panel, opens standalone settings windows, and installs click-outside-to-dismiss monitoring. |
| `CompanionPanelView.swift` | ~1115 | SwiftUI dropdown organized into aligned Companion, Response, and Recent sections. Response contains Length and Voice only; model selection is owned by the proxy configuration. Keeps manual Talk compact and links to standalone settings. |
| `CodexUsageClient.swift` | ~120 | Read-only client for the Codex usage endpoint. Loads the existing local OAuth sign-in, sends the account-aware request, and never persists or changes credentials. |
| `CodexUsageSnapshot.swift` | ~90 | Decodes Codex quota windows by duration, including the current weekly limit and dormant five-hour compatibility. |
| `CodexUsageMonitor.swift` | ~340 | Main-actor adaptive/fixed refresh lifecycle with separate scheduler and coalesced fetch tasks, wake and interaction rescheduling, event-driven quota expiration, safe last-successful snapshot cache, stale detection, and user-facing failure state. |
| `CodexUsageFormatting.swift` | ~65 | Compact menu-bar percentages, reset countdowns, and refresh-age text. |
| `CodexUsageRefreshPolicy.swift` | ~90 | Pure scheduling module for Adaptive backoff and fixed 2/5/15/30-minute refresh choices. |
| `CodexUsageGlyph.swift` | ~25 | Reusable code-native blue usage-bar glyph shared by the Codex settings header and dropdown footer. |
| `CodexUsageSettings.swift` | ~80 | Persisted menu bar visibility, per-window visibility, exhausted-limit countdown, and refresh-frequency preferences. |
| `CodexUsageSettingsView.swift` | ~325 | Standalone Codex usage overview, refresh-frequency picker, and display settings UI; hides five-hour controls unless Codex returns that window. |
| `CodexUsageSettingsWindowManager.swift` | ~50 | Owns the standalone resizable NSPanel that hosts `CodexUsageSettingsView`. |
| `AppearanceSettingsView.swift` | ~340 | Fixed preview and three Chinese settings tabs; six directly selectable head poses, follow/display controls and configurable arrival bubble. Available from the dropdown or app-active Appearance menu item. |
| `AppearanceSettingsWindowManager.swift` | ~53 | Owns the standalone resizable NSPanel that hosts `AppearanceSettingsView`. |
| `VoiceSettingsView.swift` | ~362 | Searchable and source-filtered MiniMax voice browser with cancellable per-voice preview, editable preview text, supported volume, speed, and pitch controls, and visible TTS errors. |
| `VoiceSettingsWindowManager.swift` | ~53 | Owns the standalone resizable NSPanel that hosts `VoiceSettingsView`. |
| `CompanionOverlayRuntime.swift` | ~600 | Shared cursor/auto-hide runtime, immediate attention and bounded settling, screen-synchronized flight, active-display selection and exact marker geometry. |
| `OverlayWindow.swift` | ~815 | Per-screen attention anchoring, target flight/return, short labels and input pulse; hosts the local living-avatar renderer. |
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
| `worker/minimax-computer-pointing.mjs` | ~95 | Read-only computer protocol with text-only conversational target resolution, fresh screenshot selection and strict coordinate parsing; no action execution. |
| `worker/minimax-pointing-precision.mjs` | ~120 | Local OCR anchor selection, compact-control pixel centering, and in-memory validated coordinate refinement. |
| `worker/vision-target-anchors.swift` | ~26 | Stdin-only Vision OCR helper with whitespace-tolerant exact-word anchors and top-left normalized boxes. |
| `worker/test/check-live-user-grounding.mjs` | ~60 | Explicit user-image replay with measured Save/Close/CSV regions and App-equivalent JPEG encoding. |
| `worker/test/check-pointing-variants.mjs` | ~85 | Generates and tests label swaps, translations, shrinking and missing targets; writes opt-in live evidence. |
| `worker/test/predict-click-target.mjs` | ~30 | Gets coordinates from the actual proxy for an isolated test window; does not click. |
| `worker/test/fixtures/PointingReplayHost.swift` | ~140 | Disposable native in-window mouse-event receiver with persistent hit/miss records; no OS-wide clicks. |
| `worker/test/check-live-voice-pointing.mjs` | ~55 | Synthesizes only known test instructions and verifies current TTS-to-Tencent-ASR target text without microphone capture. |
| `worker/test/check-live-pointing-followups.mjs` | ~55 | Opt-in real-proxy replay of follow-ups, intervening clarification, new targets and unresolved/absent targets against an approved screenshot; no desktop capture or clicks. |
| `worker/test/pointing-precision.test.mjs` | ~40 | Offline regression for positive labels, excluded alternatives, colored and outlined control centers, and uniform-background rejection. |
| `worker/third-party/osworld-m3-prompt.mjs` | ~6 | Pinned Apache-2.0 OSWorld M3 system prompt and macOS suffix; accompanying license is preserved. |
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

**Local signing identity**: The app and test targets use Manual Apple Development signing with the existing local team NW8P8WPH2H. Ad-hoc `CODE_SIGN_IDENTITY="-"` was confirmed to change the installed identity on every code update and repeatedly invalidate TCC grants. Preserve the development identity on this machine, verify the installed signature/requirement, and do not silently downgrade to ad-hoc if a certificate is unavailable. On another machine select that developer's valid team. Moving from the older ad-hoc install to this certificate may itself require one fresh confirmation; no TCC reset or permission bypass is allowed. Do not promise future permission persistence without checking the actual updated installation.

**Debug settings entry**: A Debug-only, one-shot UserDefaults key `matildaOpenScreenControlForTesting=true` opens the real Screen Control settings on the next launch and removes itself. This creates a CUA window for the menu-only app; it never enables screen operations or starts a test. Use it instead of repeatedly asking the user to expand the portrait panel. No practice controls are shipped. A locked Mac must be unlocked by the user, never bypassed.

**Opt-in native acceptance**: The test-target-only `nativeEventsAndDirectWindowClosingReachDisposableReceiver` runs when `com.nathan.clicky` preference `matildaRunNativeOperationAcceptance=true`. It creates its own disposable window, parses explicit commands, calls the production controller, checks actual mouse-event counts and direct AX closing, then verifies disabled/cancelled requests dispatch nothing. Run through Xcode UI with an unlocked Mac, do not interact with the desktop during that short test, remove the opt-in flag afterward and preserve the user's operation switch. It neither calls MiniMax nor validates new visual grounding or microphone input; those are separate acceptance scopes.

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

`worker/test/minimax-chat.test.mjs` and the local proxy tests cover M3.1 parameter migration, stream completion, cancellation, and structured screen-pointing validation. `worker/test/check-live-grounding.mjs` is an explicit live test (not part of `npm test`) using a synthetic UI generated by `worker/test/fixtures/make-grounding-fixture.swift`; it checks points against known control bounds, secondary screens, and absent targets without capturing the user's desktop. See docs/DEVELOPMENT.md for invocation. Synthetic hits are evidence for this fixture, not a guarantee of arbitrary desktop accuracy.

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

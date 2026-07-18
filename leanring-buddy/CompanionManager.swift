//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

func clickyDebugLog(_ message: String) {
    let line = "[DEBUG-PTT] \(Date()) \(message)\n"
    print(line, terminator: "")
    guard let data = line.data(using: .utf8) else { return }

    let logURL = URL(fileURLWithPath: "/tmp/clicky-debug.log")
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }

    do {
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    } catch {
        print("[DEBUG-PTT] failed to write debug log: \(error)")
    }
}

func clickyDebugSnippet(_ text: String, limit: Int = 240) -> String {
    let normalizedText = text
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
    if normalizedText.count <= limit {
        return normalizedText
    }
    return String(normalizedText.prefix(limit)) + "..."
}

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

struct CompanionConversationExchange: Identifiable, Equatable {
    let id: UUID
    let userTranscript: String
    let assistantResponse: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        userTranscript: String,
        assistantResponse: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userTranscript = userTranscript
        self.assistantResponse = assistantResponse
        self.createdAt = createdAt
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var visibleConversationHistory: [CompanionConversationExchange] = []
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = AppBundleConfiguration.workerBaseURL
    private static let maxConversationHistoryCount = 10
    private static let pointingConversationHistoryCount = 2
    private static let maxAssistantHistoryCharacters = 2_400
    private static let standardScreenshotLongEdgeInPixels = 2048
    private static let pointingScreenshotLongEdgeInPixels = 3072

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [CompanionConversationExchange] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    private var currentResponseTaskIdentifier = UUID()

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The MiniMax model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = {
        let storedModel = UserDefaults.standard.string(forKey: "selectedClaudeModel")
        if storedModel?.hasPrefix("claude-") == true {
            return "MiniMax-M3"
        }
        return storedModel ?? "MiniMax-M3"
    }()

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        clickyDebugLog("manager.start accessibility=\(hasAccessibilityPermission) screen=\(hasScreenRecordingPermission) mic=\(hasMicrophonePermission) screenContent=\(hasScreenContentPermission) onboarded=\(hasCompletedOnboarding) all=\(allPermissionsGranted)")
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentResponseTaskIdentifier = UUID()
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            clickyDebugLog("permissions accessibility=true starting-global-monitor")
            globalPushToTalkShortcutMonitor.start()
        } else {
            clickyDebugLog("permissions accessibility=false stopping-global-monitor")
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized
        clickyDebugLog("permissions accessibility=\(hasAccessibilityPermission) screen=\(hasScreenRecordingPermission) mic=\(hasMicrophonePermission) screenContent=\(hasScreenContentPermission) all=\(allPermissionsGranted)")

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    func togglePanelVoiceInput() {
        if buddyDictationManager.isDictationInProgress || buddyDictationManager.isPreparingToRecord {
            clickyDebugLog("panel voice-button stop")
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            return
        }

        clickyDebugLog("panel voice-button start")

        transientHideTask?.cancel()
        transientHideTask = nil

        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentResponseTaskIdentifier = UUID()
        elevenLabsTTSClient.stopPlayback()
        clearDetectedElementLocation()

        ClickyAnalytics.trackPushToTalkStarted()

        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = Task {
            await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                currentDraftText: "",
                updateDraftText: { _ in
                    // Partial transcripts are hidden (waveform-only UI)
                },
                submitDraftText: { [weak self] finalTranscript in
                    self?.lastTranscript = finalTranscript
                    print("🗣️ Companion received transcript: \(finalTranscript)")
                    clickyDebugLog("transcript \(clickyDebugSnippet(finalTranscript))")
                    ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                    self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                }
            )
        }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            clickyDebugLog("shortcut pressed dictationInProgress=\(buddyDictationManager.isDictationInProgress) onboardingVideo=\(showOnboardingVideo)")
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            currentResponseTask = nil
            currentResponseTaskIdentifier = UUID()
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        clickyDebugLog("transcript \(clickyDebugSnippet(finalTranscript))")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            clickyDebugLog("shortcut released")
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    language:
    - reply in the same language the user spoke.
    - for this local build, default to natural simplified chinese unless the user explicitly asks for another language.
    - if the user speaks chinese, answer in simplified chinese even if the screen contains english text.
    - do not tell the user to allow or grant permissions unless their request is about permissions or a real missing-permission error is present.
    - never read a [POINT_V2:...] or legacy [POINT:...] tag aloud. keep it only as a machine-readable suffix.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - if replying in english, use lowercase, casual, warm language. no emojis.
    - write for the ear, not the eye. short sentences. for normal answers, no lists, bullet points, markdown, or formatting — just natural speech.
    - if the user asks for code, commands, config, prompts, or other copyable text, include the copyable content in fenced markdown code blocks. keep the spoken explanation short; the app will show the code in the menu panel and will not read code blocks aloud.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    - pointing is opt-in for each request. only return a [POINT_V2:...] tag when the current user message includes an internal clicky pointing requirement.
    - without that requirement, never emit any point tag and never claim that you pointed, showed, guided, or indicated a screen location.
    - when pointing is requested but the exact target is not clearly visible, return [POINT_V2:none] rather than guessing.
    """

    private static func userPromptWithPointingContract(
        _ transcript: String,
        shouldRequestPointing: Bool
    ) -> String {
        guard shouldRequestPointing else {
            return """
            \(transcript)

            internal clicky requirement: this is not a pointing request. answer normally. do not output any [POINT_V2:...] or [POINT:...] tag and do not claim to point at a screen location.
            """
        }

        return """
        \(transcript)

        internal clicky pointing requirement:
        - inspect the current screenshot and end your entire response with exactly one machine-readable V2 tag: [POINT_V2:x,y:label] or [POINT_V2:none]. never use the legacy [POINT:...] format.
        - x and y are normalized integers from 0 through 1000, independent of the screenshot's pixel dimensions. origin is top-left; x increases rightward and y increases downward.
        - calibration anchors: top-left is (0,0), exact center is (500,500), and bottom-right is (1000,1000).
        - first identify the target's visible bounding box, then visually verify and return its center. for a desktop file or folder, use the center of its icon, not its filename. for a button or menu item, use the center of the clickable control.
        - use a short 1-3 word label: [POINT_V2:x,y:label]. if the target is on a labeled secondary screen, append its screen number: [POINT_V2:x,y:label:screenN].
        - do not reuse coordinates from earlier messages and do not infer them from a typical layout. inspect the current screenshot every time.
        - if the exact requested target is not visible or you are uncertain which target matches, use [POINT_V2:none]. do not guess an approximate area.
        - never say you pointed, showed, or indicated something unless the tag contains coordinates. the user will not hear the tag.
        """
    }

    // MARK: - AI Response Pipeline

    private func appendConversationHistory(userTranscript: String, assistantResponse: String) {
        conversationHistory.append(CompanionConversationExchange(
            userTranscript: userTranscript,
            assistantResponse: assistantResponse
        ))

        if conversationHistory.count > Self.maxConversationHistoryCount {
            conversationHistory.removeFirst(conversationHistory.count - Self.maxConversationHistoryCount)
        }

        visibleConversationHistory = conversationHistory
    }


    /// Captures a screenshot, sends it along with the transcript to MiniMax,
    /// and plays the response aloud via MiniMax TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// MiniMax may return a point tag only when the user's words explicitly
    /// request on-screen location help.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        let shouldRequestPointing = PointingRequestPolicy.shouldRequestPointing(for: transcript)
        let responseTaskIdentifier = UUID()
        currentResponseTaskIdentifier = responseTaskIdentifier
        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Small controls need more source pixels for reliable pointing,
                // while ordinary chat keeps the lighter screenshot payload.
                let screenshotLongEdgeInPixels = shouldRequestPointing
                    ? Self.pointingScreenshotLongEdgeInPixels
                    : Self.standardScreenshotLongEdgeInPixels
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(
                    longEdgeInPixels: screenshotLongEdgeInPixels
                )

                guard !Task.isCancelled else { return }

                let labeledImages = screenCaptures.map { capture in
                    return (data: capture.imageData, label: capture.label)
                }

                // Older screen coordinates are actively harmful to a new pointing
                // request, so location work receives only the latest two exchanges.
                let conversationHistoryForRequest = shouldRequestPointing
                    ? Array(conversationHistory.suffix(Self.pointingConversationHistoryCount))
                    : conversationHistory
                let historyForAPI = conversationHistoryForRequest.map { entry in
                    (
                        userPlaceholder: entry.userTranscript,
                        assistantResponse: Self.textForConversationContext(from: entry.assistantResponse)
                    )
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: Self.userPromptWithPointingContract(
                        transcript,
                        shouldRequestPointing: shouldRequestPointing
                    ),
                    temperature: shouldRequestPointing ? 0.1 : nil,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                // Always strip accidental point tags from display and speech.
                // Only the user's original words can authorize cursor movement.
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let pointCoordinate = shouldRequestPointing ? parseResult.coordinate : nil
                let displayText = parseResult.spokenText
                let spokenText = Self.textForSpeech(from: displayText)
                clickyDebugLog("llm full-response \(clickyDebugSnippet(fullResponseText))")
                clickyDebugLog("tts spoken-text \(clickyDebugSnippet(spokenText))")
                clickyDebugLog("point requested=\(shouldRequestPointing) coordinate=\(String(describing: pointCoordinate)) label=\(parseResult.elementLabel ?? "nil")")

                // Handle element pointing if MiniMax returned coordinates for an
                // explicitly requested target.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                if pointCoordinate != nil {
                    voiceState = .idle
                }

                // Pick the screen capture matching MiniMax's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate,
                   let targetScreenCapture {
                    if !isOverlayVisible {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                        clickyDebugLog("point overlay-show-for-target")
                    }

                    let displayFrame = targetScreenCapture.displayFrame
                    let globalLocation = Self.globalScreenLocation(
                        fromNormalizedCoordinate: pointCoordinate,
                        displayFrame: displayFrame
                    )

                    detectedElementDisplayFrame = displayFrame
                    detectedElementScreenLocation = globalLocation
                    clickyDebugLog("point target screenLocation=\(globalLocation) displayFrame=\(displayFrame) normalized1000=\(pointCoordinate)")
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save the full display response for both the panel history and
                // future context. TTS may use a shorter version when code blocks
                // are present, but the user still needs the complete answer.
                appendConversationHistory(userTranscript: transcript, assistantResponse: displayText)

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: displayText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                if currentResponseTaskIdentifier == responseTaskIdentifier {
                    currentResponseTask = nil
                    scheduleTransientHideIfNeeded()
                }
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// TTS is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I'm all out of credits. Please DM Farza and tell him to bring me back to life."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a normalized point tag from MiniMax's response.
    struct PointingParseResult {
        /// The response text with the point tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed 0...1000 coordinate, or nil when no valid V2 coordinate was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a normalized V2 point tag from the end of MiniMax's response.
    /// Legacy pixel tags are stripped so they are never spoken, but cannot move the cursor.
    nonisolated static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        let normalizedPointPattern = #"\[POINT_V2:\s*(?:none|(\d{1,4})\s*,\s*(\d{1,4})(?::([^\]:\r\n]*?))?(?::screen(\d+))?)\]?\s*$"#
        let responseRange = NSRange(responseText.startIndex..., in: responseText)

        if let normalizedPointRegex = try? NSRegularExpression(pattern: normalizedPointPattern),
           let match = normalizedPointRegex.firstMatch(in: responseText, range: responseRange),
           let tagRange = Range(match.range, in: responseText) {
            let spokenText = String(responseText[..<tagRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let xRange = Range(match.range(at: 1), in: responseText),
                  let yRange = Range(match.range(at: 2), in: responseText),
                  let xCoordinate = Double(responseText[xRange]),
                  let yCoordinate = Double(responseText[yRange]) else {
                return PointingParseResult(
                    spokenText: spokenText,
                    coordinate: nil,
                    elementLabel: "none",
                    screenNumber: nil
                )
            }

            let elementLabel: String? = {
                guard let labelRange = Range(match.range(at: 3), in: responseText) else {
                    return nil
                }
                return String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
            }()
            let screenNumber: Int? = {
                guard let screenRange = Range(match.range(at: 4), in: responseText) else {
                    return nil
                }
                return Int(responseText[screenRange])
            }()

            guard (0...1000).contains(xCoordinate),
                  (0...1000).contains(yCoordinate) else {
                return PointingParseResult(
                    spokenText: spokenText,
                    coordinate: nil,
                    elementLabel: elementLabel,
                    screenNumber: screenNumber
                )
            }

            return PointingParseResult(
                spokenText: spokenText,
                coordinate: CGPoint(x: xCoordinate, y: yCoordinate),
                elementLabel: elementLabel,
                screenNumber: screenNumber
            )
        }

        let malformedV2PointPattern = #"\[POINT_V2:[^\]\r\n]*\]?\s*$"#
        if let malformedV2PointRegex = try? NSRegularExpression(pattern: malformedV2PointPattern),
           let match = malformedV2PointRegex.firstMatch(in: responseText, range: responseRange),
           let tagRange = Range(match.range, in: responseText) {
            let spokenText = String(responseText[..<tagRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PointingParseResult(
                spokenText: spokenText,
                coordinate: nil,
                elementLabel: nil,
                screenNumber: nil
            )
        }

        let legacyPointPattern = #"\[POINT:\s*(?:none|\d+\s*,\s*\d+(?::[^\]\r\n]*)?)\]?\s*$"#
        if let legacyPointRegex = try? NSRegularExpression(pattern: legacyPointPattern),
           let match = legacyPointRegex.firstMatch(in: responseText, range: responseRange),
           let tagRange = Range(match.range, in: responseText) {
            let spokenText = String(responseText[..<tagRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PointingParseResult(
                spokenText: spokenText,
                coordinate: nil,
                elementLabel: nil,
                screenNumber: nil
            )
        }

        return PointingParseResult(
            spokenText: responseText,
            coordinate: nil,
            elementLabel: nil,
            screenNumber: nil
        )
    }

    /// Converts a normalized top-left-origin model coordinate into AppKit's
    /// global bottom-left-origin screen coordinate system.
    nonisolated static func globalScreenLocation(
        fromNormalizedCoordinate normalizedCoordinate: CGPoint,
        displayFrame: CGRect
    ) -> CGPoint {
        let clampedXCoordinate = max(0, min(normalizedCoordinate.x, 1000))
        let clampedYCoordinate = max(0, min(normalizedCoordinate.y, 1000))
        let displayLocalX = clampedXCoordinate / 1000 * displayFrame.width
        let displayLocalYFromTop = clampedYCoordinate / 1000 * displayFrame.height

        return CGPoint(
            x: displayFrame.origin.x + displayLocalX,
            y: displayFrame.origin.y + displayFrame.height - displayLocalYFromTop
        )
    }

    nonisolated private static func textForSpeech(from displayText: String) -> String {
        let codeBlockPattern = #"```[\s\S]*?```"#
        guard let codeBlockRegex = try? NSRegularExpression(pattern: codeBlockPattern),
              codeBlockRegex.firstMatch(
                in: displayText,
                range: NSRange(displayText.startIndex..., in: displayText)
              ) != nil else {
            return displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let displayTextRange = NSRange(displayText.startIndex..., in: displayText)
        var speechText = codeBlockRegex.stringByReplacingMatches(
            in: displayText,
            range: displayTextRange,
            withTemplate: "\n"
        )

        speechText = speechText
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let copyPrompt = "代码已经写好，可以在面板里复制。"
        if speechText.isEmpty {
            return copyPrompt
        }

        if speechText.contains("复制") {
            return speechText
        }

        return "\(speechText) \(copyPrompt)"
    }

    nonisolated private static func textForConversationContext(from displayText: String) -> String {
        guard displayText.count > maxAssistantHistoryCharacters else {
            return displayText
        }

        return String(displayText.prefix(maxAssistantHistoryCharacters))
            + "\n\n[previous assistant response truncated for context]"
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: use normalized integer coordinates from 0 through 1000. top-left is (0,0), center is (500,500), and bottom-right is (1000,1000). you MUST only pick elements near the CENTER of the screen: both x and y must be between 200 and 800. do NOT pick menu bar items, dock icons, sidebar items, or anything near an edge. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT_V2:x,y:label]

    visually identify the target's bounding box, verify it against the current screenshot, and return the center. never use the legacy [POINT:...] format.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(
                    longEdgeInPixels: Self.pointingScreenshotLongEdgeInPixels
                )

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    temperature: 0.1,
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let displayFrame = cursorScreenCapture.displayFrame
                let globalLocation = Self.globalScreenLocation(
                    fromNormalizedCoordinate: pointCoordinate,
                    displayFrame: displayFrame
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}

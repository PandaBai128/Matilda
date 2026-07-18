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

    @Published var selectedTTSVoiceID: String = UserDefaults.standard.string(forKey: "selectedMiniMaxTTSVoiceID")
        ?? "Chinese (Mandarin)_Warm_Bestie"
    @Published var ttsVolume: Double = {
        guard UserDefaults.standard.object(forKey: "miniMaxTTSVolume") != nil else { return 2.5 }
        return min(max(UserDefaults.standard.double(forKey: "miniMaxTTSVolume"), 0.1), 10)
    }()
    @Published var ttsSpeed: Double = {
        guard UserDefaults.standard.object(forKey: "miniMaxTTSSpeed") != nil else { return 1 }
        return min(max(UserDefaults.standard.double(forKey: "miniMaxTTSSpeed"), 0.5), 2)
    }()
    @Published var ttsPitch: Int = {
        guard UserDefaults.standard.object(forKey: "miniMaxTTSPitch") != nil else { return 0 }
        return min(max(UserDefaults.standard.integer(forKey: "miniMaxTTSPitch"), -12), 12)
    }()
    @Published var ttsEmotion: String = UserDefaults.standard.string(forKey: "miniMaxTTSEmotion")
        ?? "automatic"
    @Published private(set) var availableTTSVoices: [MiniMaxVoiceOption] = []
    @Published private(set) var isLoadingTTSVoices = false
    @Published private(set) var ttsVoiceCatalogErrorMessage: String?

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    func setSelectedTTSVoiceID(_ voiceID: String) {
        selectedTTSVoiceID = voiceID
        UserDefaults.standard.set(voiceID, forKey: "selectedMiniMaxTTSVoiceID")
    }

    func setTTSVolume(_ volume: Double) {
        let normalizedVolume = min(max(volume, 0.1), 10)
        ttsVolume = normalizedVolume
        UserDefaults.standard.set(normalizedVolume, forKey: "miniMaxTTSVolume")
    }

    func setTTSSpeed(_ speed: Double) {
        let normalizedSpeed = min(max(speed, 0.5), 2)
        ttsSpeed = normalizedSpeed
        UserDefaults.standard.set(normalizedSpeed, forKey: "miniMaxTTSSpeed")
    }

    func setTTSPitch(_ pitch: Int) {
        let normalizedPitch = min(max(pitch, -12), 12)
        ttsPitch = normalizedPitch
        UserDefaults.standard.set(normalizedPitch, forKey: "miniMaxTTSPitch")
    }

    func setTTSEmotion(_ emotion: String) {
        ttsEmotion = emotion
        UserDefaults.standard.set(emotion, forKey: "miniMaxTTSEmotion")
    }

    var selectedTTSVoiceDisplayName: String {
        availableTTSVoices.first(where: { $0.voiceID == selectedTTSVoiceID })?.displayName
            ?? selectedTTSVoiceID
    }

    func loadAvailableTTSVoices() {
        guard !isLoadingTTSVoices else { return }
        isLoadingTTSVoices = true
        ttsVoiceCatalogErrorMessage = nil

        Task {
            do {
                availableTTSVoices = try await elevenLabsTTSClient.fetchAvailableVoices()
            } catch {
                ttsVoiceCatalogErrorMessage = "Couldn't load voices"
                print("⚠️ MiniMax voice catalog error: \(error)")
            }
            isLoadingTTSVoices = false
        }
    }

    func previewTTSVoice(voiceID: String? = nil, text: String) {
        elevenLabsTTSClient.stopPlayback()
        Task {
            do {
                try await elevenLabsTTSClient.speakText(
                    text,
                    voiceID: voiceID ?? selectedTTSVoiceID,
                    volume: ttsVolume,
                    speed: ttsSpeed,
                    pitch: ttsPitch,
                    emotion: ttsEmotion
                )
            } catch {
                print("⚠️ MiniMax voice preview error: \(error)")
            }
        }
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
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    func start() {
        refreshAllPermissions()
        clickyDebugLog("manager.start accessibility=\(hasAccessibilityPermission) screen=\(hasScreenRecordingPermission) mic=\(hasMicrophonePermission) screenContent=\(hasScreenContentPermission) all=\(allPermissionsGranted)")
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the API clients so network setup begins before the first interaction.
        _ = claudeAPI
        loadAvailableTTSVoices()

        // Show the cursor immediately when permissions are available. If signing
        // changes revoke them, the panel shows the permission controls instead.
        if allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
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
    /// so they're not asked again on every launch.
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

                    if allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
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
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentResponseTaskIdentifier = UUID()
        elevenLabsTTSClient.stopPlayback()
        voiceState = .idle
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
            clickyDebugLog("shortcut pressed dictationInProgress=\(buddyDictationManager.isDictationInProgress)")
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
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
            voiceState = .idle
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
    you're clicky, a screen-aware voice companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your job is to understand the current screen, answer the user's question, explain what they are seeing, and visually guide them when a visible target is relevant. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    language:
    - reply in the same language the user spoke.
    - for this local build, default to natural simplified chinese unless the user explicitly asks for another language.
    - if the user speaks chinese, answer in simplified chinese even if the screen contains english text.
    - do not tell the user to allow or grant permissions unless their request is about permissions or a real missing-permission error is present.
    - never read a [POINT_V2:...] or legacy [POINT:...] tag aloud. keep it only as a machine-readable suffix.

    rules:
    - default to one or two sentences. be direct and dense. if the user explicitly asks for more detail, explain enough to resolve the current question while staying focused on the current screen or topic.
    - if replying in english, use lowercase, casual, warm language. no emojis.
    - write for the ear, not the eye. short sentences. for normal answers, no lists, bullet points, markdown, or formatting — just natural speech.
    - do not proactively offer scripts, commands, automation, code, or ways to control the computer. those are outside your role.
    - if the user explicitly asks for a short piece of copyable text, include only that content in a fenced markdown block and keep the spoken explanation short. do not turn a normal question into a coding task.
    - you cannot click, type, press keys, run commands, create or save files, execute scripts, or operate apps. never claim that you did or can do any of those things. you can only explain and point to a visible location.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - answer the current request completely, then stop. do not end by offering additional work, asking whether the user wants code, or suggesting unrelated next steps.
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
        - for a question asking what the current page or app is, point to the clearest visible identity anchor, such as the app icon, app name, page title, or product logo that supports your answer.
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

                let streamingSpeechSession = StreamingSpeechResponseSession(
                    ttsClient: elevenLabsTTSClient,
                    voiceID: selectedTTSVoiceID,
                    volume: ttsVolume,
                    speed: ttsSpeed,
                    pitch: ttsPitch,
                    emotion: ttsEmotion
                )
                streamingSpeechSession.begin(
                    onPlaybackStarted: { [weak self] in
                        guard let self,
                              self.currentResponseTaskIdentifier == responseTaskIdentifier else { return }
                        self.voiceState = .responding
                    },
                    onFailure: { error in
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ Streaming TTS error: \(error)")
                    }
                )

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: Self.userPromptWithPointingContract(
                        transcript,
                        shouldRequestPointing: shouldRequestPointing
                    ),
                    temperature: shouldRequestPointing ? 0.1 : nil,
                    onTextChunk: { accumulatedText in
                        guard self.currentResponseTaskIdentifier == responseTaskIdentifier,
                              !Task.isCancelled else { return }
                        streamingSpeechSession.consume(accumulatedText: accumulatedText)
                    }
                )

                guard !Task.isCancelled else { return }

                // Always strip accidental point tags from display and speech.
                // Only the user's original words can authorize cursor movement.
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let pointCoordinate = shouldRequestPointing ? parseResult.coordinate : nil
                let displayText = parseResult.spokenText
                streamingSpeechSession.finish(finalAccumulatedText: fullResponseText)
                clickyDebugLog("llm full-response \(clickyDebugSnippet(fullResponseText))")
                clickyDebugLog("point requested=\(shouldRequestPointing) coordinate=\(String(describing: pointCoordinate)) label=\(parseResult.elementLabel ?? "nil")")

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

                // Keep this response task alive until all synthesized sentence
                // segments finish so a new push-to-talk can cancel the whole queue.
                while elevenLabsTTSClient.isPlaying {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
                elevenLabsTTSClient.stopPlayback()
            } catch {
                elevenLabsTTSClient.stopPlayback()
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

    nonisolated private static func textForConversationContext(from displayText: String) -> String {
        guard displayText.count > maxAssistantHistoryCharacters else {
            return displayText
        }

        return String(displayText.prefix(maxAssistantHistoryCharacters))
            + "\n\n[previous assistant response truncated for context]"
    }

}

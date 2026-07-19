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
import OSLog
import ScreenCaptureKit
import SwiftUI

#if DEBUG
private let matildaDebugLogger = Logger(subsystem: "com.nathan.clicky", category: "runtime")
#endif

func matildaDebugLog(_ message: @autoclosure @escaping () -> String) {
#if DEBUG
    matildaDebugLogger.debug("\(message(), privacy: .private(mask: .hash))")
#endif
}

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

enum CompanionResponseLength: String, CaseIterable {
    case brief
    case normal
    case detailed

    var displayName: String {
        switch self {
        case .brief: return "Brief"
        case .normal: return "Normal"
        case .detailed: return "Detailed"
        }
    }

    var systemPromptInstruction: String {
        switch self {
        case .brief:
            return "keep the answer to one or two concise sentences unless the user explicitly asks for more detail."
        case .normal:
            return "answer naturally with enough context to resolve the question, usually in two to four sentences. do not shorten an explanation so much that the user loses the reason or the next step."
        case .detailed:
            return "give a thorough explanation with the relevant reasoning and concrete guidance. use as many spoken sentences as needed, but stay focused on the current question and screen."
        }
    }
}

enum CompanionAvatarSize: String, CaseIterable {
    case small
    case medium
    case large

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var diameter: CGFloat {
        switch self {
        case .small: return 20
        case .medium: return 30
        case .large: return 42
        }
    }

}

enum CompanionCursorDistance: String, CaseIterable {
    case near
    case medium
    case far

    var displayName: String {
        switch self {
        case .near: return "Near"
        case .medium: return "Medium"
        case .far: return "Far"
        }
    }

    func cursorOffset(for companionAvatarSize: CompanionAvatarSize) -> CGPoint {
        let avatarRadius = companionAvatarSize.diameter / 2
        switch self {
        case .near:
            return CGPoint(x: avatarRadius + 10, y: avatarRadius + 6)
        case .medium:
            return CGPoint(x: avatarRadius + 20, y: avatarRadius + 10)
        case .far:
            return CGPoint(x: avatarRadius + 34, y: avatarRadius + 20)
        }
    }
}

enum CompanionFollowResponse: String, CaseIterable {
    case quick
    case natural
    case relaxed

    var displayName: String {
        switch self {
        case .quick: return "Fast"
        case .natural: return "Medium"
        case .relaxed: return "Slow"
        }
    }

    private var responseTimeSeconds: Double? {
        switch self {
        case .quick: return nil
        case .natural: return 0.12
        case .relaxed: return 0.22
        }
    }

    func smoothingFraction(frameDurationSeconds: Double) -> CGFloat {
        guard let responseTimeSeconds else { return 1 }
        return CGFloat(1 - exp(-frameDurationSeconds / responseTimeSeconds))
    }
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
    static let defaultCompanionAutoHideDelaySeconds: Double = 10

    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var visibleConversationHistory: [CompanionConversationExchange] = []
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from MiniMax's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

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
    private let systemSpeechFallbackController = SystemSpeechFallbackController()

    /// Conversation history so MiniMax remembers prior exchanges within a session.
    /// Each entry is the user's transcript and MiniMax's response.
    private var conversationHistory: [CompanionConversationExchange] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    private var currentResponseTaskIdentifier = UUID()
    private var ttsVoicePreviewTask: Task<Void, Never>?
    private var ttsVoicePreviewIdentifier = UUID()

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all four required permissions are granted. Used by the panel to
    /// show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the companion overlay is currently visible on screen.
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
    @Published private(set) var responseLength: CompanionResponseLength = {
        guard let storedValue = UserDefaults.standard.string(forKey: "clickyResponseLength"),
              let storedResponseLength = CompanionResponseLength(rawValue: storedValue) else {
            return .normal
        }
        return storedResponseLength
    }()
    @Published private(set) var companionAvatarSize: CompanionAvatarSize = {
        guard let storedValue = UserDefaults.standard.string(forKey: "zhuangzhuangAvatarSize"),
              let storedSize = CompanionAvatarSize(rawValue: storedValue) else {
            return .medium
        }
        return storedSize
    }()
    @Published private(set) var companionCursorDistance: CompanionCursorDistance = {
        guard let storedValue = UserDefaults.standard.string(forKey: "zhuangzhuangCursorDistance"),
              let storedDistance = CompanionCursorDistance(rawValue: storedValue) else {
            return .medium
        }
        return storedDistance
    }()
    @Published private(set) var companionFollowResponse: CompanionFollowResponse = {
        guard let storedValue = UserDefaults.standard.string(forKey: "zhuangzhuangFollowResponse"),
              let storedResponse = CompanionFollowResponse(rawValue: storedValue) else {
            return .natural
        }
        return storedResponse
    }()
    @Published private(set) var isCompanionGlowEnabled: Bool = UserDefaults.standard.object(forKey: "zhuangzhuangGlowEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "zhuangzhuangGlowEnabled")
    @Published private(set) var companionGlowColorHex: String = UserDefaults.standard.string(forKey: "zhuangzhuangGlowColorHex")
        ?? "#3380FF"
    @Published private(set) var companionGlowIntensity: Double = {
        guard UserDefaults.standard.object(forKey: "zhuangzhuangGlowIntensity") != nil else { return 0.45 }
        return min(max(UserDefaults.standard.double(forKey: "zhuangzhuangGlowIntensity"), 0.1), 1)
    }()
    @Published private(set) var isCompanionAutoHideEnabled: Bool = UserDefaults.standard.object(forKey: "zhuangzhuangAutoHideEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "zhuangzhuangAutoHideEnabled")
    @Published private(set) var companionAutoHideDelaySeconds: Double = {
        guard UserDefaults.standard.object(forKey: "zhuangzhuangAutoHideDelaySeconds") != nil else {
            return CompanionManager.defaultCompanionAutoHideDelaySeconds
        }
        return min(max(UserDefaults.standard.double(forKey: "zhuangzhuangAutoHideDelaySeconds"), 2), 30)
    }()
    @Published private(set) var companionPointingMarkerDiameter: Double = {
        guard UserDefaults.standard.object(forKey: "zhuangzhuangPointingMarkerDiameter") != nil else { return 32 }
        return min(max(UserDefaults.standard.double(forKey: "zhuangzhuangPointingMarkerDiameter"), 20), 64)
    }()
    @Published private(set) var isCompanionPointingCenterDotEnabled: Bool = UserDefaults.standard.object(
        forKey: "zhuangzhuangPointingCenterDotEnabled"
    ) == nil
        ? true
        : UserDefaults.standard.bool(forKey: "zhuangzhuangPointingCenterDotEnabled")
    @Published private(set) var companionPointingMarkerColorHex: String = UserDefaults.standard.string(
        forKey: "zhuangzhuangPointingMarkerColorHex"
    ) ?? "#3380FF"
    @Published private(set) var companionPointingLabelBackgroundColorHex: String = UserDefaults.standard.string(
        forKey: "zhuangzhuangPointingLabelBackgroundColorHex"
    ) ?? "#3380FF"

    var companionGlowColor: Color {
        Color(hex: companionGlowColorHex)
    }

    var companionPointingMarkerColor: Color {
        Color(hex: companionPointingMarkerColorHex)
    }

    var companionPointingLabelBackgroundColor: Color {
        Color(hex: companionPointingLabelBackgroundColorHex)
    }

    var companionPointingLabelForegroundColor: Color {
        guard let sRGBColor = NSColor(companionPointingLabelBackgroundColor).usingColorSpace(.sRGB) else {
            return .white
        }
        let relativeLuminance = (0.2126 * sRGBColor.redComponent)
            + (0.7152 * sRGBColor.greenComponent)
            + (0.0722 * sRGBColor.blueComponent)
        return relativeLuminance > 0.62 ? Color.black.opacity(0.82) : .white
    }

    @Published var selectedTTSVoiceID: String = UserDefaults.standard.string(forKey: "selectedMiniMaxTTSVoiceID")
        ?? "Chinese (Mandarin)_Warm_Bestie"
    @Published var ttsVolume: Double = {
        guard UserDefaults.standard.object(forKey: "miniMaxTTSVolume") != nil else { return 1 }
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
    let ttsEmotion = "automatic"
    @Published private(set) var availableTTSVoices: [MiniMaxVoiceOption] = []
    @Published private(set) var isLoadingTTSVoices = false
    @Published private(set) var ttsVoiceCatalogErrorMessage: String?
    @Published private(set) var isPreviewingTTSVoice = false
    @Published private(set) var previewingTTSVoiceID: String?
    @Published private(set) var ttsVoicePreviewErrorMessage: String?
    @Published private(set) var ttsSpeechErrorMessage: String?

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    func setResponseLength(_ responseLength: CompanionResponseLength) {
        self.responseLength = responseLength
        UserDefaults.standard.set(responseLength.rawValue, forKey: "clickyResponseLength")
    }

    func setCompanionAvatarSize(_ companionAvatarSize: CompanionAvatarSize) {
        self.companionAvatarSize = companionAvatarSize
        UserDefaults.standard.set(companionAvatarSize.rawValue, forKey: "zhuangzhuangAvatarSize")
    }

    func setCompanionCursorDistance(_ companionCursorDistance: CompanionCursorDistance) {
        self.companionCursorDistance = companionCursorDistance
        UserDefaults.standard.set(companionCursorDistance.rawValue, forKey: "zhuangzhuangCursorDistance")
    }

    func setCompanionFollowResponse(_ companionFollowResponse: CompanionFollowResponse) {
        self.companionFollowResponse = companionFollowResponse
        UserDefaults.standard.set(companionFollowResponse.rawValue, forKey: "zhuangzhuangFollowResponse")
    }

    func setCompanionGlowEnabled(_ enabled: Bool) {
        isCompanionGlowEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "zhuangzhuangGlowEnabled")
    }

    func setCompanionGlowColor(_ color: Color) {
        guard let colorHex = colorHex(for: color) else { return }
        companionGlowColorHex = colorHex
        UserDefaults.standard.set(colorHex, forKey: "zhuangzhuangGlowColorHex")
    }

    func setCompanionGlowIntensity(_ intensity: Double) {
        let normalizedIntensity = min(max(intensity, 0.1), 1)
        companionGlowIntensity = normalizedIntensity
        UserDefaults.standard.set(normalizedIntensity, forKey: "zhuangzhuangGlowIntensity")
    }

    func setCompanionAutoHideEnabled(_ enabled: Bool) {
        isCompanionAutoHideEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "zhuangzhuangAutoHideEnabled")
    }

    func setCompanionAutoHideDelaySeconds(_ delaySeconds: Double) {
        let normalizedDelaySeconds = min(max(delaySeconds.rounded(), 2), 30)
        companionAutoHideDelaySeconds = normalizedDelaySeconds
        UserDefaults.standard.set(normalizedDelaySeconds, forKey: "zhuangzhuangAutoHideDelaySeconds")
    }

    func setCompanionPointingMarkerDiameter(_ markerDiameter: Double) {
        let normalizedMarkerDiameter = min(max(markerDiameter.rounded(), 20), 64)
        companionPointingMarkerDiameter = normalizedMarkerDiameter
        UserDefaults.standard.set(normalizedMarkerDiameter, forKey: "zhuangzhuangPointingMarkerDiameter")
    }

    func setCompanionPointingCenterDotEnabled(_ enabled: Bool) {
        isCompanionPointingCenterDotEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "zhuangzhuangPointingCenterDotEnabled")
    }

    func setCompanionPointingMarkerColor(_ color: Color) {
        guard let colorHex = colorHex(for: color) else { return }
        companionPointingMarkerColorHex = colorHex
        UserDefaults.standard.set(colorHex, forKey: "zhuangzhuangPointingMarkerColorHex")
    }

    func setCompanionPointingLabelBackgroundColor(_ color: Color) {
        guard let colorHex = colorHex(for: color) else { return }
        companionPointingLabelBackgroundColorHex = colorHex
        UserDefaults.standard.set(colorHex, forKey: "zhuangzhuangPointingLabelBackgroundColorHex")
    }

    private func colorHex(for color: Color) -> String? {
        guard let sRGBColor = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let red = Int(round(sRGBColor.redComponent * 255))
        let green = Int(round(sRGBColor.greenComponent * 255))
        let blue = Int(round(sRGBColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
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
        cancelTTSVoicePreview()
        let previewIdentifier = UUID()
        ttsVoicePreviewIdentifier = previewIdentifier
        isPreviewingTTSVoice = true
        previewingTTSVoiceID = voiceID ?? selectedTTSVoiceID
        ttsVoicePreviewErrorMessage = nil

        ttsVoicePreviewTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await elevenLabsTTSClient.speakText(
                    text,
                    voiceID: voiceID ?? selectedTTSVoiceID,
                    volume: ttsVolume,
                    speed: ttsSpeed,
                    pitch: ttsPitch,
                    emotion: ttsEmotion
                )
                guard previewIdentifier == ttsVoicePreviewIdentifier else { return }
            } catch {
                guard previewIdentifier == ttsVoicePreviewIdentifier else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return
                }
                ttsVoicePreviewErrorMessage = error.localizedDescription
                print("⚠️ MiniMax voice preview error: \(error)")
            }
            guard previewIdentifier == ttsVoicePreviewIdentifier else { return }
            isPreviewingTTSVoice = false
            previewingTTSVoiceID = nil
            ttsVoicePreviewTask = nil
        }
    }

    func cancelTTSVoicePreview() {
        ttsVoicePreviewIdentifier = UUID()
        ttsVoicePreviewTask?.cancel()
        ttsVoicePreviewTask = nil
        isPreviewingTTSVoice = false
        previewingTTSVoiceID = nil
        elevenLabsTTSClient.stopCompleteSpeechPlayback()
    }

    private func stopAllSpeechAndCancelPreview() {
        cancelTTSVoicePreview()
        elevenLabsTTSClient.stopPlayback()
        systemSpeechFallbackController.stop()
    }

    /// User preference for whether the Zhuangzhuang companion should be shown.
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
        UserDefaults.standard.removeObject(forKey: "miniMaxTTSEmotion")
        refreshAllPermissions()
        matildaDebugLog("manager started")
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
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        stopAllSpeechAndCancelPreview()
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

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if previouslyHadAccessibility != currentlyHasAccessibility {
            if currentlyHasAccessibility {
                matildaDebugLog("accessibility granted; starting global shortcut monitor")
                globalPushToTalkShortcutMonitor.start()
            } else {
                matildaDebugLog("accessibility removed; stopping global shortcut monitor")
                globalPushToTalkShortcutMonitor.stop()
            }
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            matildaDebugLog("permission state changed")
        }

        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
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
            matildaDebugLog("panel voice button stopped")
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            return
        }

        matildaDebugLog("panel voice button started")

        transientHideTask?.cancel()
        transientHideTask = nil

        if !isOverlayVisible {
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentResponseTaskIdentifier = UUID()
        stopAllSpeechAndCancelPreview()
        voiceState = .idle
        clearDetectedElementLocation()


        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = Task {
            await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                currentDraftText: "",
                updateDraftText: { _ in
                    // Partial transcripts are hidden (waveform-only UI)
                },
                submitDraftText: { [weak self] finalTranscript in
                    self?.lastTranscript = finalTranscript
                    matildaDebugLog("panel transcript received")
                    self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                }
            )
        }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            matildaDebugLog("shortcut pressed")
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
            stopAllSpeechAndCancelPreview()
            voiceState = .idle
            clearDetectedElementLocation()


            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        matildaDebugLog("shortcut transcript received")
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            matildaDebugLog("shortcut released")
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private var companionVoiceResponseSystemPrompt: String {
        """
    you're 壮壮, a screen-aware voice companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your job is to understand the current screen, answer the user's question, explain what they are seeing, and visually guide them when a visible target is relevant. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    language:
    - reply in the same language the user spoke.
    - for this local build, default to natural simplified chinese unless the user explicitly asks for another language.
    - if the user speaks chinese, answer in simplified chinese even if the screen contains english text.
    - do not tell the user to allow or grant permissions unless their request is about permissions or a real missing-permission error is present.
    - never read a [POINT_V2:...] or legacy [POINT:...] tag aloud. keep it only as a machine-readable suffix.

    rules:
    - response length setting: \(responseLength.systemPromptInstruction)
    - an explicit request in the user's current message for a shorter or more detailed answer overrides the response length setting.
    - if replying in english, use lowercase, casual, warm language. no emojis.
    - write for the ear, not the eye. short sentences. for normal answers, no lists, bullet points, markdown, or formatting — just natural speech.
    - do not proactively offer scripts, commands, automation, code, or ways to control the computer. those are outside your role.
    - if the user explicitly asks for a short piece of copyable text, include only that content in a fenced markdown block and keep the spoken explanation short. do not turn a normal question into a coding task.
    - you cannot click, type, press keys, run commands, create or save files, execute scripts, or operate apps. never claim that you did or can do any of those things. you can only explain and point to a visible location.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - when the user asks to extract, transcribe, or copy text visible in the current screen or video frame, copy all legible requested text faithfully into a fenced plain-text block. preserve its reading order and meaningful line breaks. speak only a short completion sentence and never read the extracted block aloud.
    - a screenshot represents only the current visible frame. never claim to have inspected earlier or later parts of a video.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - answer the current request completely, then stop. do not end by offering additional work, asking whether the user wants code, or suggesting unrelated next steps.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    - pointing is opt-in for each request. only return a [POINT_V2:...] tag when the current user message includes an internal clicky pointing requirement.
    - without that requirement, never emit any point tag and never claim that you pointed, showed, guided, or indicated a screen location.
    - when pointing is requested but the exact target is not clearly visible, return [POINT_V2:none] rather than guessing.
    """
    }

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
        - this machine-readable suffix is mandatory. inspect the current screenshot and end your entire response with exactly one V2 tag: [POINT_V2:x,y:label] or [POINT_V2:none]. never omit it and never use the legacy [POINT:...] format.
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
        stopAllSpeechAndCancelPreview()

        let shouldRequestPointing = PointingRequestPolicy.shouldRequestPointing(
            for: transcript,
            previousUserTranscript: conversationHistory.last?.userTranscript
        )
        let shouldExtractScreenText = ScreenTextExtractionPolicy.isTextExtractionRequest(transcript)
        let responseTaskIdentifier = UUID()
        currentResponseTaskIdentifier = responseTaskIdentifier
        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Small controls need more source pixels for reliable pointing,
                // while ordinary chat keeps the lighter screenshot payload.
                let requiresDetailedScreenshot = shouldRequestPointing || shouldExtractScreenText
                let screenshotLongEdgeInPixels = requiresDetailedScreenshot
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
                ttsSpeechErrorMessage = nil
                streamingSpeechSession.begin(
                    onPlaybackStarted: { [weak self] in
                        guard let self,
                              self.currentResponseTaskIdentifier == responseTaskIdentifier else { return }
                        self.voiceState = .responding
                    },
                    onFailure: { [weak self] error in
                        guard let self,
                              self.currentResponseTaskIdentifier == responseTaskIdentifier else { return }
                        self.ttsSpeechErrorMessage = error.localizedDescription
                        print("⚠️ Streaming TTS error: \(error)")
                    }
                )

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: Self.userPromptWithPointingContract(
                        transcript,
                        shouldRequestPointing: shouldRequestPointing
                    ),
                    temperature: requiresDetailedScreenshot ? 0.1 : nil,
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
                matildaDebugLog("model response completed")

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
                        matildaDebugLog("pointing overlay shown")
                    }

                    let displayFrame = targetScreenCapture.displayFrame
                    let globalLocation = Self.globalScreenLocation(
                        fromNormalizedCoordinate: pointCoordinate,
                        displayFrame: displayFrame
                    )

                    detectedElementDisplayFrame = displayFrame
                    detectedElementScreenLocation = globalLocation
                    matildaDebugLog("pointing target accepted")
                } else {
                    matildaDebugLog("response completed without pointing target")
                }

                // Save the full display response for both the panel history and
                // future context. TTS may use a shorter version when code blocks
                // are present, but the user still needs the complete answer.
                appendConversationHistory(userTranscript: transcript, assistantResponse: displayText)

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")


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
                if !Task.isCancelled && (error as? URLError)?.code != .cancelled {
                    print("⚠️ Companion response error: \(error)")
                    voiceState = .responding
                    await systemSpeechFallbackController.speak(
                        CompanionResponseFailureMessage.spokenMessage(for: error)
                    )
                }
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

    /// If the companion is in transient mode (user toggled "Show 壮壮" off),
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

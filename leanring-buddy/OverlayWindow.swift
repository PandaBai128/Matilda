//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for the companion avatar.
//  One OverlayWindow is created per screen so the companion
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode: Equatable {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the Zhuangzhuang cursor companion.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// avatar when it is. Voice and navigation states animate the same approved
// identity image so facial proportions never drift between generated frames.
struct BlueCursorView: View {
    let screenFrame: CGRect
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        let cursorOffset = companionManager.companionAvatarSize.cursorOffset
        _cursorPosition = State(initialValue: CGPoint(x: localX + cursorOffset.x, y: localY + cursorOffset.y))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// A restrained head tilt that follows the direction of travel.
    @State private var buddyTravelTiltDegrees: Double = 0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy portrait during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0
    @State private var pointingTargetPosition: CGPoint?

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    private let navigationPointerPhrase = "汪，汪汪"

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            if buddyNavigationMode == .pointingAtTarget,
               let pointingTargetPosition {
                ZhuangzhuangTargetMarkerView()
                    .position(pointingTargetPosition)
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(
                        x: cursorPosition.x + 8 + (navigationBubbleSize.width / 2),
                        y: cursorPosition.y + (companionManager.companionAvatarSize.diameter / 2) + 12
                    )
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // The same approved portrait remains mounted for every state. SwiftUI
            // supplies smooth motion, listening feedback, and thinking indicators
            // without asking image generation to redraw the dog's face per frame.
            ZhuangzhuangAvatarView(
                diameter: companionManager.companionAvatarSize.diameter,
                voiceState: companionManager.voiceState,
                navigationMode: buddyNavigationMode,
                audioPowerLevel: companionManager.currentAudioPowerLevel,
                travelTiltDegrees: buddyTravelTiltDegrees
            )
                .scaleEffect(buddyFlightScale)
                .opacity(buddyIsVisibleOnThisScreen ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            let cursorOffset = companionManager.companionAvatarSize.cursorOffset
            self.cursorPosition = CGPoint(
                x: swiftUIPosition.x + cursorOffset.x,
                y: swiftUIPosition.y + cursorOffset.y
            )

            startTrackingCursor()

            self.cursorOpacity = 1.0
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            clickyDebugLog("overlay point-change screen=\(screenFrame) newLocation=\(String(describing: newLocation)) displayFrame=\(String(describing: companionManager.detectedElementDisplayFrame))")
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                clickyDebugLog("overlay point-change ignored missing-target screen=\(screenFrame)")
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                clickyDebugLog("overlay point-change ignored different-screen screen=\(screenFrame) displayFrame=\(displayFrame)")
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
    }

    /// Whether the buddy avatar should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // During forward flight or pointing, the buddy is NOT interrupted by
            // mouse movement — it completes its full animation and return flight.
            // Only during the RETURN flight do we allow cursor movement to cancel
            // (so the buddy snaps to following if the user moves while it's flying back).
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            // During forward navigation or pointing, just skip cursor tracking
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // Normal cursor following
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let cursorOffset = companionManager.companionAvatarSize.cursorOffset
            let buddyX = swiftUIPosition.x + cursorOffset.x
            let buddyY = swiftUIPosition.y + cursorOffset.y
            self.cursorPosition = CGPoint(x: buddyX, y: buddyY)
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Keep the exact model coordinate visible as a pulse marker, while the
        // larger portrait stops beside it instead of covering the control.
        let markerPosition = CGPoint(
            x: max(10, min(targetInSwiftUI.x, screenFrame.width - 10)),
            y: max(10, min(targetInSwiftUI.y, screenFrame.height - 10))
        )
        pointingTargetPosition = markerPosition

        let avatarDiameter = companionManager.companionAvatarSize.diameter
        let avatarDestination = CGPoint(
            x: markerPosition.x + max(18, avatarDiameter * 0.82),
            y: markerPosition.y - max(16, avatarDiameter * 0.68)
        )
        let clampedTarget = CGPoint(
            x: max(avatarDiameter / 2, min(avatarDestination.x, screenFrame.width - avatarDiameter / 2)),
            y: max(avatarDiameter / 2, min(avatarDestination.y, screenFrame.height - avatarDiameter / 2))
        )
        clickyDebugLog("overlay navigate start screenLocation=\(screenLocation) target=\(targetInSwiftUI) clamped=\(clampedTarget) screen=\(screenFrame)")

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The portrait tilts toward its direction
    /// of travel each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Tilt toward the direction of travel without rotating the face
            // upside down along steep arcs.
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            let travelAngle = atan2(tangentY, tangentX) * (180.0 / .pi)
            self.buddyTravelTiltDegrees = min(max(travelAngle * 0.12, -10), 10)

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        buddyTravelTiltDegrees = -5

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        streamNavigationBubbleCharacter(phrase: navigationPointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorOffset = companionManager.companionAvatarSize.cursorOffset
        let cursorWithTrackingOffset = CGPoint(
            x: cursorInSwiftUI.x + cursorOffset.x,
            y: cursorInSwiftUI.y + cursorOffset.y
        )

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        pointingTargetPosition = nil
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        buddyTravelTiltDegrees = 0
        buddyFlightScale = 1.0
        pointingTargetPosition = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        companionManager.clearDetectedElementLocation()
    }

}

// MARK: - Zhuangzhuang Avatar

private struct ZhuangzhuangAvatarView: View {
    let diameter: CGFloat
    let voiceState: CompanionVoiceState
    let navigationMode: BuddyNavigationMode
    let audioPowerLevel: CGFloat
    let travelTiltDegrees: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timelineContext in
            let animationTime = timelineContext.date.timeIntervalSinceReferenceDate
            let portraitRotation = rotationDegrees(at: animationTime)
            let portraitScale = scale(at: animationTime)
            let shouldBlink = isBlinking(at: animationTime)

            ZStack {
                Circle()
                    .fill(Color(red: 0.79, green: 0.79, blue: 0.79))

                Image("ZhuangzhuangHead")
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())

                Circle()
                    .stroke(DS.Colors.overlayCursorBlue.opacity(0.78), lineWidth: max(1, diameter * 0.045))

                if shouldBlink {
                    HStack(spacing: diameter * 0.07) {
                        ForEach(0..<2, id: \.self) { _ in
                            Capsule()
                                .fill(Color(red: 0.42, green: 0.20, blue: 0.08))
                                .frame(width: diameter * 0.16, height: max(1, diameter * 0.04))
                        }
                    }
                    .offset(y: -diameter * 0.045)
                }

                if voiceState == .listening {
                    BlueCursorWaveformView(audioPowerLevel: audioPowerLevel)
                        .offset(x: diameter * 0.72, y: diameter * 0.08)
                }

                if voiceState == .processing {
                    ZhuangzhuangThinkingDotsView(
                        diameter: diameter,
                        animationTime: animationTime
                    )
                }
            }
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(portraitRotation))
            .scaleEffect(portraitScale)
            .shadow(
                color: DS.Colors.overlayCursorBlue.opacity(navigationMode == .navigatingToTarget ? 0.72 : 0.42),
                radius: navigationMode == .navigatingToTarget ? diameter * 0.34 : diameter * 0.20,
                x: 0,
                y: 0
            )
        }
    }

    private func rotationDegrees(at animationTime: TimeInterval) -> Double {
        switch navigationMode {
        case .navigatingToTarget:
            return travelTiltDegrees
        case .pointingAtTarget:
            return -5 + sin(animationTime * 2.8) * 1.2
        case .followingCursor:
            break
        }

        switch voiceState {
        case .idle:
            return sin(animationTime * 1.2) * 1.2
        case .listening:
            return -7 + sin(animationTime * 2.2) * 1.4
        case .processing:
            return 4 + sin(animationTime * 1.9) * 2.0
        case .responding:
            return sin(animationTime * 1.8) * 0.9
        }
    }

    private func scale(at animationTime: TimeInterval) -> CGFloat {
        if voiceState == .listening {
            let normalizedAudioPower = min(max(audioPowerLevel * 1.7, 0), 1)
            return 1 + normalizedAudioPower * 0.045
        }
        return 1 + CGFloat(sin(animationTime * 1.7)) * 0.012
    }

    private func isBlinking(at animationTime: TimeInterval) -> Bool {
        guard navigationMode == .followingCursor,
              voiceState == .idle || voiceState == .responding else {
            return false
        }
        return animationTime.truncatingRemainder(dividingBy: 5.8) < 0.14
    }
}

private struct ZhuangzhuangThinkingDotsView: View {
    let diameter: CGFloat
    let animationTime: TimeInterval

    var body: some View {
        HStack(alignment: .bottom, spacing: max(1, diameter * 0.045)) {
            ForEach(0..<3, id: \.self) { dotIndex in
                let wave = CGFloat((sin(animationTime * 4.2 + Double(dotIndex) * 0.9) + 1) / 2)
                Circle()
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(
                        width: diameter * (0.10 + wave * 0.025),
                        height: diameter * (0.10 + wave * 0.025)
                    )
                    .offset(y: -CGFloat(wave) * diameter * 0.10)
            }
        }
        .offset(x: diameter * 0.48, y: -diameter * 0.53)
        .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.65), radius: diameter * 0.12)
    }
}

private struct ZhuangzhuangTargetMarkerView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            let phase = CGFloat((sin(timelineContext.date.timeIntervalSinceReferenceDate * 4.0) + 1) / 2)
            ZStack {
                Circle()
                    .stroke(DS.Colors.overlayCursorBlue.opacity(Double(0.78 - phase * 0.38)), lineWidth: 1.5)
                    .frame(width: 15, height: 15)
                    .scaleEffect(0.72 + phase * 0.48)

                Circle()
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(width: 4, height: 4)
            }
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.72), radius: 5)
        }
    }
}

// MARK: - Listening Waveform

/// A small waveform that reacts beside Zhuangzhuang while the user speaks.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}

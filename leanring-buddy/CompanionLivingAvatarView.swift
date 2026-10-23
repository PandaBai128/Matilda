import SwiftUI

/// A cached atlas is cropped by the renderer, not by a network/image service.
/// All six/four poses share one texture and the idle state has no frame clock.
struct CompanionAtlasFrame: View {
    let name: String
    let columns: Int
    let rows: Int
    let index: Int
    let size: CGFloat

    var body: some View {
        Image(name)
            .resizable()
            .interpolation(.high)
            .frame(width: size * CGFloat(columns), height: size * CGFloat(rows))
            .offset(x: -size * CGFloat(index % columns), y: -size * CGFloat(index / columns))
            .frame(width: size, height: size, alignment: .topLeading)
            .clipped()
            .transaction { $0.animation = nil }
            .accessibilityHidden(true)
    }
}

struct ZhuangzhuangAvatarView: View {
    let diameter: CGFloat
    let voiceState: CompanionVoiceState
    let navigationMode: BuddyNavigationMode
    let audioPowerLevel: CGFloat
    let travelTiltDegrees: Double
    let glowColor: Color
    let glowIntensity: Double
    let isGlowEnabled: Bool
    var navigationAnimationTime: TimeInterval? = nil
    var blinkCycleDurationSeconds: Double = CompanionBlinkSchedule.intervalSeconds
    var visualStyle: CompanionVisualStyle = .portrait
    var gaze: CGPoint = .zero
    var movementEnergy: CGFloat = 0
    var movementDirection: CGPoint = .zero
    var isCursorMoving: Bool = false
    var operationFeedback: CompanionOperationFeedback? = nil
    var previewHeadFrame: Int? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blinking = false
    @State private var resting = false
    @State private var feedbackTilt: Double = 0
    @State private var feedbackDrop: CGFloat = 0
    @State private var nodding = false
    @State private var blinkTask: Task<Void, Never>?
    @State private var feedbackTask: Task<Void, Never>?
    @State private var restingTask: Task<Void, Never>?

    private var holdingAttention: Bool {
        CompanionAppearanceMotion.shouldHoldPosition(voiceState: voiceState)
    }
    private var moving: Bool {
        !holdingAttention && navigationMode == .followingCursor && isCursorMoving && !reduceMotion
    }
    private var footprint: CGFloat { diameter * visualStyle.footprintScale }

    var body: some View {
        Group {
            if let navigationAnimationTime, !reduceMotion {
                frame(at: navigationAnimationTime)
            } else if !reduceMotion, let framesPerSecond = CompanionAnimationCadencePolicy.framesPerSecond(voiceState: voiceState, navigationMode: navigationMode) {
                TimelineView(.periodic(from: .now, by: 1.0 / framesPerSecond)) { context in
                    frame(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                // Cursor tracker updates are already event-driven. No extra walking timer.
                frame(at: Date().timeIntervalSinceReferenceDate)
            }
        }
        .onAppear {
            restartBlinkTask()
            restartRestingTask()
            animateFeedback()
        }
        .onDisappear {
            blinkTask?.cancel()
            feedbackTask?.cancel()
            restingTask?.cancel()
        }
        .onChange(of: voiceState) { _, _ in restartBlinkTask(); restartRestingTask() }
        .onChange(of: navigationMode) { _, _ in restartBlinkTask(); restartRestingTask() }
        .onChange(of: isCursorMoving) { _, _ in restartRestingTask() }
        .onChange(of: blinkCycleDurationSeconds) { _, _ in restartBlinkTask() }
        .onChange(of: previewHeadFrame) { _, _ in restartBlinkTask() }
        .onChange(of: reduceMotion) { _, _ in restartBlinkTask(); restartRestingTask() }
        .onChange(of: operationFeedback?.id) { _, _ in animateFeedback() }
    }

    private func frame(at time: TimeInterval) -> some View {
        let headFrame = previewHeadFrame.map { min(max($0, 0), 5) } ?? CompanionAppearanceMotion.headFrame(
            gaze: gaze, listening: voiceState == .listening,
            blinking: blinking, nodding: nodding
        )
        let bodyFrame = CompanionAppearanceMotion.bodyFrame(
            moving: moving, resting: resting && voiceState == .idle && navigationMode == .followingCursor,
            time: time
        )
        let travel = navigationMode == .navigatingToTarget ? travelTiltDegrees : 0
        let followingTilt = holdingAttention ? 0 : Double(movementDirection.x * movementEnergy) * 4
        let attentiveTilt: Double = voiceState == .processing ? 4 : 0
        return ZStack {
            Group {
                if visualStyle == .portrait {
                    CompanionAtlasFrame(name: "ZhuangzhuangHeadAtlas", columns: 3, rows: 2, index: headFrame, size: diameter * 1.16)
                        .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(gaze.y) * -5), axis: (x: 1, y: 0, z: 0))
                } else {
                    CompanionAtlasFrame(name: "ZhuangzhuangBodyAtlas", columns: 2, rows: 2, index: bodyFrame, size: footprint)
                        .offset(x: CompanionAppearanceMotion.bodyRegistration(for: bodyFrame).x * footprint,
                                y: CompanionAppearanceMotion.bodyRegistration(for: bodyFrame).y * footprint)
                        .scaleEffect(x: moving && movementDirection.x < -0.15 ? -1 : 1, y: 1)
                        .transaction { $0.animation = nil }
                }
            }
            .rotationEffect(.degrees(reduceMotion ? 0 : travel + followingTilt + attentiveTilt + feedbackTilt))
            .offset(y: reduceMotion ? 0 : feedbackDrop)
            // A small damped settling movement; never change the target marker coordinate.
            .animation(navigationMode == .navigatingToTarget || reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.72), value: followingTilt)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: headFrame)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: attentiveTilt)

            if voiceState == .listening {
                BlueCursorWaveformView(audioPowerLevel: audioPowerLevel, accentColor: glowColor, animationTime: reduceMotion ? 0 : time)
                    .offset(x: footprint * 0.65, y: diameter * 0.08)
            }
            if voiceState == .processing {
                ZhuangzhuangThinkingDotsView(diameter: diameter, animationTime: reduceMotion ? 0 : time, accentColor: glowColor)
                    .offset(y: (diameter - footprint) * 0.35)
            }
        }
        .frame(width: footprint, height: footprint)
        .shadow(color: glowColor.opacity(isGlowEnabled ? min(glowIntensity * 0.72, 1) : 0), radius: diameter * 0.22)
    }

    private func restartBlinkTask() {
        blinkTask?.cancel()
        blinking = false
        guard voiceState == .idle || voiceState == .responding,
              navigationMode == .followingCursor, !reduceMotion, previewHeadFrame == nil else { return }
        blinkTask = Task { @MainActor in
            var schedule = CompanionBlinkSchedule(now: Date().timeIntervalSinceReferenceDate, interval: blinkCycleDurationSeconds)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(schedule.nextBlinkTime - Date().timeIntervalSinceReferenceDate, 0.01)))
                guard !Task.isCancelled else { return }
                guard schedule.consumeIfDue(now: Date().timeIntervalSinceReferenceDate) else { continue }
                blinking = true
                try? await Task.sleep(for: .seconds(CompanionBlinkSchedule.closedDurationSeconds))
                guard !Task.isCancelled else { return }
                blinking = false
            }
        }
    }

    private func restartRestingTask() {
        restingTask?.cancel()
        resting = false
        guard voiceState == .idle, navigationMode == .followingCursor,
              !isCursorMoving, !reduceMotion else { return }
        restingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5.8))
            guard !Task.isCancelled else { return }
            resting = true
        }
    }

    private func animateFeedback() {
        feedbackTask?.cancel()
        feedbackTilt = 0
        feedbackDrop = 0
        nodding = false
        guard let feedback = operationFeedback, !reduceMotion,
              Date().timeIntervalSince(feedback.createdAt) < 1.2 else { return }
        feedbackTask = Task { @MainActor in
            switch feedback.kind {
            case .performed:
                withAnimation(.easeOut(duration: 0.16)) {
                    feedbackDrop = diameter * 0.06
                    nodding = true
                }
            case .uncertain:
                withAnimation(.easeOut(duration: 0.22)) { feedbackTilt = -8 }
            case .cancelled:
                return
            }
            try? await Task.sleep(for: .milliseconds(feedback.kind == .performed ? 220 : 600))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.24)) {
                feedbackTilt = 0
                feedbackDrop = 0
                nodding = false
            }
        }
    }
}

struct CompanionInputPulseView: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    var body: some View {
        Circle().stroke(color, lineWidth: 1.8)
            .frame(width: 16, height: 16)
            .scaleEffect(expanded && !reduceMotion ? 1.7 : 1)
            .opacity(expanded ? 0 : 0.9)
            .onAppear { withAnimation(.easeOut(duration: 0.55)) { expanded = true } }
    }
}

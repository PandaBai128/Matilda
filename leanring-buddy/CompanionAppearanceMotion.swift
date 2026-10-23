import CoreGraphics
import Foundation

enum CompanionVisualStyle: String, CaseIterable {
    case portrait
    case petiteBody

    static let preferenceKey = "zhuangzhuangVisualStyle"
    var displayName: String { self == .portrait ? "头像" : "小身体" }
    var footprintScale: CGFloat { self == .portrait ? 1 : 1.65 }
    static func load(from defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .portrait
    }
}

enum CompanionPointingLabelMode: String, CaseIterable {
    case bark, targetName, custom, hidden

    static let preferenceKey = "zhuangzhuangPointingLabelMode"
    static let customTextKey = "zhuangzhuangCustomPointingText"
    var displayName: String {
        switch self {
        case .bark: return "汪，汪汪"
        case .targetName: return "目标名称"
        case .custom: return "自定义"
        case .hidden: return "不显示"
        }
    }
    static func load(from defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .bark
    }
    static func normalizedText(_ text: String) -> String {
        String(text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
    }
    func text(target: String?, custom: String) -> String {
        switch self {
        case .bark: return "汪，汪汪"
        case .targetName: return Self.normalizedText(target ?? "")
        case .custom: return Self.normalizedText(custom)
        case .hidden: return ""
        }
    }
}

/// Blink deadlines are independent of cursor movement; moving must not starve them.
struct CompanionBlinkSchedule {
    static let intervalSeconds: TimeInterval = 8.5
    static let firstDelaySeconds: TimeInterval = 2.4
    static let closedDurationSeconds: TimeInterval = 0.22
    private(set) var nextBlinkTime: TimeInterval
    let interval: TimeInterval

    init(now: TimeInterval, interval: TimeInterval = Self.intervalSeconds) {
        self.interval = max(interval, 0.5)
        nextBlinkTime = now + min(Self.firstDelaySeconds, self.interval)
    }

    mutating func consumeIfDue(now: TimeInterval) -> Bool {
        guard now >= nextBlinkTime else { return false }
        nextBlinkTime = now + interval
        return true
    }
}

/// Local presentation only: none of these poses can dispatch input or call a model.
enum CompanionAppearanceMotion {
    static func bubbleCenter(proposed: CGPoint, size: CGSize, container: CGSize) -> CGPoint {
        let halfWidth = min(size.width / 2 + 8, container.width / 2)
        let halfHeight = min(size.height / 2 + 8, container.height / 2)
        return CGPoint(x: min(max(proposed.x, halfWidth), container.width - halfWidth),
                       y: min(max(proposed.y, halfHeight), container.height - halfHeight))
    }

    static func gaze(from avatar: CGPoint, toward target: CGPoint) -> CGPoint {
        let dx = target.x - avatar.x
        let dy = target.y - avatar.y
        let distance = hypot(dx, dy)
        guard distance > 0.1 else { return .zero }
        let strength = min(distance / 65, 1)
        return CGPoint(x: dx / distance * strength, y: dy / distance * strength)
    }

    static func headFrame(gaze: CGPoint, listening: Bool, blinking: Bool, nodding: Bool) -> Int {
        if blinking { return 4 }
        if nodding { return 5 }
        if listening { return 3 }
        if gaze.x < -0.30 { return 1 }
        if gaze.x > 0.30 { return 2 }
        return 0
    }

    static func bodyFrame(moving: Bool, resting: Bool, time: TimeInterval) -> Int {
        if moving { return 1 + Int(max(0, time) * 4).quotientAndRemainder(dividingBy: 2).remainder }
        return resting ? 3 : 0
    }

    /// Art-registration offsets for the 1254px body atlas: keep the paws on
    /// one baseline when changing pose. These never affect screen coordinates.
    static func bodyRegistration(for frame: Int) -> CGPoint {
        switch frame {
        case 0: return CGPoint(x: -0.057, y: -0.062)
        case 1: return CGPoint(x: -0.002, y: -0.067)
        case 2: return CGPoint(x: -0.040, y: -0.008)
        default: return CGPoint(x: -0.048, y: 0.002)
        }
    }

    static func shouldHoldPosition(voiceState: CompanionVoiceState) -> Bool {
        voiceState == .listening || voiceState == .processing
    }
}

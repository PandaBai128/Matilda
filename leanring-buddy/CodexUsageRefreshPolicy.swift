import Foundation

enum CodexUsageRefreshFrequency: String, CaseIterable, Identifiable {
    case adaptive
    case everyTwoMinutes
    case everyFiveMinutes
    case everyFifteenMinutes
    case everyThirtyMinutes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .adaptive:
            return "Adaptive"
        case .everyTwoMinutes:
            return "Every 2 minutes"
        case .everyFiveMinutes:
            return "Every 5 minutes"
        case .everyFifteenMinutes:
            return "Every 15 minutes"
        case .everyThirtyMinutes:
            return "Every 30 minutes"
        }
    }

    var detailText: String {
        switch self {
        case .adaptive:
            return "2 minutes after interaction, then 5–30 minutes while idle."
        case .everyTwoMinutes:
            return "Always keep usage as fresh as the current behavior."
        case .everyFiveMinutes:
            return "A balanced fixed interval for regular Codex use."
        case .everyFifteenMinutes:
            return "Reduce background checks when usage changes slowly."
        case .everyThirtyMinutes:
            return "Use the fewest background checks while keeping automatic updates."
        }
    }

    fileprivate var fixedDelaySeconds: TimeInterval? {
        switch self {
        case .adaptive:
            return nil
        case .everyTwoMinutes:
            return 2 * 60
        case .everyFiveMinutes:
            return 5 * 60
        case .everyFifteenMinutes:
            return 15 * 60
        case .everyThirtyMinutes:
            return 30 * 60
        }
    }
}

enum CodexUsageRefreshPolicy {
    static func delay(
        for refreshFrequency: CodexUsageRefreshFrequency,
        currentDate: Date,
        lastUserInteractionDate: Date?,
        isSystemConstrained: Bool
    ) -> TimeInterval {
        if let fixedDelaySeconds = refreshFrequency.fixedDelaySeconds {
            return fixedDelaySeconds
        }

        if isSystemConstrained {
            return 30 * 60
        }

        guard let lastUserInteractionDate else {
            return 30 * 60
        }

        let elapsedSeconds = max(
            0,
            currentDate.timeIntervalSince(lastUserInteractionDate)
        )
        if elapsedSeconds <= 5 * 60 {
            return 2 * 60
        }
        if elapsedSeconds <= 60 * 60 {
            return 5 * 60
        }
        if elapsedSeconds <= 4 * 60 * 60 {
            return 15 * 60
        }
        return 30 * 60
    }
}

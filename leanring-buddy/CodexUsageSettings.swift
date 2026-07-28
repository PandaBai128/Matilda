import Combine
import Foundation

@MainActor
final class CodexUsageSettings: ObservableObject {
    @Published var isMenuBarUsageVisible: Bool {
        didSet { userDefaults.set(isMenuBarUsageVisible, forKey: Keys.isMenuBarUsageVisible) }
    }

    @Published var isWeeklyLimitVisible: Bool {
        didSet { userDefaults.set(isWeeklyLimitVisible, forKey: Keys.isWeeklyLimitVisible) }
    }

    @Published var isFiveHourLimitVisible: Bool {
        didSet { userDefaults.set(isFiveHourLimitVisible, forKey: Keys.isFiveHourLimitVisible) }
    }

    @Published var showsResetCountdownWhenExhausted: Bool {
        didSet {
            userDefaults.set(
                showsResetCountdownWhenExhausted,
                forKey: Keys.showsResetCountdownWhenExhausted
            )
        }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.isMenuBarUsageVisible = Self.boolValue(
            forKey: Keys.isMenuBarUsageVisible,
            defaultValue: true,
            userDefaults: userDefaults
        )
        self.isWeeklyLimitVisible = Self.boolValue(
            forKey: Keys.isWeeklyLimitVisible,
            defaultValue: true,
            userDefaults: userDefaults
        )
        self.isFiveHourLimitVisible = Self.boolValue(
            forKey: Keys.isFiveHourLimitVisible,
            defaultValue: true,
            userDefaults: userDefaults
        )
        self.showsResetCountdownWhenExhausted = Self.boolValue(
            forKey: Keys.showsResetCountdownWhenExhausted,
            defaultValue: true,
            userDefaults: userDefaults
        )
    }

    private static func boolValue(
        forKey key: String,
        defaultValue: Bool,
        userDefaults: UserDefaults
    ) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return defaultValue }
        return userDefaults.bool(forKey: key)
    }

    private enum Keys {
        static let isMenuBarUsageVisible = "codexUsageMenuBarVisible"
        static let isWeeklyLimitVisible = "codexUsageWeeklyLimitVisible"
        static let isFiveHourLimitVisible = "codexUsageFiveHourLimitVisible"
        static let showsResetCountdownWhenExhausted = "codexUsageResetCountdownWhenExhausted"
    }
}

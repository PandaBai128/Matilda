import Foundation

struct CodexQuotaWindow: Codable, Equatable, Sendable {
    let usedPercent: Int
    let remainingPercent: Int
    let resetsAt: Date
    let durationSeconds: Int
}

struct CodexUsageSnapshot: Codable, Equatable, Sendable {
    static let fiveHourDurationSeconds = 5 * 60 * 60
    static let weeklyDurationSeconds = 7 * 24 * 60 * 60

    let fiveHourLimit: CodexQuotaWindow?
    let weeklyLimit: CodexQuotaWindow?
    let refreshedAt: Date

    var availableLimits: [CodexQuotaWindow] {
        [fiveHourLimit, weeklyLimit].compactMap { $0 }
    }

    static func decode(responseData: Data, refreshedAt: Date) throws -> CodexUsageSnapshot {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: responseData)
        let windows = [
            response.rateLimit?.primaryWindow,
            response.rateLimit?.secondaryWindow,
        ].compactMap { $0 }

        return CodexUsageSnapshot(
            fiveHourLimit: quotaWindow(
                durationSeconds: fiveHourDurationSeconds,
                in: windows
            ),
            weeklyLimit: quotaWindow(
                durationSeconds: weeklyDurationSeconds,
                in: windows
            ),
            refreshedAt: refreshedAt
        )
    }

    private static func quotaWindow(
        durationSeconds: Int,
        in windows: [CodexUsageResponse.Window]
    ) -> CodexQuotaWindow? {
        guard let matchingWindow = windows.first(where: {
            $0.limitWindowSeconds == durationSeconds
        }) else {
            return nil
        }

        let normalizedUsedPercent = min(max(matchingWindow.usedPercent, 0), 100)
        return CodexQuotaWindow(
            usedPercent: normalizedUsedPercent,
            remainingPercent: 100 - normalizedUsedPercent,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(matchingWindow.resetAt)),
            durationSeconds: matchingWindow.limitWindowSeconds
        )
    }
}

private struct CodexUsageResponse: Decodable {
    let rateLimit: RateLimit?

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Int
        let resetAt: Int
        let limitWindowSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

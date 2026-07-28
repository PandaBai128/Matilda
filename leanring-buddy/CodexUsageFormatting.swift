import Foundation

enum CodexUsageFormatting {
    static func menuValue(
        for quotaWindow: CodexQuotaWindow,
        showsResetCountdownWhenExhausted: Bool,
        currentDate: Date = Date()
    ) -> String {
        guard quotaWindow.remainingPercent == 0,
              showsResetCountdownWhenExhausted,
              quotaWindow.resetsAt > currentDate
        else {
            return "\(quotaWindow.remainingPercent)%"
        }

        return "↻ \(compactDuration(until: quotaWindow.resetsAt, from: currentDate))"
    }

    static func resetDescription(
        for quotaWindow: CodexQuotaWindow,
        currentDate: Date = Date()
    ) -> String {
        guard quotaWindow.resetsAt > currentDate else { return "Reset pending" }
        return "Resets in \(compactDuration(until: quotaWindow.resetsAt, from: currentDate))"
    }

    static func refreshDescription(
        refreshedAt: Date,
        currentDate: Date = Date()
    ) -> String {
        let elapsedSeconds = max(0, Int(currentDate.timeIntervalSince(refreshedAt)))
        if elapsedSeconds < 60 {
            return "Updated just now"
        }

        let elapsedMinutes = elapsedSeconds / 60
        if elapsedMinutes < 60 {
            return "Updated \(elapsedMinutes)m ago"
        }

        let elapsedHours = elapsedMinutes / 60
        return "Updated \(elapsedHours)h ago"
    }

    private static func compactDuration(until endDate: Date, from startDate: Date) -> String {
        let totalMinutes = max(1, Int(ceil(endDate.timeIntervalSince(startDate) / 60)))
        let totalHours = totalMinutes / 60
        let remainingMinutes = totalMinutes % 60

        if totalHours >= 24 {
            let days = totalHours / 24
            let remainingHours = totalHours % 24
            return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
        }

        if totalHours > 0 {
            return remainingMinutes == 0
                ? "\(totalHours)h"
                : "\(totalHours)h \(remainingMinutes)m"
        }

        return "\(remainingMinutes)m"
    }
}

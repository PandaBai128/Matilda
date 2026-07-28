import Foundation
import Testing
@testable import Matilda

@MainActor
struct CodexUsageTests {
    @Test func weeklyOnlyResponseShowsWeeklyRemainingWithoutInventingFiveHourLimit() throws {
        let responseData = Data(
            """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 18,
                  "reset_at": 1785838062,
                  "limit_window_seconds": 604800
                }
              }
            }
            """.utf8
        )
        let refreshedAt = Date(timeIntervalSince1970: 1_785_000_000)

        let snapshot = try CodexUsageSnapshot.decode(
            responseData: responseData,
            refreshedAt: refreshedAt
        )

        #expect(snapshot.weeklyLimit?.remainingPercent == 82)
        #expect(snapshot.weeklyLimit?.resetsAt == Date(timeIntervalSince1970: 1_785_838_062))
        #expect(snapshot.fiveHourLimit == nil)
        #expect(snapshot.refreshedAt == refreshedAt)
    }

    @Test func fiveHourAndWeeklyWindowsAreIdentifiedByDurationNotResponseOrder() throws {
        let responseData = Data(
            """
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 27,
                  "reset_at": 1785838062,
                  "limit_window_seconds": 604800
                },
                "secondary_window": {
                  "used_percent": 61,
                  "reset_at": 1785250000,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.utf8
        )

        let snapshot = try CodexUsageSnapshot.decode(
            responseData: responseData,
            refreshedAt: Date(timeIntervalSince1970: 1_785_000_000)
        )

        #expect(snapshot.fiveHourLimit?.remainingPercent == 39)
        #expect(snapshot.weeklyLimit?.remainingPercent == 73)
    }

    @Test func refreshFailureKeepsTheLastSuccessfulUsageVisible() async {
        let expectedSnapshot = CodexUsageSnapshot(
            fiveHourLimit: nil,
            weeklyLimit: CodexQuotaWindow(
                usedPercent: 18,
                remainingPercent: 82,
                resetsAt: Date(timeIntervalSince1970: 1_785_838_062),
                durationSeconds: CodexUsageSnapshot.weeklyDurationSeconds
            ),
            refreshedAt: Date(timeIntervalSince1970: 1_785_000_000)
        )
        var refreshAttemptCount = 0
        let monitor = CodexUsageMonitor(fetchSnapshot: {
            refreshAttemptCount += 1
            if refreshAttemptCount == 1 {
                return expectedSnapshot
            }
            throw CodexUsageError.networkUnavailable
        })

        await monitor.refresh()
        await monitor.refresh()

        #expect(monitor.snapshot == expectedSnapshot)
        #expect(monitor.refreshState == .failed)
        #expect(monitor.errorMessage == "Couldn't refresh Codex usage")
    }

    @Test func exhaustedLimitUsesResetCountdownOnlyWhenEnabled() {
        let currentDate = Date(timeIntervalSince1970: 1_785_000_000)
        let exhaustedWindow = CodexQuotaWindow(
            usedPercent: 100,
            remainingPercent: 0,
            resetsAt: currentDate.addingTimeInterval((1 * 60 * 60) + (30 * 60)),
            durationSeconds: CodexUsageSnapshot.weeklyDurationSeconds
        )

        #expect(CodexUsageFormatting.menuValue(
            for: exhaustedWindow,
            showsResetCountdownWhenExhausted: true,
            currentDate: currentDate
        ) == "↻ 1h 30m")
        #expect(CodexUsageFormatting.menuValue(
            for: exhaustedWindow,
            showsResetCountdownWhenExhausted: false,
            currentDate: currentDate
        ) == "0%")
    }
}

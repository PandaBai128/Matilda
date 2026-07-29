import Foundation
import Testing
@testable import Matilda

@MainActor
struct CodexUsageTests {
    @Test func adaptiveRefreshSlowsDownAsUserInteractionGetsOlder() {
        let currentDate = Date(timeIntervalSince1970: 1_785_000_000)

        #expect(CodexUsageRefreshPolicy.delay(
            for: .adaptive,
            currentDate: currentDate,
            lastUserInteractionDate: currentDate.addingTimeInterval(-4 * 60),
            isSystemConstrained: false
        ) == 2 * 60)
        #expect(CodexUsageRefreshPolicy.delay(
            for: .adaptive,
            currentDate: currentDate,
            lastUserInteractionDate: currentDate.addingTimeInterval(-30 * 60),
            isSystemConstrained: false
        ) == 5 * 60)
        #expect(CodexUsageRefreshPolicy.delay(
            for: .adaptive,
            currentDate: currentDate,
            lastUserInteractionDate: currentDate.addingTimeInterval(-2 * 60 * 60),
            isSystemConstrained: false
        ) == 15 * 60)
        #expect(CodexUsageRefreshPolicy.delay(
            for: .adaptive,
            currentDate: currentDate,
            lastUserInteractionDate: nil,
            isSystemConstrained: false
        ) == 30 * 60)
    }

    @Test func fixedRefreshFrequencyIgnoresInteractionAgeAndSystemConstraints() {
        let currentDate = Date(timeIntervalSince1970: 1_785_000_000)

        #expect(CodexUsageRefreshPolicy.delay(
            for: .everyFiveMinutes,
            currentDate: currentDate,
            lastUserInteractionDate: nil,
            isSystemConstrained: true
        ) == 5 * 60)
        #expect(CodexUsageRefreshPolicy.delay(
            for: .everyThirtyMinutes,
            currentDate: currentDate,
            lastUserInteractionDate: currentDate,
            isSystemConstrained: false
        ) == 30 * 60)
    }

    @Test func refreshFrequencyDefaultsToAdaptiveAndPersistsFixedChoices() {
        let userDefaultsSuiteName = "CodexUsageTests.refreshFrequency"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)!
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)

        let initialSettings = CodexUsageSettings(userDefaults: userDefaults)
        #expect(initialSettings.refreshFrequency == .adaptive)

        initialSettings.refreshFrequency = .everyFifteenMinutes
        let reloadedSettings = CodexUsageSettings(userDefaults: userDefaults)
        #expect(reloadedSettings.refreshFrequency == .everyFifteenMinutes)

        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }

    @Test func monitorUsesLatestInteractionAndSelectedRefreshFrequency() {
        let currentDate = Date(timeIntervalSince1970: 1_785_000_000)
        let userDefaultsSuiteName = "CodexUsageTests.monitorRefreshPolicy"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)!
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        let usageSettings = CodexUsageSettings(userDefaults: userDefaults)
        let monitor = CodexUsageMonitor(
            fetchSnapshot: { throw CodexUsageError.networkUnavailable },
            usageSettings: usageSettings
        )

        monitor.noteUserInteraction(at: currentDate.addingTimeInterval(-4 * 60))
        #expect(monitor.nextRefreshDelay(
            at: currentDate,
            isSystemConstrained: false
        ) == 2 * 60)

        usageSettings.refreshFrequency = .everyFifteenMinutes
        #expect(monitor.nextRefreshDelay(
            at: currentDate,
            isSystemConstrained: false
        ) == 15 * 60)

        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }

    @Test func cancelledRefreshDoesNotReplaceTheLastSuccessfulStateWithAnError() async {
        let expectedSnapshot = CodexUsageSnapshot(
            fiveHourLimit: nil,
            weeklyLimit: CodexQuotaWindow(
                usedPercent: 4,
                remainingPercent: 96,
                resetsAt: Date(timeIntervalSince1970: 1_785_838_062),
                durationSeconds: CodexUsageSnapshot.weeklyDurationSeconds
            ),
            refreshedAt: Date(timeIntervalSince1970: 1_785_000_000)
        )
        let monitor = CodexUsageMonitor(
            fetchSnapshot: { throw CancellationError() },
            initialSnapshot: expectedSnapshot
        )

        await monitor.refresh()

        #expect(monitor.snapshot == expectedSnapshot)
        #expect(monitor.refreshState == .loaded)
        #expect(monitor.errorMessage == nil)
    }

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

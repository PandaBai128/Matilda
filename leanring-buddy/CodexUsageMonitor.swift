import AppKit
import Combine
import Foundation

enum CodexUsageError: Error, Equatable {
    case credentialsNotFound
    case credentialsInvalid
    case unauthorized
    case invalidResponse
    case networkUnavailable
    case serverError(Int)
}

enum CodexUsageRefreshState: Equatable {
    case idle
    case refreshing
    case loaded
    case failed
}

@MainActor
final class CodexUsageMonitor: ObservableObject {
    typealias FetchSnapshot = () async throws -> CodexUsageSnapshot
    typealias SaveSnapshot = (CodexUsageSnapshot) -> Void

    static let staleIntervalSeconds: TimeInterval = 10 * 60

    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var refreshState: CodexUsageRefreshState = .idle
    @Published private(set) var errorMessage: String?

    private let fetchSnapshot: FetchSnapshot
    private let saveSnapshot: SaveSnapshot
    private let usageSettings: CodexUsageSettings
    private var refreshScheduleTask: Task<Void, Never>?
    private var inFlightRefreshTask: Task<Void, Never>?
    private var inFlightRefreshIdentifier: UUID?
    private var snapshotExpirationTask: Task<Void, Never>?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var refreshFrequencySubscription: AnyCancellable?
    private var lastUserInteractionDate: Date?
    private var isStarted = false

    init(
        fetchSnapshot: @escaping FetchSnapshot,
        usageSettings: CodexUsageSettings,
        initialSnapshot: CodexUsageSnapshot? = nil,
        saveSnapshot: @escaping SaveSnapshot = { _ in }
    ) {
        self.fetchSnapshot = fetchSnapshot
        self.snapshot = initialSnapshot
        self.saveSnapshot = saveSnapshot
        self.usageSettings = usageSettings
    }

    convenience init(
        fetchSnapshot: @escaping FetchSnapshot,
        initialSnapshot: CodexUsageSnapshot? = nil,
        saveSnapshot: @escaping SaveSnapshot = { _ in }
    ) {
        self.init(
            fetchSnapshot: fetchSnapshot,
            usageSettings: CodexUsageSettings(),
            initialSnapshot: initialSnapshot,
            saveSnapshot: saveSnapshot
        )
    }

    convenience init(usageSettings: CodexUsageSettings) {
        let snapshotStore = CodexUsageSnapshotStore()
        let client = CodexUsageClient()
        self.init(
            fetchSnapshot: {
                try await client.fetchSnapshot()
            },
            usageSettings: usageSettings,
            initialSnapshot: snapshotStore.loadSnapshot(),
            saveSnapshot: { snapshot in
                snapshotStore.saveSnapshot(snapshot)
            }
        )
    }

    deinit {
        refreshScheduleTask?.cancel()
        inFlightRefreshTask?.cancel()
        snapshotExpirationTask?.cancel()
        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        refreshFrequencySubscription = usageSettings.$refreshFrequency
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.restartRefreshSchedule(refreshesImmediately: false)
                }
            }

        removeExpiredQuotaWindows()
        scheduleSnapshotExpiration()
        restartRefreshSchedule(refreshesImmediately: true)

        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.isStarted == true else { return }
                await self?.refresh()
                self?.restartRefreshSchedule(refreshesImmediately: false)
            }
        }
    }

    func stop() {
        isStarted = false
        refreshScheduleTask?.cancel()
        refreshScheduleTask = nil
        inFlightRefreshTask?.cancel()
        inFlightRefreshTask = nil
        inFlightRefreshIdentifier = nil
        snapshotExpirationTask?.cancel()
        snapshotExpirationTask = nil
        refreshFrequencySubscription?.cancel()
        refreshFrequencySubscription = nil

        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
            self.workspaceWakeObserver = nil
        }
    }

    func refresh() async {
        if let inFlightRefreshTask {
            await inFlightRefreshTask.value
            return
        }

        let refreshIdentifier = UUID()
        let refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        inFlightRefreshIdentifier = refreshIdentifier
        inFlightRefreshTask = refreshTask
        await refreshTask.value

        if inFlightRefreshIdentifier == refreshIdentifier {
            inFlightRefreshTask = nil
            inFlightRefreshIdentifier = nil
        }
    }

    private func performRefresh() async {
        refreshState = .refreshing
        errorMessage = nil

        do {
            let refreshedSnapshot = try await fetchSnapshot()
            try Task.checkCancellation()
            snapshot = refreshedSnapshot
            saveSnapshot(refreshedSnapshot)
            scheduleSnapshotExpiration()
            refreshState = .loaded
        } catch is CancellationError {
            removeExpiredQuotaWindows()
            refreshState = snapshot == nil ? .idle : .loaded
        } catch {
            removeExpiredQuotaWindows()
            refreshState = .failed
            errorMessage = Self.errorMessage(for: error)
        }
    }

    func isSnapshotStale(at currentDate: Date = Date()) -> Bool {
        guard let snapshot else { return true }
        return currentDate.timeIntervalSince(snapshot.refreshedAt) >= Self.staleIntervalSeconds
    }

    func noteUserInteraction(at interactionDate: Date = Date()) {
        lastUserInteractionDate = interactionDate
        if isStarted, usageSettings.refreshFrequency == .adaptive {
            restartRefreshSchedule(refreshesImmediately: false)
        }
    }

    func nextRefreshDelay(
        at currentDate: Date = Date(),
        isSystemConstrained: Bool? = nil
    ) -> TimeInterval {
        CodexUsageRefreshPolicy.delay(
            for: usageSettings.refreshFrequency,
            currentDate: currentDate,
            lastUserInteractionDate: lastUserInteractionDate,
            isSystemConstrained: isSystemConstrained ?? Self.isSystemConstrained
        )
    }

    func removeExpiredQuotaWindows(at currentDate: Date = Date()) {
        guard let snapshot else { return }

        let activeFiveHourLimit = snapshot.fiveHourLimit.flatMap {
            $0.resetsAt > currentDate ? $0 : nil
        }
        let activeWeeklyLimit = snapshot.weeklyLimit.flatMap {
            $0.resetsAt > currentDate ? $0 : nil
        }
        guard activeFiveHourLimit != snapshot.fiveHourLimit
                || activeWeeklyLimit != snapshot.weeklyLimit
        else {
            return
        }

        if activeFiveHourLimit == nil, activeWeeklyLimit == nil {
            self.snapshot = nil
        } else {
            self.snapshot = CodexUsageSnapshot(
                fiveHourLimit: activeFiveHourLimit,
                weeklyLimit: activeWeeklyLimit,
                refreshedAt: snapshot.refreshedAt
            )
        }
        scheduleSnapshotExpiration()
    }

    private func restartRefreshSchedule(refreshesImmediately: Bool) {
        guard isStarted else { return }
        refreshScheduleTask?.cancel()
        refreshScheduleTask = Task { [weak self] in
            if refreshesImmediately {
                await self?.refresh()
            }

            while !Task.isCancelled {
                guard let refreshDelaySeconds = self?.nextRefreshDelay() else { return }
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(refreshDelaySeconds * 1_000_000_000)
                    )
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func scheduleSnapshotExpiration() {
        snapshotExpirationTask?.cancel()
        snapshotExpirationTask = nil

        guard isStarted,
              let nextExpirationDate = snapshot?.availableLimits.map(\.resetsAt).min()
        else {
            return
        }

        snapshotExpirationTask = Task { [weak self] in
            let delaySeconds = max(0, nextExpirationDate.timeIntervalSinceNow)
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            self?.removeExpiredQuotaWindows()
        }
    }

    private static var isSystemConstrained: Bool {
        let processInfo = ProcessInfo.processInfo
        if processInfo.isLowPowerModeEnabled {
            return true
        }
        switch processInfo.thermalState {
        case .serious, .critical:
            return true
        default:
            return false
        }
    }

    private static func errorMessage(for error: Error) -> String {
        switch error as? CodexUsageError {
        case .credentialsNotFound, .credentialsInvalid:
            return "Sign in to Codex to see usage"
        case .unauthorized:
            return "Open Codex to refresh your sign-in"
        default:
            return "Couldn't refresh Codex usage"
        }
    }
}

private struct CodexUsageSnapshotStore {
    private let userDefaults: UserDefaults
    private let snapshotKey = "codexUsageLastSuccessfulSnapshot"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadSnapshot(currentDate: Date = Date()) -> CodexUsageSnapshot? {
        guard let snapshotData = userDefaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(CodexUsageSnapshot.self, from: snapshotData),
              currentDate.timeIntervalSince(snapshot.refreshedAt) < 24 * 60 * 60
        else {
            return nil
        }

        let activeFiveHourLimit = snapshot.fiveHourLimit.flatMap {
            $0.resetsAt > currentDate ? $0 : nil
        }
        let activeWeeklyLimit = snapshot.weeklyLimit.flatMap {
            $0.resetsAt > currentDate ? $0 : nil
        }
        guard activeFiveHourLimit != nil || activeWeeklyLimit != nil else { return nil }

        return CodexUsageSnapshot(
            fiveHourLimit: activeFiveHourLimit,
            weeklyLimit: activeWeeklyLimit,
            refreshedAt: snapshot.refreshedAt
        )
    }

    func saveSnapshot(_ snapshot: CodexUsageSnapshot) {
        guard let snapshotData = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(snapshotData, forKey: snapshotKey)
    }
}

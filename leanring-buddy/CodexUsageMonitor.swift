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
    private var periodicRefreshTask: Task<Void, Never>?
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
        periodicRefreshTask?.cancel()
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
                    self?.restartPeriodicRefreshLoop(refreshesImmediately: false)
                }
            }

        restartPeriodicRefreshLoop(refreshesImmediately: true)

        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
                self?.restartPeriodicRefreshLoop(refreshesImmediately: false)
            }
        }
    }

    func stop() {
        isStarted = false
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        refreshFrequencySubscription?.cancel()
        refreshFrequencySubscription = nil

        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
            self.workspaceWakeObserver = nil
        }
    }

    func refresh() async {
        guard refreshState != .refreshing else { return }
        refreshState = .refreshing
        errorMessage = nil

        do {
            let refreshedSnapshot = try await fetchSnapshot()
            snapshot = refreshedSnapshot
            saveSnapshot(refreshedSnapshot)
            refreshState = .loaded
        } catch is CancellationError {
            refreshState = snapshot == nil ? .idle : .loaded
        } catch {
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
            restartPeriodicRefreshLoop(refreshesImmediately: false)
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

    private func restartPeriodicRefreshLoop(refreshesImmediately: Bool) {
        guard isStarted else { return }
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { [weak self] in
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

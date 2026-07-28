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

    static let refreshIntervalSeconds: TimeInterval = 120
    static let staleIntervalSeconds: TimeInterval = 10 * 60

    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var refreshState: CodexUsageRefreshState = .idle
    @Published private(set) var errorMessage: String?

    private let fetchSnapshot: FetchSnapshot
    private let saveSnapshot: SaveSnapshot
    private var periodicRefreshTask: Task<Void, Never>?
    private var workspaceWakeObserver: NSObjectProtocol?

    init(
        fetchSnapshot: @escaping FetchSnapshot,
        initialSnapshot: CodexUsageSnapshot? = nil,
        saveSnapshot: @escaping SaveSnapshot = { _ in }
    ) {
        self.fetchSnapshot = fetchSnapshot
        self.snapshot = initialSnapshot
        self.saveSnapshot = saveSnapshot
    }

    convenience init() {
        let snapshotStore = CodexUsageSnapshotStore()
        let client = CodexUsageClient()
        self.init(
            fetchSnapshot: {
                try await client.fetchSnapshot()
            },
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
        guard periodicRefreshTask == nil else { return }

        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.refreshIntervalSeconds * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }
        }

        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func stop() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil

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
        } catch {
            refreshState = .failed
            errorMessage = Self.errorMessage(for: error)
        }
    }

    func isSnapshotStale(at currentDate: Date = Date()) -> Bool {
        guard let snapshot else { return true }
        return currentDate.timeIntervalSince(snapshot.refreshedAt) >= Self.staleIntervalSeconds
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

import Foundation
import CoreGraphics

struct CompanionOperationFeedback: Identifiable, Equatable {
    enum Kind: Equatable {
        // Performed confirms that input was dispatched, not a business result.
        case performed
        case uncertain
        case cancelled
    }

    let id: UUID
    let kind: Kind
    let location: CGPoint?
    let createdAt: Date

    init(kind: Kind, location: CGPoint? = nil, createdAt: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.location = location
        self.createdAt = createdAt
    }
}

struct CompanionOperationFeedbackSession {
    private var operationIdentifier: UUID?
    private var recordedKind: CompanionOperationFeedback.Kind?

    mutating func begin(operationIdentifier: UUID) {
        self.operationIdentifier = operationIdentifier
        recordedKind = nil
    }

    mutating func reset() {
        operationIdentifier = nil
        recordedKind = nil
    }

    mutating func finish(operationIdentifier: UUID) {
        guard self.operationIdentifier == operationIdentifier else { return }
        reset()
    }

    mutating func record(
        _ kind: CompanionOperationFeedback.Kind,
        operationIdentifier: UUID,
        location: CGPoint? = nil,
        createdAt: Date = Date()
    ) -> CompanionOperationFeedback? {
        guard self.operationIdentifier == operationIdentifier else { return nil }
        guard recordedKind == nil || (kind == .cancelled && recordedKind != .cancelled) else { return nil }
        recordedKind = kind
        return CompanionOperationFeedback(kind: kind, location: location, createdAt: createdAt)
    }
}

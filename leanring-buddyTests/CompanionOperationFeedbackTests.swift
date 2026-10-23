import Foundation
import CoreGraphics
import Testing
@testable import Matilda

struct CompanionOperationFeedbackTests {
    @Test func beginningAnOperationDoesNotClaimAnActionWasPerformed() {
        var session = CompanionOperationFeedbackSession()
        let operationIdentifier = UUID()
        session.begin(operationIdentifier: operationIdentifier)

        let feedback = session.record(.uncertain, operationIdentifier: operationIdentifier)
        #expect(feedback?.kind == .uncertain)
        #expect(feedback?.location == nil)
        #expect(session.record(.performed, operationIdentifier: operationIdentifier) == nil)
    }

    @Test func performedFeedbackPreservesActualInputLocationAndTime() {
        var session = CompanionOperationFeedbackSession()
        let operationIdentifier = UUID()
        let location = CGPoint(x: -250, y: 480)
        let dispatchedAt = Date(timeIntervalSince1970: 123)
        session.begin(operationIdentifier: operationIdentifier)

        let feedback = session.record(.performed, operationIdentifier: operationIdentifier, location: location, createdAt: dispatchedAt)
        #expect(feedback?.kind == .performed)
        #expect(feedback?.location == location)
        #expect(feedback?.createdAt == dispatchedAt)
        #expect(session.record(.performed, operationIdentifier: operationIdentifier) == nil)
    }

    @Test func olderCompletionCannotAnimateOrFinishTheNewerOperation() {
        var session = CompanionOperationFeedbackSession()
        let olderIdentifier = UUID()
        let newerIdentifier = UUID()
        session.begin(operationIdentifier: olderIdentifier)
        session.begin(operationIdentifier: newerIdentifier)

        #expect(session.record(.performed, operationIdentifier: olderIdentifier) == nil)
        session.finish(operationIdentifier: olderIdentifier)
        #expect(session.record(.performed, operationIdentifier: newerIdentifier)?.kind == .performed)
        session.finish(operationIdentifier: newerIdentifier)
        #expect(session.record(.cancelled, operationIdentifier: newerIdentifier) == nil)
    }

    @Test func cancellationSupersedesFeedbackOnceAndRejectsLateSuccess() {
        var session = CompanionOperationFeedbackSession()
        let operationIdentifier = UUID()
        session.begin(operationIdentifier: operationIdentifier)
        let performed = session.record(.performed, operationIdentifier: operationIdentifier)
        let cancelled = session.record(.cancelled, operationIdentifier: operationIdentifier)

        #expect(cancelled?.kind == .cancelled)
        #expect(cancelled?.id != performed?.id)
        #expect(session.record(.cancelled, operationIdentifier: operationIdentifier) == nil)
        #expect(session.record(.performed, operationIdentifier: operationIdentifier) == nil)
        session.reset()
        #expect(session.record(.uncertain, operationIdentifier: operationIdentifier) == nil)
    }
}

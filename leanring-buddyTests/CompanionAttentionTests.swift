import AppKit
import Testing
@testable import Matilda

struct CompanionAttentionTests {
    @Test func cursorAttentionUsesBoundedSpeedAndUnitDirection() {
        let diagonalMovement = CompanionCursorMotionPolicy.movementSample(
            from: .zero,
            to: CGPoint(x: 30, y: 40),
            elapsedTime: 0.016
        )
        #expect(diagonalMovement.energy == 1)
        #expect(abs(diagonalMovement.direction.x - 0.6) < 0.000_001)
        #expect(abs(diagonalMovement.direction.y - 0.8) < 0.000_001)

        let gentleMovement = CompanionCursorMotionPolicy.movementSample(
            from: .zero,
            to: CGPoint(x: -1, y: 0),
            elapsedTime: 0.02
        )
        #expect(gentleMovement.energy > 0 && gentleMovement.energy < 0.1)
        #expect(gentleMovement.direction == CGPoint(x: -1, y: 0))
        let stationaryMovement = CompanionCursorMotionPolicy.movementSample(
            from: .zero, to: .zero, elapsedTime: 0
        )
        #expect(stationaryMovement.energy == 0)
        #expect(stationaryMovement.direction == .zero)
    }

    @Test func cursorFollowRetainsItsExistingResponseWhileMoving() {
        let frameDuration = 1.0 / 60.0
        for response in CompanionFollowResponse.allCases {
            let fraction = CompanionCursorMotionPolicy.interpolationFraction(
                followResponse: response,
                frameDurationSeconds: frameDuration,
                timeSinceMovement: 0.02
            )
            #expect(fraction == response.smoothingFraction(frameDurationSeconds: frameDuration))
        }
        #expect(CompanionCursorMotionPolicy.interpolationFraction(
            followResponse: .quick, frameDurationSeconds: frameDuration, timeSinceMovement: 0.5
        ) == 1)
    }

    @Test func mediumAndSlowSettleWithoutTheFormerTwoHundredMillisecondJump() {
        let targetLocation = CGPoint(x: 1200, y: 800)
        for response in [CompanionFollowResponse.natural, .relaxed] {
            var renderedLocation = CGPoint.zero
            var lastStepDistance: CGFloat = 0
            for frameIndex in 1...60 {
                let fraction = CompanionCursorMotionPolicy.interpolationFraction(
                    followResponse: response,
                    frameDurationSeconds: 1.0 / 60.0,
                    timeSinceMovement: Double(frameIndex) / 60.0
                )
                let nextLocation = CGPoint(
                    x: renderedLocation.x + (targetLocation.x - renderedLocation.x) * fraction,
                    y: renderedLocation.y + (targetLocation.y - renderedLocation.y) * fraction
                )
                #expect(nextLocation.x >= renderedLocation.x && nextLocation.x <= targetLocation.x)
                #expect(nextLocation.y >= renderedLocation.y && nextLocation.y <= targetLocation.y)
                if frameIndex == 12 {
                    #expect(nextLocation.x < targetLocation.x - 10)
                    #expect(fraction < 0.2)
                }
                lastStepDistance = hypot(nextLocation.x - renderedLocation.x, nextLocation.y - renderedLocation.y)
                renderedLocation = nextLocation
            }
            #expect(renderedLocation == targetLocation)
            #expect(lastStepDistance < CompanionCursorMotionPolicy.restingDistancePoints)
        }
    }

    @Test func attentionRelaxesToRestAndDoesNotKeepAnIdleClockAlive() {
        var energy: CGFloat = 1
        var direction = CGPoint(x: 0.6, y: 0.8)
        for frameIndex in 1...60 {
            let previousEnergy = energy
            let decay = CompanionCursorMotionPolicy.attentionDecayFraction(
                frameDurationSeconds: 1.0 / 60.0,
                timeSinceMovement: Double(frameIndex) / 60.0
            )
            energy *= decay
            direction = CGPoint(x: direction.x * decay, y: direction.y * decay)
            #expect(energy <= previousEnergy)
        }
        #expect(CompanionCursorMotionPolicy.hasSettled(
            renderedLocation: .zero, targetLocation: .zero, energy: energy, direction: direction
        ))
        #expect(!CompanionCursorMotionPolicy.hasSettled(
            renderedLocation: .zero, targetLocation: CGPoint(x: 20, y: 0), energy: 0, direction: .zero
        ))
        #expect(!CompanionCursorMotionPolicy.hasSettled(
            renderedLocation: .zero, targetLocation: .zero, energy: 0.5, direction: .zero
        ))
    }
}

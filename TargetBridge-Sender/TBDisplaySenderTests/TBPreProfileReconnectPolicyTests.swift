import XCTest
@testable import TargetBridge

final class TBPreProfileReconnectPolicyTests: XCTestCase {
    func testInitialDialFailureDoesNotArmOrRetry() {
        var policy = TBPreProfileReconnectPolicy()

        XCTAssertEqual(policy.handle(.retryConnectionFailedOrTimedOut), .none)
        XCTAssertFalse(policy.isArmed)
        XCTAssertEqual(policy.scheduledAttemptCount, 0)
    }

    func testReadyThenEOFUsesFiniteBackoffAndExhausts() {
        var policy = TBPreProfileReconnectPolicy()

        XCTAssertEqual(policy.handle(.tcpReadyWithoutProfile), .none)
        for (index, delay) in TBPreProfileReconnectPolicy.retryDelays.enumerated() {
            XCTAssertEqual(
                policy.handle(index == 0
                    ? .connectionEndedBeforeProfile
                    : .retryConnectionFailedOrTimedOut),
                .retry(.init(
                    attempt: index + 1,
                    maximumAttempts: TBPreProfileReconnectPolicy.retryDelays.count,
                    delay: delay
                ))
            )
        }

        XCTAssertEqual(policy.handle(.retryConnectionFailedOrTimedOut), .exhausted)
        XCTAssertFalse(policy.isArmed)
        XCTAssertEqual(
            TBPreProfileReconnectPolicy.retryDelays.reduce(0, +),
            7.75,
            accuracy: 0.000_001
        )
    }

    func testProfileWatchdogCanStartRecoveryAfterReady() {
        var policy = TBPreProfileReconnectPolicy()
        _ = policy.handle(.tcpReadyWithoutProfile)

        XCTAssertEqual(
            policy.handle(.displayProfileTimedOut),
            .retry(.init(attempt: 1, maximumAttempts: 6, delay: 0.25))
        )
    }

    func testEachRetryReadyEventPreservesAttemptBudget() {
        var policy = TBPreProfileReconnectPolicy()
        _ = policy.handle(.tcpReadyWithoutProfile)
        _ = policy.handle(.connectionEndedBeforeProfile)

        XCTAssertEqual(policy.handle(.tcpReadyWithoutProfile), .none)
        XCTAssertEqual(
            policy.handle(.connectionEndedBeforeProfile),
            .retry(.init(attempt: 2, maximumAttempts: 6, delay: 0.5))
        )
    }

    func testDisplayProfileResetsRecoveryState() {
        var policy = TBPreProfileReconnectPolicy()
        _ = policy.handle(.tcpReadyWithoutProfile)
        _ = policy.handle(.connectionEndedBeforeProfile)

        XCTAssertEqual(policy.handle(.displayProfileReceived), .none)
        XCTAssertEqual(policy, TBPreProfileReconnectPolicy())
        XCTAssertEqual(policy.handle(.retryConnectionFailedOrTimedOut), .none)
    }

    func testUserOrInternalStopResetsRecoveryState() {
        var policy = TBPreProfileReconnectPolicy()
        _ = policy.handle(.tcpReadyWithoutProfile)
        _ = policy.handle(.connectionEndedBeforeProfile)

        XCTAssertEqual(policy.handle(.stopped), .none)
        XCTAssertEqual(policy, TBPreProfileReconnectPolicy())
    }
}

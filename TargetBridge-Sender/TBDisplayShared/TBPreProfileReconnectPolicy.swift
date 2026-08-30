import Foundation

/// A finite recovery policy for the receiver's wake-only startup handshake.
///
/// The policy deliberately stays disarmed for an ordinary failed dial. It is
/// armed only after TCP became ready while no display profile had arrived;
/// that is the evidence that a receiver accepted our HELLO and may be moving
/// from its lightweight startup broker to the full display listener.
struct TBPreProfileReconnectPolicy: Equatable {
    enum Event {
        case tcpReadyWithoutProfile
        case connectionEndedBeforeProfile
        case displayProfileTimedOut
        case retryConnectionFailedOrTimedOut
        case displayProfileReceived
        case stopped
    }

    struct Retry: Equatable {
        let attempt: Int
        let maximumAttempts: Int
        let delay: TimeInterval
    }

    enum Action: Equatable {
        case none
        case retry(Retry)
        case exhausted
    }

    /// Six attempts cover the receiver's panel-wake/listener handoff without
    /// turning a manual Connect into an unbounded background reconnect loop.
    /// The scheduled-delay budget is 7.75 seconds. Each dial remains bounded
    /// separately by the sender's existing five-second connect watchdog.
    static let retryDelays: [TimeInterval] = [0.25, 0.5, 1.0, 2.0, 2.0, 2.0]

    private(set) var isArmed = false
    private(set) var scheduledAttemptCount = 0

    mutating func handle(_ event: Event) -> Action {
        switch event {
        case .tcpReadyWithoutProfile:
            isArmed = true
            return .none

        case .connectionEndedBeforeProfile,
             .displayProfileTimedOut,
             .retryConnectionFailedOrTimedOut:
            guard isArmed else { return .none }
            guard scheduledAttemptCount < Self.retryDelays.count else {
                isArmed = false
                return .exhausted
            }
            let index = scheduledAttemptCount
            scheduledAttemptCount += 1
            return .retry(Retry(
                attempt: scheduledAttemptCount,
                maximumAttempts: Self.retryDelays.count,
                delay: Self.retryDelays[index]
            ))

        case .displayProfileReceived, .stopped:
            self = Self()
            return .none
        }
    }
}

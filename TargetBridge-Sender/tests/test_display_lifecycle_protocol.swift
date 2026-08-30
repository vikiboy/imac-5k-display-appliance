import Foundation

@main
struct TBDisplayLifecycleProtocolTests {
    static func require(_ condition: @autoclosure () -> Bool,
                        _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(
                Data("display lifecycle protocol failed: \(message)\n".utf8)
            )
            exit(1)
        }
    }

    static func main() throws {
        var receiver = TBMonotonicBooleanState(value: true)
        require(receiver.apply(value: false, epoch: 4) == .applied,
                "new receiver epoch applies")
        require(receiver.apply(value: false, epoch: 4) == .duplicate,
                "same receiver epoch is idempotent")
        require(receiver.apply(value: true, epoch: 3) == .stale,
                "stale receiver epoch is rejected")
        require(!receiver.value && receiver.epoch == 4,
                "stale state cannot reverse pause")

        require(!TBDisplayLifecyclePolicy.shouldProduceFrames(
                    sourceAwake: true,
                    receiverSurfaceAvailable: false,
                    peerSupportsLifecycle: true),
                "inactive receiver pauses production")
        require(!TBDisplayLifecyclePolicy.shouldProduceFrames(
                    sourceAwake: false,
                    receiverSurfaceAvailable: true,
                    peerSupportsLifecycle: true),
                "sleeping source pauses production")
        require(TBDisplayLifecyclePolicy.shouldProduceFrames(
                    sourceAwake: true,
                    receiverSurfaceAvailable: true,
                    peerSupportsLifecycle: true),
                "both gates resume production")
        require(TBDisplayLifecyclePolicy.shouldProduceFrames(
                    sourceAwake: false,
                    receiverSurfaceAvailable: false,
                    peerSupportsLifecycle: false),
                "legacy peers preserve pre-lifecycle frame production")
        require(TBDisplayLifecyclePolicy.shouldApplySourceTransition(
                    awake: false,
                    autoRestartOnWake: false),
                "sleep always closes the lifecycle gate")
        require(!TBDisplayLifecyclePolicy.shouldApplySourceTransition(
                    awake: true,
                    autoRestartOnWake: false),
                "wake preference can keep the lifecycle gate closed")
        require(TBDisplayLifecyclePolicy.shouldApplySourceTransition(
                    awake: true,
                    autoRestartOnWake: true),
                "enabled wake preference reopens the lifecycle gate")

        let state = TBMonitorSourceDisplayState(
            awake: false,
            epoch: 12,
            receiverEpoch: 9
        )
        let packet = TBMonitorProtocol.makeJSONPacket(
            type: .sourceDisplayState,
            value: state
        )!
        var stateBuffer = packet
        let decodedPacket = try TBMonitorProtocol.drainPacket(from: &stateBuffer)
        require(decodedPacket?.0 == .sourceDisplayState,
                "source state packet type round-trips")
        require(TBMonitorProtocol.decodeJSON(
                    TBMonitorSourceDisplayState.self,
                    from: decodedPacket!.1) == state,
                "source state payload round-trips")

        /* Unknown packets are consumed and skipped, so a new lifecycle packet
         * sent to a legacy peer cannot stall the known heartbeat behind it. */
        var unknown = Data([0, 0, 0, 2, 0x7E, 0xAA])
        unknown.append(TBMonitorProtocol.makeJSONPacket(
            type: .heartbeat,
            value: TBMonitorHeartbeat(sequence: 7)
        )!)
        let afterUnknown = try TBMonitorProtocol.drainPacket(from: &unknown)
        require(afterUnknown?.0 == .heartbeat && unknown.isEmpty,
                "unknown peer extension is safely skipped")

        print("sender display lifecycle protocol passed")
    }
}

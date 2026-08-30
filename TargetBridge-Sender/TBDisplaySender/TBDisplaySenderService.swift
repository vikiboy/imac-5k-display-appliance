import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import AVFoundation
import IOSurface
import IOKit.pwr_mgt
import Network
@preconcurrency import ScreenCaptureKit
import VideoToolbox

enum TBMonitorCodecLabel {
    static func resolve(
        usesDPCM: Bool,
        usesRawNV12: Bool,
        encodedCodecName: String
    ) -> String {
        if usesDPCM { return "DPCM 8-bit" }
        if usesRawNV12 { return "NV12 RAW" }
        return encodedCodecName
    }
}

enum TBDisplayCapturePreset: String, CaseIterable, Identifiable {
    case standard1440p
    case smooth1440p60
    case smooth1800p60
    case crisp2160p60
    case retina4k60
    case native5k
    case native5k60Experimental

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard1440p:
            return "Standard"
        case .smooth1440p60:
            return "Smooth"
        case .smooth1800p60:
            return "Smooth+"
        case .crisp2160p60:
            return "Crisp"
        case .retina4k60:
            return "Retina 4K"
        case .native5k:
            return "5K"
        case .native5k60Experimental:
            return "5K 60 Experimental"
        }
    }

    var description: String {
        switch self {
        case .standard1440p:
            return "2560 × 1440"
        case .smooth1440p60:
            return "2560 × 1440 @ 60"
        case .smooth1800p60:
            return "3200 × 1800 @ 60"
        case .crisp2160p60:
            return "3840 × 2160 @ 60"
        case .retina4k60:
            return "4096 × 2304 @ 60"
        case .native5k:
            return "5120 × 2880 @ 48"
        case .native5k60Experimental:
            return "5120 × 2880 @ 60"
        }
    }

    var width: Int {
        switch self {
        case .standard1440p, .smooth1440p60:
            return 2560
        case .smooth1800p60:
            return 3200
        case .crisp2160p60:
            return 3840
        case .retina4k60:
            return 4096
        case .native5k, .native5k60Experimental:
            return 5120
        }
    }

    var height: Int {
        switch self {
        case .standard1440p, .smooth1440p60:
            return 1440
        case .smooth1800p60:
            return 1800
        case .crisp2160p60:
            return 2160
        case .retina4k60:
            return 2304
        case .native5k, .native5k60Experimental:
            return 2880
        }
    }

    var averageBitRate: Int {
        switch self {
        case .standard1440p:
            return 36_000_000
        case .smooth1440p60:
            return 52_000_000
        case .smooth1800p60:
            return 78_000_000
        case .crisp2160p60:
            return 105_000_000
        case .retina4k60:
            return 120_000_000
        case .native5k:
            return 120_000_000
        case .native5k60Experimental:
            return 150_000_000
        }
    }

    var codecName: String {
        switch self {
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            return "H.264"
        case .crisp2160p60, .retina4k60, .native5k, .native5k60Experimental:
            return "HEVC"
        }
    }

    var codecType: CMVideoCodecType {
        switch self {
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            return kCMVideoCodecType_H264
        case .crisp2160p60, .retina4k60, .native5k, .native5k60Experimental:
            return kCMVideoCodecType_HEVC
        }
    }

    var queueDepth: Int {
        if let envVal = ProcessInfo.processInfo.environment["QD"], let parsed = Int(envVal) {
            return parsed
        }
        switch self {
        case .standard1440p:
            return 3
        case .smooth1440p60, .smooth1800p60, .crisp2160p60, .retina4k60,
             .native5k, .native5k60Experimental:
            // Five surfaces protect WindowServer from starvation during
            // high-frame-rate 4K capture while the serial pipeline prevents an
            // application-side frame backlog.
            return 5
        }
    }

    var expectedFrameRate: Int {
        switch self {
        case .standard1440p:
            return 30
        case .smooth1440p60:
            return 60
        case .smooth1800p60:
            return 60
        case .crisp2160p60, .retina4k60:
            return 60
        case .native5k:
            return 48
        case .native5k60Experimental:
            return 60
        }
    }

    /// ScreenCaptureKit treats `minimumFrameInterval` as a throttle rather than
    /// a target cadence. Requesting headroom avoids losing refreshes to scheduler
    /// tolerance; `TBFrameRatePacer` applies the exact output ceiling later.
    var captureRequestFrameRate: Int {
        expectedFrameRate >= 48 ? expectedFrameRate * 2 : expectedFrameRate
    }

    var maxKeyFrameInterval: Int {
        switch self {
        case .standard1440p:
            return 60
        case .smooth1440p60:
            return 60
        case .smooth1800p60:
            return 60
        case .crisp2160p60, .retina4k60:
            return 60
        case .native5k:
            return 48
        case .native5k60Experimental:
            return 60
        }
    }

    var maxKeyFrameIntervalDuration: Int {
        switch self {
        case .standard1440p:
            return 2
        case .smooth1440p60:
            return 1
        case .smooth1800p60, .crisp2160p60, .retina4k60:
            return 1
        case .native5k, .native5k60Experimental:
            return 1
        }
    }

    var prioritizeSpeed: Bool {
        switch self {
        case .standard1440p:
            return false
        case .smooth1440p60, .smooth1800p60, .crisp2160p60, .retina4k60, .native5k, .native5k60Experimental:
            return true
        }
    }

    var maxPendingVideoPackets: Int {
        if let envVal = ProcessInfo.processInfo.environment["MPVP"], let parsed = Int(envVal) {
            return parsed
        }
        return 3
    }

    var maxFrameDelayCount: Int {
        switch self {
        case .standard1440p:
            return 1
        case .smooth1440p60, .smooth1800p60, .crisp2160p60, .retina4k60, .native5k, .native5k60Experimental:
            return 0
        }
    }

    var dropsBeforeEncodeWhenBacklogged: Bool {
        switch self {
        case .standard1440p:
            return false
        case .smooth1440p60, .smooth1800p60, .crisp2160p60, .retina4k60, .native5k, .native5k60Experimental:
            return true
        }
    }

    var maxInFlightEncodeFrames: Int {
        if let envVal = ProcessInfo.processInfo.environment["MIFEF"], let parsed = Int(envVal) {
            return parsed
        }
        return 5
    }

    var captureResolution: SCCaptureResolutionType {
        switch self {
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            return .nominal
        case .crisp2160p60, .retina4k60, .native5k, .native5k60Experimental:
            return .best
        }
    }

    var virtualDisplayRefreshRate: Double {
        switch self {
        case .standard1440p:
            return 60
        case .smooth1440p60, .smooth1800p60:
            return 60
        case .crisp2160p60, .retina4k60:
            return 60
        case .native5k:
            return 48
        case .native5k60Experimental:
            return 60
        }
    }

    /// Virtual display mode that makes the render resolution equal the stream
    /// resolution. macOS HiDPI is strictly 2x, so a (w/2, h/2) mode backs onto a
    /// (w, h) framebuffer, which ScreenCaptureKit then captures 1:1.
    ///
    /// Costs screen real estate: the desktop reports "looks like w/2 x h/2" rather
    /// than the receiver's default 2560 x 1440.
    var renderMatchedDisplayMode: TBVirtualDisplayModeSize {
        TBVirtualDisplayModeSize(width: width / 2, height: height / 2)
    }

    /// Logical desktop size the user ends up with under render matching.
    var renderMatchedDesktopDescription: String {
        "\(width / 2) × \(height / 2)"
    }
}

/// A zero-buffer frame-rate ceiling for capture callbacks. Deadlines advance on
/// the ideal output timeline, allowing 75 Hz input to be sampled evenly at 60 Hz.
/// Long idle gaps reset the cadence instead of accumulating burst credit.
struct TBFrameRatePacer {
    private let frameInterval: CMTime
    private let deadlineTolerance = CMTime(value: 1, timescale: 10_000)
    private var nextDeadline: CMTime?

    init(maximumFrameRate: Int) {
        frameInterval = maximumFrameRate > 0
            ? CMTime(value: 1, timescale: CMTimeScale(maximumFrameRate))
            : .invalid
    }

    mutating func shouldEmit(presentationTime: CMTime) -> Bool {
        guard frameInterval.isValid, presentationTime.isValid,
              !presentationTime.isIndefinite else { return true }

        guard let deadline = nextDeadline else {
            nextDeadline = CMTimeAdd(presentationTime, frameInterval)
            return true
        }

        if CMTimeCompare(presentationTime, CMTimeSubtract(deadline, frameInterval)) < 0 {
            nextDeadline = CMTimeAdd(presentationTime, frameInterval)
            return true
        }

        guard CMTimeCompare(CMTimeAdd(presentationTime, deadlineTolerance), deadline) >= 0 else {
            return false
        }

        if CMTimeCompare(CMTimeSubtract(presentationTime, deadline), frameInterval) > 0 {
            nextDeadline = CMTimeAdd(presentationTime, frameInterval)
        } else {
            nextDeadline = CMTimeAdd(deadline, frameInterval)
        }
        return true
    }
}

enum TBDisplayCaptureSource: String, CaseIterable, Identifiable {
    case desktopMirror
    case extendedDesktop

    var id: String { rawValue }

    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch self {
        case .desktopMirror:
            return TBDisplaySenderL10n.text("sender.source.desktop_mirror", language)
        case .extendedDesktop:
            return TBDisplaySenderL10n.text("sender.source.extended_desktop", language)
        }
    }

    func virtualDisplayIdentity(receiverKey: String) -> TBVirtualDisplayIdentity {
        switch self {
        case .desktopMirror:
            return .desktopMirror
        case .extendedDesktop:
            return .extendedDesktop(receiverKey: receiverKey)
        }
    }
}

enum TBInputControlRole: String, CaseIterable, Identifiable {
    case off
    case senderMaster
    case receiverMaster

    var id: String { rawValue }

    func usesLowLatencyCursorOverlay(largeCursorEnabled: Bool) -> Bool {
        // ScreenCaptureKit preserves every native macOS cursor shape, including
        // temporary system cursors such as the screenshot crosshair. The custom
        // overlay is reserved for the explicit large-cursor accessibility option.
        largeCursorEnabled
    }

    func changesCursorCaptureMode(
        from previousRole: TBInputControlRole,
        largeCursorEnabled: Bool
    ) -> Bool {
        usesLowLatencyCursorOverlay(largeCursorEnabled: largeCursorEnabled)
            != previousRole.usesLowLatencyCursorOverlay(largeCursorEnabled: largeCursorEnabled)
    }
}

enum TBInputGestureMode: String, CaseIterable, Identifiable {
    case native
    case relayToSlave

    var id: String { rawValue }
}

private final class TBDirectDisplayStreamCapture {
    // Strong reference so the pipeline (and its delivery queue) outlives every
    // frame callback — a stray frame must never deref a freed pipeline.
    private let pipeline: TBVideoPipeline
    private let queue: DispatchQueue
    private var stream: CGDisplayStream?
    // CGDisplayStreamStop is asynchronous: frames already in flight keep arriving
    // until the stream delivers a final `.stopped` frame, and releasing the
    // CGDisplayStream before then crashes inside SkyLight's
    // `_CGYDisplayStreamFrameAvailable`. This self-reference keeps the capture
    // object (and the stream) alive from stop() until that `.stopped` frame.
    private var pendingStopRetain: TBDirectDisplayStreamCapture?

    init(pipeline: TBVideoPipeline, queue: DispatchQueue) {
        self.pipeline = pipeline
        self.queue = queue
    }

    func start(displayID: CGDirectDisplayID, preset: TBDisplayCapturePreset, showCursor: Bool) -> Bool {
        guard let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) else {
            return false
        }
        let properties: NSDictionary = [
            CGDisplayStream.showCursor: showCursor,
            CGDisplayStream.queueDepth: preset.queueDepth,
            CGDisplayStream.minimumFrameTime: 1.0 / Double(preset.expectedFrameRate),
            CGDisplayStream.colorSpace: displayP3
        ]

        let displayStream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: preset.width,
            outputHeight: preset.height,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: properties,
            queue: queue
        ) { [weak self] status, displayTime, surface, _ in
            // Delivered on `queue` — the pipeline's own serial queue — so encode
            // runs here, off the main thread, with no extra hop.
            guard let self else { return }
            if status == .stopped {
                // The stream has fully drained; no further frames will arrive, so
                // it is now safe to release the stream and drop the self-retain.
                self.stream = nil
                self.pendingStopRetain = nil
                return
            }
            guard status == .frameComplete, let surface else { return }
            // After pipeline.stop(), encodeDisplaySurface() no-ops on its `running`
            // guard, so a late in-flight frame here is harmless.
            self.pipeline.encodeDisplaySurface(surface, displayTime: displayTime)
        }

        guard let displayStream, displayStream.start() == .success else {
            return false
        }

        stream = displayStream
        return true
    }

    func stop() {
        guard stream != nil else { return }
        // Stay alive until the `.stopped` frame arrives (see pendingStopRetain);
        // the stream is released in the handler, never here, so it is never freed
        // with frame events still queued on `queue`.
        pendingStopRetain = self
        stream?.stop()
    }

    deinit {
        stop()
    }
}

enum TBVideoPipelineStopOutcome: Equatable {
    case stopped
    case dpcmEncoderQuarantined

    static func resolve(dpcmDrainStatus: TBDPCMDrainStatus?) -> Self {
        dpcmDrainStatus == .quarantined ? .dpcmEncoderQuarantined : .stopped
    }

    var requiresProcessTermination: Bool {
        self == .dpcmEncoderQuarantined
    }
}

struct TBVideoPipelineProgressSnapshot: Equatable {
    let capturedFrames: Int
    let sentFrames: Int
    let monitorsDPCMProgress: Bool
    let terminalEncoderHealth: Bool
}

enum TBPostFirstFrameProgressDecision: Equatable {
    case none
    case tearDownPreservingCodec
    case terminatePoisonedProcess
}

/// Detects active capture whose encoded delivery stopped after the first frame.
/// Polling is intentionally evidence-based rather than a wall-clock liveness
/// test: an event-driven capture source can legitimately produce no frames on a
/// static desktop. Two consecutive active polls and twelve captured frames with
/// no sent progress distinguish a sustained encoder failure from one interval
/// of pacing or bounded backpressure.
struct TBPostFirstFrameProgressWatchdog {
    static let minimumCapturedFramesWithoutSend = 12
    static let requiredConsecutiveActiveChecks = 2

    private var lastCapturedFrames = 0
    private var lastSentFrames = 0
    private var capturedWithoutSend = 0
    private var consecutiveActiveChecks = 0
    private var recoveryIssued = false

    mutating func reset(capturedFrames: Int = 0, sentFrames: Int = 0) {
        lastCapturedFrames = capturedFrames
        lastSentFrames = sentFrames
        capturedWithoutSend = 0
        consecutiveActiveChecks = 0
        recoveryIssued = false
    }

    mutating func observe(
        _ snapshot: TBVideoPipelineProgressSnapshot,
        hasDeliveredFirstFrame: Bool
    ) -> TBPostFirstFrameProgressDecision {
        let capturedDelta = max(0, snapshot.capturedFrames - lastCapturedFrames)
        let sentDelta = max(0, snapshot.sentFrames - lastSentFrames)
        lastCapturedFrames = snapshot.capturedFrames
        lastSentFrames = snapshot.sentFrames

        guard snapshot.monitorsDPCMProgress, hasDeliveredFirstFrame else {
            capturedWithoutSend = 0
            consecutiveActiveChecks = 0
            return .none
        }
        guard !recoveryIssued else { return .none }

        if snapshot.terminalEncoderHealth {
            recoveryIssued = true
            return .terminatePoisonedProcess
        }
        if sentDelta > 0 {
            capturedWithoutSend = 0
            consecutiveActiveChecks = 0
            return .none
        }
        guard capturedDelta > 0 else {
            /* No new capture evidence means a legitimate static desktop, not
             * an encoder stall. Break consecutiveness without inventing time. */
            capturedWithoutSend = 0
            consecutiveActiveChecks = 0
            return .none
        }

        capturedWithoutSend += capturedDelta
        consecutiveActiveChecks += 1
        if capturedWithoutSend >= Self.minimumCapturedFramesWithoutSend,
           consecutiveActiveChecks >= Self.requiredConsecutiveActiveChecks {
            recoveryIssued = true
            return .tearDownPreservingCodec
        }
        return .none
    }
}

/// Owns the capture→encode→send video pipeline and runs it entirely on a
/// dedicated serial queue, off the main thread. SwiftUI layout (or any other
/// main-thread work) therefore cannot stall frame delivery. All mutable encode
/// state is confined to `queue`; the two values the main thread polls
/// (`sentFrames`, `lastCaptureFrameAt`) are guarded by a small lock instead of
/// a per-frame hop back to main.
private final class TBCaptureAttemptGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    func deactivate() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

private final class TBVideoPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "fd.tbmonitor.sender.pipeline", qos: .userInteractive)

    private let preset: TBDisplayCapturePreset
    private let codecType: CMVideoCodecType
    private let connection: NWConnection
    private let displayName: String
    private let displayID: CGDirectDisplayID
    private let usesDPCM: Bool
    private let usesRawNV12: Bool
    private let rawMaxPendingVideoPackets: Int
    private let dpcmMaxPipelineFrames = 3
    private let onFirstFrame: @Sendable () -> Void
    private let attemptGate: TBCaptureAttemptGate

    // Confined to `queue`.
    private var vtEncoder: VTCompressionSession?
    private var vtEncoderRef: Unmanaged<TBVideoPipeline>?
    private var dpcmEncoder: TBDPCMAsyncEncode?
    private var pendingVideoPackets = 0
    private var inFlightEncodeFrames = 0
    private var displayStreamFrameSequence: CMTimeValue = 0
    private var lastEncodedDisplayPTS: CMTime?
    private var frameRatePacer: TBFrameRatePacer
    private var ackSent: Bool
    private var firstFrameReported = false
    private var running = false

    // Read from the main thread (fps timer / watchdog); guarded by `lock`.
    private let lock = NSLock()
    private var _sentFrames = 0
    private var capturedFrames = 0
    private var droppedByFrameRatePacer = 0
    private var droppedBeforeEncodeFrames = 0
    private var droppedAfterEncodeFrames = 0
    private var _lastCaptureFrameAt = Date()

    init(preset: TBDisplayCapturePreset,
         codecType: CMVideoCodecType,
         connection: NWConnection,
         displayName: String,
         displayID: CGDirectDisplayID,
         usesDPCM: Bool,
         usesRawNV12: Bool,
         ackAlreadySent: Bool,
         attemptGate: TBCaptureAttemptGate,
         onFirstFrame: @escaping @Sendable () -> Void) {
        self.preset = preset
        self.codecType = codecType
        self.connection = connection
        self.displayName = displayName
        self.displayID = displayID
        self.usesDPCM = usesDPCM
        self.usesRawNV12 = usesRawNV12
        let rawPendingOverride = ProcessInfo.processInfo.environment["RAW_PENDING"]
            .flatMap(Int.init)
        // RAW mode is already diagnostic-only. Two in-flight sends are the
        // measured minimum needed to overlap capture with a 22 MB network
        // write at 5K60; keep the override hard-bounded so experiments can
        // compare one slot without allowing a latency-growing frame queue.
        self.rawMaxPendingVideoPackets = min(max(rawPendingOverride ?? 2, 1), 2)
        self.frameRatePacer = TBFrameRatePacer(maximumFrameRate: preset.expectedFrameRate)
        self.ackSent = ackAlreadySent
        self.attemptGate = attemptGate
        self.onFirstFrame = onFirstFrame
    }

    // MARK: - Lifecycle (called from the main actor)

    /// Sets up the encoder on `queue`. Returns false if the hardware encoder
    /// could not be created.
    func start() -> Bool {
        queue.sync {
            if usesDPCM {
                guard let encoder = TBDPCMAsyncEncode() else {
                    NSLog("TargetBridge DPCM: unable to create GPU encoder")
                    return false
                }
                dpcmEncoder = encoder
                running = true
                NSLog("TargetBridge DPCM: GPU encoder ready device=%@", encoder.deviceName)
                return true
            }
            if usesRawNV12 {
                running = true
                return true
            }
            setupEncoder()
            running = vtEncoder != nil
            return running
        }
    }

    /// Tears the encoder down on `queue`. Because the queue is serial, any
    /// in-flight `encode` completes before `VTCompressionSessionInvalidate`,
    /// so a frame can never encode into an invalidated session.
    @discardableResult
    func stop() -> TBVideoPipelineStopOutcome {
        attemptGate.deactivate()
        return queue.sync {
            running = false
            var dpcmDrainStatus: TBDPCMDrainStatus?
            if let dpcmEncoder {
                // Callbacks copy their packet and enqueue pipeline work with
                // queue.async. They never queue.sync back here, so draining on
                // the pipeline queue cannot deadlock.
                dpcmDrainStatus = dpcmEncoder.drain()
                self.dpcmEncoder = nil
            }
            if let encoder = vtEncoder { VTCompressionSessionInvalidate(encoder) }
            vtEncoder = nil
            vtEncoderRef?.release()
            vtEncoderRef = nil
            return TBVideoPipelineStopOutcome.resolve(
                dpcmDrainStatus: dpcmDrainStatus
            )
        }
    }

    // MARK: - Snapshots for the main thread

    var sentFramesSnapshot: Int {
        lock.lock(); defer { lock.unlock() }
        return _sentFrames
    }

    var lastCaptureFrameAtSnapshot: Date {
        lock.lock(); defer { lock.unlock() }
        return _lastCaptureFrameAt
    }

    func progressSnapshot() -> TBVideoPipelineProgressSnapshot {
        queue.sync {
            lock.lock()
            let sent = _sentFrames
            lock.unlock()
            return TBVideoPipelineProgressSnapshot(
                capturedFrames: capturedFrames,
                sentFrames: sent,
                monitorsDPCMProgress: usesDPCM,
                terminalEncoderHealth: usesDPCM && TBDPCMEncoderProcessState.shared.isPoisoned
            )
        }
    }

    func diagnosticsSnapshot() -> (pending: Int, inFlight: Int, ptsSeq: CMTimeValue, captured: Int, droppedPacing: Int, droppedPre: Int, droppedPost: Int) {
        queue.sync {
            (
                pending: pendingVideoPackets,
                inFlight: inFlightEncodeFrames,
                ptsSeq: displayStreamFrameSequence,
                captured: capturedFrames,
                droppedPacing: droppedByFrameRatePacer,
                droppedPre: droppedBeforeEncodeFrames,
                droppedPost: droppedAfterEncodeFrames
            )
        }
    }

    private func markCaptureFrame() {
        capturedFrames += 1
        lock.lock(); _lastCaptureFrameAt = Date(); lock.unlock()
    }

    // MARK: - Encoder setup (on `queue`)

    private func setupEncoder() {
        if let encoder = vtEncoder { VTCompressionSessionInvalidate(encoder) }
        vtEncoder = nil
        vtEncoderRef?.release()
        vtEncoderRef = nil

        let spec: NSDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        let retained = Unmanaged.passRetained(self)
        vtEncoderRef = retained

        let callback: VTCompressionOutputCallback = { ref, _, status, _, sampleBuffer in
            guard let ref else { return }
            let pipeline = Unmanaged<TBVideoPipeline>.fromOpaque(ref).takeUnretainedValue()
            pipeline.queue.async {
                pipeline.inFlightEncodeFrames = max(0, pipeline.inFlightEncodeFrames - 1)
                guard status == noErr, let sampleBuffer else { return }
                pipeline.handleEncoded(sampleBuffer)
            }
        }

        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(preset.width),
            height: Int32(preset.height),
            codecType: codecType,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: retained.toOpaque(),
            compressionSessionOut: &session
        ) == noErr, let session else {
            retained.release()
            vtEncoderRef = nil
            return
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        if codecType == kCMVideoCodecType_HEVC {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: preset.expectedFrameRate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: preset.maxKeyFrameInterval))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: preset.maxKeyFrameIntervalDuration))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: preset.maxFrameDelayCount))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: preset.averageBitRate))
        if preset.prioritizeSpeed {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        vtEncoder = session
    }

    // MARK: - Encode paths (on `queue`)

    /// Opt-in raw passthrough: ScreenCaptureKit already captures NV12,
    /// so we can forward the planes uncompressed and skip the encoder entirely.
    /// This removes all decode cost on the receiver — useful when the receiver is
    /// an older Intel Mac whose HEVC decoder struggles at high resolutions — at
    /// the price of much higher bandwidth (~10.6 Gb/s for 5K@60 4:2:0), which a
    /// direct Thunderbolt Bridge link comfortably sustains.
    /// SCStream capture path. Must be dispatched onto `queue` by the caller.
    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard attemptGate.isActive else { return }
        markCaptureFrame()
        defer {
            if usesRawNV12, capturedFrames.isMultiple(of: 600) {
                lock.lock()
                let sent = _sentFrames
                lock.unlock()
                NSLog(
                    "TargetBridge RAW: captured=%d sent=%d droppedPacing=%d droppedBackpressure=%d pending=%d pendingLimit=%d",
                    capturedFrames,
                    sent,
                    droppedByFrameRatePacer,
                    droppedBeforeEncodeFrames,
                    pendingVideoPackets,
                    rawMaxPendingVideoPackets
                )
            }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard frameRatePacer.shouldEmit(presentationTime: pts) else {
            droppedByFrameRatePacer += 1
            return
        }
        if usesDPCM {
            sendDPCMFrame(sampleBuffer)
            return
        }
        if usesRawNV12 {
            sendRawFrame(sampleBuffer)
            return
        }
        guard running, let encoder = vtEncoder,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        if preset.dropsBeforeEncodeWhenBacklogged,
           (pendingVideoPackets >= preset.maxPendingVideoPackets ||
            inFlightEncodeFrames >= preset.maxInFlightEncodeFrames) {
            droppedBeforeEncodeFrames += 1
            return
        }
        encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts, using: encoder)
    }

    /// CGDisplayStream capture path. Delivered directly on `queue` by
    /// `TBDirectDisplayStreamCapture`.
    func encodeDisplaySurface(_ surface: IOSurfaceRef, displayTime: UInt64) {
        guard attemptGate.isActive else { return }
        markCaptureFrame()
        guard running else { return }

        var pts = displayTime != 0
            ? CMClockMakeHostTimeFromSystemUnits(displayTime)
            : CMClockGetTime(CMClockGetHostTimeClock())
        if let last = lastEncodedDisplayPTS, CMTimeCompare(pts, last) <= 0 {
            // VTCompressionSession requires strictly increasing PTS.
            pts = CMTimeAdd(last, CMTime(value: 1, timescale: 600))
        }
        guard frameRatePacer.shouldEmit(presentationTime: pts) else {
            droppedByFrameRatePacer += 1
            return
        }
        let attrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: preset.width,
            kCVPixelBufferHeightKey: preset.height,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()
        ]
        var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            attrs,
            &unmanagedPixelBuffer
        ) == kCVReturnSuccess, let unmanagedPixelBuffer else {
            return
        }
        let pixelBuffer = unmanagedPixelBuffer.takeRetainedValue()

        if usesDPCM {
            sendDPCMFrame(pixelBuffer)
            return
        }
        guard let encoder = vtEncoder else { return }
        if preset.dropsBeforeEncodeWhenBacklogged,
           (pendingVideoPackets >= preset.maxPendingVideoPackets ||
            inFlightEncodeFrames >= preset.maxInFlightEncodeFrames) {
            droppedBeforeEncodeFrames += 1
            return
        }

        displayStreamFrameSequence += 1
        // Derive PTS from the frame's actual capture time. CGDisplayStream
        // delivers frames irregularly (event-driven on screen changes), so a
        // frame-counter PTS would drift away from real wall-clock time over a
        // long session and pace the receiver progressively wrong. displayTime is
        // in mach-absolute units, the same host clock the SCStream path uses.
        lastEncodedDisplayPTS = pts
        encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts, using: encoder)
    }

    private func sendDPCMFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            droppedBeforeEncodeFrames += 1
            return
        }
        submitDPCM(pixelBuffer: pixelBuffer) { [dpcmEncoder] completion in
            guard let dpcmEncoder else { return false }
            return dpcmEncoder.submit(sampleBuffer: sampleBuffer, completion: completion)
        }
    }

    private func sendDPCMFrame(_ pixelBuffer: CVPixelBuffer) {
        submitDPCM(pixelBuffer: pixelBuffer) { [dpcmEncoder] completion in
            guard let dpcmEncoder else { return false }
            return dpcmEncoder.submit(pixelBuffer: pixelBuffer, completion: completion)
        }
    }

    /// Keep the total number of GPU jobs plus socket writes bounded to the
    /// encoder's three reusable job slots. Every counter mutation happens on
    /// `queue`; callbacks only enqueue asynchronously onto it.
    private func submitDPCM(
        pixelBuffer: CVPixelBuffer,
        submit: (@escaping @Sendable (Data?) -> Void) -> Bool
    ) {
        guard running, dpcmEncoder != nil,
              CVPixelBufferGetWidth(pixelBuffer) == preset.width,
              CVPixelBufferGetHeight(pixelBuffer) == preset.height,
              pendingVideoPackets + inFlightEncodeFrames < dpcmMaxPipelineFrames
        else {
            droppedBeforeEncodeFrames += 1
            return
        }

        inFlightEncodeFrames += 1
        let accepted = submit { [weak self] packet in
            guard let self else { return }
            self.queue.async {
                self.inFlightEncodeFrames = max(0, self.inFlightEncodeFrames - 1)
                guard self.running, let packet else {
                    self.droppedAfterEncodeFrames += 1
                    return
                }
                self.sendDPCMPacket(packet)
            }
        }
        if !accepted {
            inFlightEncodeFrames = max(0, inFlightEncodeFrames - 1)
            droppedBeforeEncodeFrames += 1
        }
    }

    private func sendDPCMPacket(_ packet: Data) {
        guard running, attemptGate.isActive else { return }
        guard pendingVideoPackets < dpcmMaxPipelineFrames else {
            droppedAfterEncodeFrames += 1
            return
        }

        sendSessionAckIfNeeded()
        reportFirstFrameIfNeeded()

        pendingVideoPackets += 1
        connection.send(content: packet, completion: .contentProcessed({ [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.pendingVideoPackets = max(0, self.pendingVideoPackets - 1)
            }
        }))
        lock.lock(); _sentFrames += 1; lock.unlock()
    }

    private func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp pts: CMTime, using encoder: VTCompressionSession) {
        inFlightEncodeFrames += 1
        let status = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            inFlightEncodeFrames = max(0, inFlightEncodeFrames - 1)
        }
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard running, attemptGate.isActive else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        if !isKeyframe, pendingVideoPackets >= preset.maxPendingVideoPackets {
            droppedAfterEncodeFrames += 1
            return
        }

        if isKeyframe,
           let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let packet = buildParamSetsPacket(from: format, codecType: codecType) {
            connection.send(content: packet, completion: .contentProcessed({ _ in }))
        }

        if let packet = buildFramePacket(from: sampleBuffer) {
            sendSessionAckIfNeeded()
            reportFirstFrameIfNeeded()
            pendingVideoPackets += 1
            connection.send(content: packet, completion: .contentProcessed({ [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.pendingVideoPackets = max(0, self.pendingVideoPackets - 1)
                }
            }))
            lock.lock(); _sentFrames += 1; lock.unlock()
        }
    }

    /// Raw passthrough: package the two NV12 planes of the captured pixel buffer
    /// and send them uncompressed. The receiver blits them directly (no decode).
    /// Payload: [1: format=1(NV12)][BE32 w][BE32 h][BE32 yStride][BE32 uvStride]
    ///          [Y plane: yStride*h][CbCr plane: uvStride*(h/2)]
    private func sendRawFrame(_ sampleBuffer: CMSampleBuffer) {
        guard running, attemptGate.isActive,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        // Backpressure: never pile frames on top of a network that can't keep up.
        if pendingVideoPackets >= rawMaxPendingVideoPackets {
            droppedBeforeEncodeFrames += 1
            return
        }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) ==
                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2
        else {
            droppedBeforeEncodeFrames += 1
            return
        }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) ==
                  kCVReturnSuccess
        else {
            droppedBeforeEncodeFrames += 1
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else {
            droppedBeforeEncodeFrames += 1
            return
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        guard width > 0, height > 0,
              width <= 8192, height <= 8192,
              width.isMultiple(of: 2), height.isMultiple(of: 2),
              yHeight == height, uvWidth == width / 2, uvHeight == height / 2,
              yStride >= width, uvStride >= width,
              yStride <= 16384, uvStride <= 16384
        else {
            droppedBeforeEncodeFrames += 1
            return
        }
        let ySize = yStride * height
        let uvSize = uvStride * uvHeight
        guard 18 + ySize + uvSize <= Int(TBMonitorProtocol.maxPacketLength) else {
            droppedBeforeEncodeFrames += 1
            return
        }

        // Build framing and planes into one allocation. Going through
        // makePacket(payload:) would copy this ~22 MB 5K frame into a second
        // Data value before every send (about 1.3 GB/s of avoidable copying at
        // 60 Hz).
        let rawPayloadSize = 17 + ySize + uvSize
        var packet = Data(capacity: 5 + rawPayloadSize)
        TBMonitorProtocol.appendBE32(&packet, UInt32(1 + rawPayloadSize))
        packet.append(TBMonitorPacketType.rawFrame.rawValue)
        packet.append(1) // format: NV12
        TBMonitorProtocol.appendBE32(&packet, UInt32(width))
        TBMonitorProtocol.appendBE32(&packet, UInt32(height))
        TBMonitorProtocol.appendBE32(&packet, UInt32(yStride))
        TBMonitorProtocol.appendBE32(&packet, UInt32(uvStride))
        packet.append(UnsafeBufferPointer(
            start: yBase.assumingMemoryBound(to: UInt8.self),
            count: ySize
        ))
        packet.append(UnsafeBufferPointer(
            start: uvBase.assumingMemoryBound(to: UInt8.self),
            count: uvSize
        ))

        sendSessionAckIfNeeded()
        reportFirstFrameIfNeeded()
        pendingVideoPackets += 1
        connection.send(content: packet, completion: .contentProcessed({ [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.pendingVideoPackets = max(0, self.pendingVideoPackets - 1)
            }
        }))
        lock.lock(); _sentFrames += 1; lock.unlock()
    }

    private func sendSessionAckIfNeeded() {
        guard !ackSent else { return }
        ackSent = true
        let ack = TBMonitorCreateSessionAck(
            accepted: true,
            displayName: displayName,
            displayID: displayID
        )
        if let packet = TBMonitorProtocol.makeJSONPacket(type: .createSessionAck, value: ack) {
            connection.send(content: packet, completion: .contentProcessed({ _ in }))
        }
    }

    /// A connection ACK is sent only once, but every replacement capture
    /// pipeline must prove that it produced a real frame. Keeping these two
    /// facts separate makes wake/restart watchdogs meaningful.
    private func reportFirstFrameIfNeeded() {
        guard !firstFrameReported else { return }
        firstFrameReported = true
        onFirstFrame()
    }

    private func buildParamSetsPacket(from format: CMVideoFormatDescription, codecType: CMVideoCodecType) -> Data? {
        if codecType == kCMVideoCodecType_HEVC {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
            guard count > 0 else { return nil }

            var payload = Data([2, UInt8(count)])
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard let pointer else { continue }
                TBMonitorProtocol.appendBE32(&payload, UInt32(size))
                payload.append(UnsafeBufferPointer(start: pointer, count: size))
            }
            return TBMonitorProtocol.makePacket(type: .paramSets, payload: payload)
        } else {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
            guard count > 0 else { return nil }

            var payload = Data([1, UInt8(count)])
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard let pointer else { continue }
                TBMonitorProtocol.appendBE32(&payload, UInt32(size))
                payload.append(UnsafeBufferPointer(start: pointer, count: size))
            }
            return TBMonitorProtocol.makePacket(type: .paramSets, payload: payload)
        }
    }

    private func buildFramePacket(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return nil }

        var payload = Data(count: totalLength)
        let status = payload.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return kCMBlockBufferBadCustomBlockSourceErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: baseAddress
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        return TBMonitorProtocol.makePacket(type: .frame, payload: payload)
    }
}

/// Live, frequently-updating session readouts (currently just the FPS counter),
/// split out of `TBDisplaySenderSession` so their ~1 Hz changes only invalidate
/// the small subview that displays them rather than the whole session card.
@MainActor
final class TBSessionLiveMetrics: ObservableObject {
    @Published var senderFPS = 0
}

@MainActor
final class TBDisplaySenderSession: NSObject, ObservableObject, Identifiable, @unchecked Sendable {
    private static let receiverIPDefaultsKey = "fd.tbdisplaysender.receiverIP"
    private struct SavedExtendedDisplayArrangement {
        let x: Int32
        let y: Int32
        let isRelativeToMainDisplay: Bool
    }

    private static let extendedArrangementDefaultsPrefix = "com.vikiboy.imac5kdisplay.sender.extended-arrangement"

    private static func normalizedPng(for image: NSImage) -> Data? {
        let targetSize = NSSize(width: 32, height: 32)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        // Clear canvas
        NSColor.clear.set()
        NSRect(origin: .zero, size: targetSize).fill()

        // Draw the image centered
        let x = (targetSize.width - image.size.width) / 2
        let y = (targetSize.height - image.size.height) / 2
        image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: image.size.height))

        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }

    private static let standardCursorPngs: [Data: Int] = {
        let standardCursors: [(Int, NSCursor)] = [
            (0, NSCursor.arrow),
            (1, NSCursor.iBeam),
            (2, NSCursor.pointingHand),
            (3, NSCursor.resizeLeft),
            (3, NSCursor.resizeRight),
            (3, NSCursor.resizeLeftRight),
            (4, NSCursor.resizeUp),
            (4, NSCursor.resizeDown),
            (4, NSCursor.resizeUpDown),
            (5, NSCursor.closedHand),
            (5, NSCursor.openHand),
            (6, NSCursor.crosshair)
        ]
        var dict = [Data: Int]()
        for (type, cursor) in standardCursors {
            if let png = normalizedPng(for: cursor.image) {
                dict[png] = type
            }
        }

        // Dynamically load private system window resize cursors to support macOS window borders perfectly
        let privateCursors: [(Int, String)] = [
            (3, "_windowResizeEastWestCursor"),
            (4, "_windowResizeNorthSouthCursor"),
            (7, "_windowResizeNorthWestSouthEastCursor"),
            (8, "_windowResizeNorthEastSouthWestCursor"),
            (3, "_horizontalResizeCursor"),
            (4, "_verticalResizeCursor")
        ]
        for (type, selName) in privateCursors {
            let sel = NSSelectorFromString(selName)
            if NSCursor.responds(to: sel),
               let cursorObj = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor,
               let png = normalizedPng(for: cursorObj.image) {
                dict[png] = type
            }
        }

        return dict
    }()

    let id = UUID()

    init(
        language: TBDisplaySenderLanguage,
        largeCursor: Bool,
        preventDisplaySleep: Bool,
        autoRestartOnWake: Bool,
        audioEnabled: Bool,
        verboseDisplayLogging: Bool = false
    ) {
        self.statusText = TBDisplaySenderStatusState.ready.text(language)
        self.receiverPanelText = TBDisplaySenderL10n.waitingReceiverProfile(language)
        self.virtualDisplayText = TBDisplaySenderL10n.virtualDisplayNotCreated(language)
        self.captureDisplayText = TBDisplaySenderL10n.captureDisplayNotAvailable(language)
        self.displayStateText = TBDisplaySenderL10n.displayStateNotAvailable(language)
        self.language = language
        self.largeCursor = largeCursor
        self.preventDisplaySleep = preventDisplaySleep
        self.autoRestartOnWake = autoRestartOnWake
        self.audioEnabled = audioEnabled
        self.verboseDisplayLogging = verboseDisplayLogging
        self.streamResolutionText = TBDisplaySenderL10n.streamSummary(
            preset: .standard1440p,
            source: .desktopMirror,
            language: language
        )
        self.sourceDisplayState = TBMonotonicBooleanState(
            value: Self.currentSourceDisplayAvailable(),
            epoch: 1
        )
        super.init()
        registerDisplayLifecycleObservers()
        registerDisplayReconfigurationCallback()
    }

    deinit {
        for token in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        if displayReconfigurationCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(
                Self.displayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }

    @Published var isConnected = false
    @Published var isStreaming = false
    @Published var statusText: String
    @Published var transportKind: TBTransportKind = .thunderboltBridge
    @Published var localInterfaceIP = ""
    @Published var selectedReceiverID = "" {
        didSet {
            if selectedReceiverID.isEmpty {
                receiverSupportsHEVCDecodeHint = nil
                receiverInputMonitoringTrustedHint = nil
                receiverAccessibilityTrustedHint = nil
            }
        }
    }
    @Published var isCableTesting = false
    @Published var cableTestResult: Double? = nil
    private var isCableTestConnection = false
    @Published var receiverIP: String = UserDefaults.standard.string(forKey: receiverIPDefaultsKey) ?? "" {
        didSet {
            UserDefaults.standard.set(receiverIP, forKey: Self.receiverIPDefaultsKey)
            if receiverIP != oldValue {
                receiverSupportsHEVCDecodeHint = nil
                receiverInputMonitoringTrustedHint = nil
                receiverAccessibilityTrustedHint = nil
            }
        }
    }
    var shortHostName: String? {
        if let receiver = TBDisplaySenderService.shared.discoveredReceivers.first(where: {
            $0.id == selectedReceiverID ||
            $0.preferredIP == receiverIP ||
            $0.thunderboltIP == receiverIP ||
            $0.networkIP == receiverIP
        }) {
            return receiver.shortHostName
        }
        return nil
    }

    var receiverDisplayName: String {
        if let host = shortHostName {
            return host
        }
        return receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var receiverSubtitle: String {
        var parts: [String] = []
        let ip = receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ip.isEmpty {
            parts.append("\(TBDisplaySenderL10n.receiverIP(language)) \(ip)")
        }
        if !receiverPanelText.isEmpty {
            parts.append(receiverPanelText)
        }
        return parts.joined(separator: "\n")
    }

    @Published var audioEnabled: Bool
    @Published var brightness: Double = 1.0 {
        didSet {
            sendBrightnessUpdate()
        }
    }
    @Published var volume: Double = 0.5 {
        didSet {
            sendVolumeUpdate()
        }
    }
    /// Night Shift / True Tone on the receiver's own panel. Only offered when
    /// the receiver reports it can honour them (both are private CoreBrightness
    /// features, and True Tone needs supporting hardware).
    @Published var nightShiftEnabled = false {
        didSet { if !adoptingReportedTweaks { sendDisplayTweaks() } }
    }
    @Published var trueToneEnabled = false {
        didSet { if !adoptingReportedTweaks { sendDisplayTweaks() } }
    }
    /// Set while adopting state the receiver reported, so the didSet observers
    /// above don't echo it back and start a loop.
    private var adoptingReportedTweaks = false
    @Published var receiverSupportsNightShift = false
    @Published var receiverSupportsTrueTone = false
    var audioAddonAvailable = true
    var receiverSupportsHEVCDecodeHint: Bool?
    var receiverInputMonitoringTrustedHint: Bool?
    var receiverAccessibilityTrustedHint: Bool?
    @Published var senderFPS = 0
    // Live FPS readout. Kept on a dedicated observable so its once-per-second
    // update only re-renders the small FPS subview — not the whole session card
    // or (via the manager's objectWillChange bubble-up) the entire window.
    let liveMetrics = TBSessionLiveMetrics()
    @Published var receiverPanelText: String
    @Published var virtualDisplayText: String
    @Published var captureDisplayText: String
    @Published var displayStateText: String
    @Published var language: TBDisplaySenderLanguage {
        didSet {
            refreshLocalizedText()
        }
    }
    @Published var largeCursor: Bool
    @Published var preventDisplaySleep: Bool = true
    @Published var autoRestartOnWake: Bool = true {
        didSet {
            guard autoRestartOnWake,
                  activeProfile != nil,
                  Self.currentSourceDisplayAvailable() else { return }
            handleSourceDisplayAvailability(awake: true)
        }
    }
    @Published var verboseDisplayLogging: Bool = false {
        didSet {
            if verboseDisplayLogging {
                startVerboseLoggingTimer()
            } else {
                stopVerboseLoggingTimer()
            }
        }
    }
    /// When enabled, the virtual display's backing store is sized to the capture
    /// preset instead of the receiver-advertised 5120x2880. Removes the capture-side
    /// downsample and the GPU cost of rendering pixels that get thrown away.
    @Published var matchRenderToStream: Bool = false

    @Published var capturePreset: TBDisplayCapturePreset = .standard1440p {
        didSet {
            if !isStreaming {
                streamResolutionText = TBDisplaySenderL10n.streamSummary(preset: capturePreset, source: captureSource, language: language)
            }
        }
    }
    @Published var captureSource: TBDisplayCaptureSource = .desktopMirror {
        didSet {
            if !isStreaming {
                streamResolutionText = TBDisplaySenderL10n.streamSummary(preset: capturePreset, source: captureSource, language: language)
            }
        }
    }
    @Published var streamResolutionText: String
    var inputRelayActive = false {
        didSet {
            guard inputRelayActive != oldValue else { return }
            applyCursorOverlayMode()
        }
    }
    @Published var inputControlRole: TBInputControlRole = .off {
        didSet {
            let cursorCaptureModeChanged = inputControlRole.changesCursorCaptureMode(
                from: oldValue,
                largeCursorEnabled: largeCursor
            )
            inputRelayActive = (inputControlRole == .senderMaster)
            if inputControlRole != .receiverMaster {
                injectedRemoteMouseLocation = nil
                injectedLeftClickTracker.reset()
                releaseInjectedModifiersIfNeeded()
                remoteHeldModifierKeyCodes.removeAll()
                suppressedTriggerKeyCode = nil
            }
            if cursorCaptureModeChanged, isStreaming {
                restartCaptureNow()
            }
        }
    }
    @Published var inputGestureMode: TBInputGestureMode = .native
    /// User-defined receiver-master shortcuts for this session. See
    /// TBInputBinding.
    @Published var inputBindings: [TBInputBinding] = []

    private var connection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "fd.tbmonitor.sender.connection", qos: .userInteractive)
    private var recvBuffer = Data()

    private var session = ReceiverBackedVirtualDisplaySession()
    private let audioConverter = SBAudioConverter()
    private var activeProfile: TBMonitorDisplayProfile?
    private var activeCodecType: CMVideoCodecType?
    private var activeCodecName: String?

    private var captureDelegate: CaptureDelegate?
    private var scStream: SCStream?
    private var directDisplayStream: TBDirectDisplayStreamCapture?
    private var pipeline: TBVideoPipeline?

    private var sentSnapshot = 0
    private var sessionAckSent = false
    private var captureBlockedByScreenRecordingPermission = false
    private var fpsTimer: Timer?
    private var heartbeatTimer: Timer?
    private var firstFrameTimer: Timer?
    private var cursorTimer: Timer?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    /// TCP readiness only proves that a socket opened. The receiver still has
    /// to identify itself with a display profile before this can become a
    /// monitor session. Keep that negotiation bounded independently so a
    /// stale/auxiliary peer cannot leave automatic appliance mode falsely
    /// "connected" forever.
    private var displayProfileTimeoutWorkItem: DispatchWorkItem?
    /// Finite, control-plane-only recovery for the receiver startup broker:
    /// that broker accepts HELLO to wake the panel, then closes so the full
    /// display listener can take over. This is intentionally independent from
    /// appliance automation so a manual GUI Connect gets the same recovery.
    private var preProfileReconnectPolicy = TBPreProfileReconnectPolicy()
    private var preProfileReconnectWorkItem: DispatchWorkItem?
    private var preProfileReconnectGeneration: UInt64 = 0
    /// Lets appliance automation distinguish the intentional broker→listener
    /// handoff gap from a terminal disconnect. No capture/display resources
    /// exist while this is true and `isConnected` is false.
    var isRecoveringPreProfileConnection: Bool {
        activeProfile == nil &&
            preProfileReconnectPolicy.isArmed &&
            (connection != nil || preProfileReconnectWorkItem != nil)
    }
    /// TCP readiness and broker recovery are not yet a usable monitor session.
    /// Automation uses this explicit profile gate before resetting its outer
    /// reconnect backoff after a stable run.
    var hasNegotiatedDisplayProfile: Bool {
        activeProfile != nil
    }
    /// Name of the local interface the current connect attempt is bound to
    /// (e.g. "bridge0"), resolved when dialing. Diagnostic context only.
    private var connectInterfaceName: String?
    /// Last state reported by NWConnection for the current attempt (e.g.
    /// "waiting(No route to host)") — surfaced when a connect fails or times
    /// out so the real reason is not lost.
    private var lastConnectionStateDetail: String?
    private var heartbeatSequence: UInt64 = 0
    private var statusState: TBDisplaySenderStatusState = .ready
    private var streamingActivity: NSObjectProtocol?
    private var displayWakeAssertionID = IOPMAssertionID(0)
    private var lastCheckedCursor: NSCursor?
    private var lastCheckedCursorType: Int = 0
    private var baselineDisplayIDs = Set<CGDirectDisplayID>()
    private var cursorDisplayID: CGDirectDisplayID = kCGNullDirectDisplay
    private var lastCursorPacket: TBMonitorCursor?
    private var injectedRemoteMouseLocation: CGPoint?
    private var injectedLeftClickTracker = TBInjectedClickStateTracker()
    private var injectedCommandDown = false
    private var injectedShiftDown = false
    private var injectedOptionDown = false
    private var injectedControlDown = false
    private var injectedCapsDown = false
    // Tracks the actual modifier keys still held on the receiver while a
    // System Events shortcut is running, so released keys are never restored.
    private var remoteHeldModifierKeyCodes = Set<UInt16>()
    /// While a binding trigger key is held (matched), swallow its key-up so the
    /// raw trigger key never reaches the slave.
    private var suppressedTriggerKeyCode: UInt16?
    private static var cachedSupportsHEVCHardwareEncode: Bool?
    private var receivedInputEventCount: UInt64 = 0
    var onRemoteSwitchRequest: ((Int) -> Void)?
    var onRemoteDeactivateInputRequest: (() -> Void)?
    nonisolated(unsafe) private var wakeObservers: [NSObjectProtocol] = []
    private var isRestartingCaptureAfterWake = false
    /// Legacy receivers never send surface-state packets, so availability
    /// starts true and their established behavior is unchanged. A capable
    /// receiver immediately replaces this with its fail-closed initial state.
    private var receiverSurfaceState = TBMonotonicBooleanState(value: true)
    private var sourceDisplayState = TBMonotonicBooleanState(value: true, epoch: 1)
    private var lastSentSourceDisplayEpoch: UInt64?
    private var lastAcknowledgedReceiverSurfaceEpoch: UInt64?
    private var displayLifecycleTransitionInFlight = false
    private var displayLifecycleTransitionGeneration: UInt64 = 0
    private var captureAttemptGeneration: UInt64 = 0
    private var captureAttemptFirstFrameSeen = false
    private var captureAttemptGate: TBCaptureAttemptGate?
    nonisolated(unsafe) private var displayReconfigurationCallbackRegistered = false
    private var verboseLoggingTimer: Timer?
    private var captureHealthWatchdog: Timer?
    private var postFirstFrameProgressWatchdog = TBPostFirstFrameProgressWatchdog()

    private enum CaptureStartResult {
        case started(attempt: UInt64)
        case cancelled
        case failed
    }

    nonisolated(unsafe) private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard let userInfo else { return }
        let service = Unmanaged<TBDisplaySenderSession>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                service.handleDisplayReconfiguration(displayID: displayID, flags: flags)
            }
        }
    }

    private final class CaptureDelegate: NSObject, SCStreamOutput, SCStreamDelegate {
        var onFrame: ((CMSampleBuffer) -> Void)?
        var onAudio: ((CMSampleBuffer) -> Void)?
        var onError: ((Error) -> Void)?
        var expectedDisplayID: CGDirectDisplayID = kCGNullDirectDisplay
        var captureDisplayID: CGDirectDisplayID = kCGNullDirectDisplay
        var requiresRasterExactCapture = false
        var expectedPixelWidth = 0
        var expectedPixelHeight = 0
        private var didLogFirstCompleteScreenFrame = false
        private var didLogIncompleteProofMetadata = false
        private var didFailRasterGate = false

        private static func number(_ value: Any?) -> Double? {
            if let value = value as? CGFloat { return Double(value) }
            if let value = value as? Double { return value }
            return (value as? NSNumber)?.doubleValue
        }

        private static func contentRect(_ value: Any?) -> CGRect? {
            if let rect = value as? CGRect { return rect }
            guard let dictionary = value as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        }

        private static func approximatelyEqual(
            _ left: Double,
            _ right: Double,
            tolerance: Double = 0.001
        ) -> Bool {
            abs(left - right) <= tolerance
        }

        private func rasterGateAllows(_ sampleBuffer: CMSampleBuffer) -> Bool {
            guard requiresRasterExactCapture else { return true }
            guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer,
                    createIfNecessary: false
                  ) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentArray.first,
                  let rawStatus = attachments[SCStreamFrameInfo.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else {
                return false
            }

            guard let contentRect = Self.contentRect(
                    attachments[SCStreamFrameInfo.contentRect]
                  ),
                  let scaleFactor = Self.number(
                    attachments[SCStreamFrameInfo.scaleFactor]
                  ),
                  let contentScale = Self.number(
                    attachments[SCStreamFrameInfo.contentScale]
                  )
            else {
                if !didLogIncompleteProofMetadata {
                    didLogIncompleteProofMetadata = true
                    NSLog(
                        "[capture-proof] metadata=INCOMPLETE first complete frame " +
                        "missing ScreenCaptureKit geometry metadata; waiting for a complete proof frame"
                    )
                }
                return false
            }

            // This one-shot proof record is intentionally emitted before the
            // frame enters the encoder. A 5120x2880 buffer alone is not enough:
            // ScreenCaptureKit can scale content into a requested buffer. Keep
            // the raw frame geometry alongside the active CG mode so a live
            // acceptance test can prove full-display 2x capture with no crop,
            // letterbox, or hidden rescale.
            let mode = captureDisplayID == kCGNullDirectDisplay
                ? nil
                : CGDisplayCopyDisplayMode(captureDisplayID)
            let modeText = mode.map {
                let refresh = String(format: "%.2f", $0.refreshRate)
                return "\($0.width)x\($0.height) points -> \($0.pixelWidth)x\($0.pixelHeight) pixels @\(refresh)Hz"
            } ?? "unavailable"
            let contentRectText = String(
                format: "x=%.3f y=%.3f w=%.3f h=%.3f",
                contentRect.origin.x,
                contentRect.origin.y,
                contentRect.size.width,
                contentRect.size.height
            )
            let scaleFactorText = String(format: "%.6f", scaleFactor)
            let contentScaleText = String(format: "%.6f", contentScale)
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
            let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
            let primaries = CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                nil
            ) as? String ?? "missing"
            let transfer = CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                nil
            ) as? String ?? "missing"

            let rasterExact = mode.map {
                expectedDisplayID != kCGNullDirectDisplay &&
                expectedDisplayID == captureDisplayID &&
                expectedPixelWidth > 0 &&
                expectedPixelHeight > 0 &&
                bufferWidth == expectedPixelWidth &&
                bufferHeight == expectedPixelHeight &&
                pixelFormat == kCVPixelFormatType_32BGRA &&
                $0.pixelWidth == bufferWidth &&
                $0.pixelHeight == bufferHeight &&
                Self.approximatelyEqual(Double(contentRect.origin.x), 0) &&
                Self.approximatelyEqual(Double(contentRect.origin.y), 0) &&
                Self.approximatelyEqual(Double(contentRect.size.width), Double($0.width)) &&
                Self.approximatelyEqual(Double(contentRect.size.height), Double($0.height)) &&
                Self.approximatelyEqual(
                    Double(contentRect.size.width) * scaleFactor,
                    Double(bufferWidth)
                ) &&
                Self.approximatelyEqual(
                    Double(contentRect.size.height) * scaleFactor,
                    Double(bufferHeight)
                ) &&
                Self.approximatelyEqual(contentScale, 1.0)
            } ?? false

            if !didLogFirstCompleteScreenFrame || !rasterExact {
                didLogFirstCompleteScreenFrame = true
                NSLog(
                    "[capture-proof] metadata=COMPLETE rasterExact=%d " +
                    "expectedDisplay=%u captureDisplay=%u activeMode=%@ " +
                    "expectedBuffer=%dx%d buffer=%zux%zu pixelFormat=0x%08x bgra=%d " +
                    "scaleFactor=%@ contentScale=%@ contentRect={%@} " +
                    "primaries=%@ transfer=%@",
                    rasterExact ? 1 : 0,
                    expectedDisplayID,
                    captureDisplayID,
                    modeText,
                    expectedPixelWidth,
                    expectedPixelHeight,
                    bufferWidth,
                    bufferHeight,
                    pixelFormat,
                    pixelFormat == kCVPixelFormatType_32BGRA ? 1 : 0,
                    scaleFactorText,
                    contentScaleText,
                    contentRectText,
                    primaries,
                    transfer
                )
            }

            if !rasterExact && !didFailRasterGate {
                didFailRasterGate = true
                onError?(NSError(
                    domain: "TargetBridgeCapture",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "lossless 5K capture failed the raster-exact geometry gate"]
                ))
            }
            return rasterExact
        }

        private static func shouldProcessFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: rawStatus)
            else {
                return true
            }

            switch status {
            case .complete, .started:
                return true
            case .idle, .blank, .suspended, .stopped:
                return false
            @unknown default:
                return true
            }
        }

        nonisolated func stream(_ stream: SCStream,
                                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                                of type: SCStreamOutputType) {
            if type == .audio {
                onAudio?(sampleBuffer)
                return
            }
            guard type == .screen else { return }
            guard Self.shouldProcessFrame(sampleBuffer) else { return }
            guard rasterGateAllows(sampleBuffer) else { return }
            onFrame?(sampleBuffer)
        }

        nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
            onError?(error)
        }
    }

    private func setStatus(_ state: TBDisplaySenderStatusState) {
        statusState = state
        statusText = state.text(language)
    }

    private static func probeHEVCHardwareEncoderSupport() -> Bool {
        if let cachedSupportsHEVCHardwareEncode {
            return cachedSupportsHEVCHardwareEncode
        }

        let encoderSpecification: CFDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ] as CFDictionary

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 1920,
            height: 1080,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let session {
            VTCompressionSessionInvalidate(session)
        }

        let supported = status == noErr
        cachedSupportsHEVCHardwareEncode = supported
        return supported
    }

    private func resolvedCodecType(for preset: TBDisplayCapturePreset, profile: TBMonitorDisplayProfile?) -> CMVideoCodecType {
        switch preset {
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            let receiverSupportsHEVC = profile?.supportsHEVCDecode ?? receiverSupportsHEVCDecodeHint ?? false
            if receiverSupportsHEVC, Self.probeHEVCHardwareEncoderSupport() {
                return kCMVideoCodecType_HEVC
            }
            return kCMVideoCodecType_H264
        case .crisp2160p60, .retina4k60, .native5k, .native5k60Experimental:
            return preset.codecType
        }
    }

    private func codecName(for codecType: CMVideoCodecType) -> String {
        codecType == kCMVideoCodecType_HEVC ? "HEVC" : "H.264"
    }

    private func refreshLocalizedText() {
        statusText = statusState.text(language)
        streamResolutionText = TBDisplaySenderL10n.streamSummary(
            preset: capturePreset,
            source: captureSource,
            language: language,
            codecName: activeCodecName
        )

        if let profile = activeProfile {
            receiverPanelText = TBDisplaySenderL10n.receiverSummary(profile, language: language)
        } else {
            receiverPanelText = TBDisplaySenderL10n.waitingReceiverProfile(language)
        }

        if session.displayID != kCGNullDirectDisplay, !session.displayName.isEmpty {
            virtualDisplayText = TBDisplaySenderL10n.virtualDisplaySummary(
                name: session.displayName,
                id: session.displayID,
                language: language
            )
        } else {
            virtualDisplayText = TBDisplaySenderL10n.virtualDisplayNotCreated(language)
        }

        if captureDisplayText.isEmpty
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.italian)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.english)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.german)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.french)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.chinese) {
            captureDisplayText = TBDisplaySenderL10n.captureDisplayNotAvailable(language)
        }

        if displayStateText.isEmpty
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.italian)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.english)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.german)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.french)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.chinese) {
            displayStateText = TBDisplaySenderL10n.displayStateNotAvailable(language)
        }
    }

    private func formattedCaptureErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        let details = "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
        let permissionGranted = CGPreflightScreenCaptureAccess()
        let lowered = nsError.localizedDescription.lowercased()

        if !permissionGranted {
            return TBDisplaySenderL10n.missingScreenRecordingPermission(language: language)
        }

        if lowered.contains("denied")
            || lowered.contains("not authorized")
            || lowered.contains("permission")
            || lowered.contains("tcc") {
            return TBDisplaySenderL10n.screenCaptureKitPermissionMismatch(details: details, language: language)
        }

        return details
    }

    func connect() {
        guard connection == nil, !receiverIP.isEmpty, !localInterfaceIP.isEmpty else { return }
        connect(preservingPreProfileReconnectPolicy: false)
    }

    private func connect(preservingPreProfileReconnectPolicy: Bool) {
        guard connection == nil, !receiverIP.isEmpty, !localInterfaceIP.isEmpty else { return }
        if !preservingPreProfileReconnectPolicy {
            cancelPreProfileReconnect(resetPolicy: true)
        }
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        recvBuffer.removeAll(keepingCapacity: false)
        activeProfile = nil
        receiverSurfaceState = TBMonotonicBooleanState(value: true)
        lastSentSourceDisplayEpoch = nil
        lastAcknowledgedReceiverSurfaceEpoch = nil
        displayLifecycleTransitionGeneration &+= 1
        activeCodecType = nil
        activeCodecName = nil
        lastConnectionStateDetail = nil
        setStatus(.connecting(receiverDisplayName))

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.serviceClass = .interactiveVideo
        if let localPort = NWEndpoint.Port(rawValue: 0) {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localInterfaceIP), port: localPort)
        }

        // Scope link-local dials to the interface that owns the local IP.
        // requiredLocalEndpoint pins the source address but NOT the egress
        // interface — the routing table keeps 169.254/16 on the primary
        // interface (usually Wi-Fi), so an unscoped dial to a Thunderbolt
        // Bridge peer leaves via the wrong link and times out.
        let interfaces = TBConnectionDiagnostics.currentIPv4Interfaces()
        let interfaceSummary = interfaces
            .map { "\($0.name)=\($0.ip)" }
            .joined(separator: ",")
        TBLog.connection.info(
            "connect: IPv4 interfaces=\(interfaceSummary, privacy: .public)"
        )
        connectInterfaceName = TBConnectionDiagnostics.interfaceName(forLocalIP: localInterfaceIP, in: interfaces)
        let scopedHost = TBConnectionDiagnostics.scopedReceiverHost(
            receiverIP: receiverIP,
            localIP: localInterfaceIP,
            interfaces: interfaces
        )
        let dialHost: NWEndpoint.Host
        if scopedHost != receiverIP, let scopedAddress = IPv4Address(scopedHost) {
            dialHost = .ipv4(scopedAddress)
        } else {
            dialHost = NWEndpoint.Host(receiverIP)
        }
        TBLog.connection.info("connect: dialing \(scopedHost, privacy: .public):\(TBMonitorProtocol.port) from \(self.localInterfaceIP, privacy: .public) (\(self.connectInterfaceName ?? "unknown interface", privacy: .public)) transport=\(self.transportKind.rawValue, privacy: .public)")
        let conn = NWConnection(
            host: dialHost,
            port: NWEndpoint.Port(integerLiteral: TBMonitorProtocol.port),
            using: params
        )
        connection = conn

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor [weak self, weak conn] in
                guard let self, let conn, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.connectTimeoutWorkItem?.cancel()
                    self.connectTimeoutWorkItem = nil
                    self.isConnected = true
                    if !self.isCableTestConnection, self.activeProfile == nil {
                        _ = self.preProfileReconnectPolicy.handle(.tcpReadyWithoutProfile)
                    }
                    TBLog.connection.info("connect: ready — \(self.receiverIP, privacy: .public) via \(self.connectInterfaceName ?? "?", privacy: .public)")
                    self.setStatus(.waitingDisplayProfile)
                    self.startHeartbeat()
                    self.sendHello()
                    self.sendInputControlModeUpdate()
                    self.sendBrightnessUpdate()
                    self.sendVolumeUpdate()
                    self.receiveLoop(on: conn)
                    self.startDisplayProfileWatchdog(for: conn)
                case .waiting(let error):
                    // The dial cannot proceed yet (no route, host down, cable
                    // unplugged, firewall drop, …). Record and log the real
                    // reason so a later timeout can report it instead of a
                    // bare "Connection timed out".
                    self.lastConnectionStateDetail = "waiting(\(error.localizedDescription))"
                    TBLog.connection.warning("connect: waiting — \(error.localizedDescription, privacy: .public)")
                case .failed(let error):
                    self.lastConnectionStateDetail = "failed(\(error.localizedDescription))"
                    let detail = TBConnectionDiagnostics.failureDetail(
                        receiverHost: self.receiverIP,
                        port: TBMonitorProtocol.port,
                        localIP: self.localInterfaceIP,
                        interfaceName: self.connectInterfaceName,
                        transport: self.transportKind.rawValue,
                        lastNetworkState: nil
                    )
                    TBLog.connection.error("connect: failed — \(error.localizedDescription, privacy: .public); \(detail, privacy: .public)")
                    if self.requestPreProfileReconnect(
                        after: .retryConnectionFailedOrTimedOut,
                        teardownReason: "sender_pre_profile_connect_failed"
                    ) {
                        return
                    }
                    self.setStatus(.connectionFailed("\(error.localizedDescription) — \(detail)"))
                    self.stop(resetStatusTo: nil)
                case .cancelled:
                    self.isConnected = false
                default:
                    break
                }
            }
        }

        startConnectWatchdog()
        conn.start(queue: connectionQueue)
    }

    func startCableTest() {
        guard !isCableTesting, !isConnected, !receiverIP.isEmpty else { return }
        isCableTesting = true
        cableTestResult = nil
        isCableTestConnection = true
        connect()
    }

    private func performCableTest() async throws -> Double {
        guard let conn = connection else {
            throw NSError(domain: "TBDisplaySenderService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No connection"])
        }

        let totalBytes: Int64 = 20 * 1000 * 1000 * 1000
        let chunkSize = 4 * 1000 * 1000
        let totalChunks = Int(totalBytes / Int64(chunkSize))

        // Pre-allocate the single test packet to avoid memory overhead
        var packet = Data()
        TBMonitorProtocol.appendBE32(&packet, UInt32(1 + chunkSize))
        packet.append(TBMonitorPacketType.testData.rawValue)
        packet.append(Data(repeating: 0, count: chunkSize))

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let startTime = DispatchTime.now()
                let condition = NSCondition()

                let lock = NSLock()
                var sendError: Error?
                var resumed = false
                var inFlightCount = 0

                func finish(with error: Error?) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        let endTime = DispatchTime.now()
                        let nanoTime = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
                        let timeInSeconds = Double(nanoTime) / 1_000_000_000.0

                        // 20 GB = 20,000,000,000 bytes = 160,000,000,000 bits
                        // Decimal Gigabits = bits / 1,000,000,000
                        let totalBits = Double(totalBytes) * 8.0
                        let rate = totalBits / 1_000_000_000.0 / timeInSeconds
                        continuation.resume(returning: rate)
                    }
                }

                for _ in 0..<totalChunks {
                    lock.lock()
                    let err = sendError
                    lock.unlock()
                    if err != nil {
                        break
                    }

                    condition.lock()
                    while inFlightCount >= 8 {
                        lock.lock()
                        let errCheck = sendError
                        lock.unlock()
                        if errCheck != nil {
                            break
                        }
                        condition.wait()
                    }

                    lock.lock()
                    let errCheck2 = sendError
                    lock.unlock()
                    if errCheck2 != nil {
                        condition.unlock()
                        break
                    }

                    inFlightCount += 1
                    condition.unlock()

                    conn.send(content: packet, completion: .contentProcessed({ error in
                        if let error = error {
                            lock.lock()
                            if sendError == nil {
                                sendError = error
                            }
                            lock.unlock()
                        }

                        condition.lock()
                        inFlightCount -= 1
                        condition.broadcast()
                        condition.unlock()
                    }))
                }

                // Wait for all outstanding packets to complete (up to 3 seconds)
                let limitDate = Date().addingTimeInterval(3.0)
                condition.lock()
                while inFlightCount > 0 {
                    if !condition.wait(until: limitDate) {
                        break // Timed out
                    }
                }
                condition.unlock()

                lock.lock()
                let err = sendError
                lock.unlock()

                finish(with: err)
            }
        }
    }

    func stop(
        persistArrangement: Bool = true,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        TBSenderAutomation.suspendAutomaticReconnectAfterUserStop()
        stop(
            resetStatusTo: .stopped,
            persistArrangement: persistArrangement,
            teardownReason: "sender_user_stop",
            teardownCompletion: completion
        )
    }

    /// Internal retry stop. Unlike a GUI Stop, this must not disable the
    /// LaunchAgent marker that represents the user's monitor-mode choice.
    func stopForAutomaticReconnect() {
        stop(
            resetStatusTo: .stopped,
            persistArrangement: false,
            teardownReason: "sender_internal_stop"
        )
    }

    func persistExtendedDisplayArrangementSnapshot() {
        persistExtendedDisplayArrangementIfNeeded()
    }

    private func stop(
        resetStatusTo status: TBDisplaySenderStatusState?,
        persistArrangement: Bool = true,
        teardownReason: String = "sender_internal_stop",
        preservePreProfileReconnectPolicy: Bool = false,
        teardownCompletion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let connectionToClose = connection
        invalidateCaptureAttempt()
        if persistArrangement {
            persistExtendedDisplayArrangementIfNeeded()
        }
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        displayProfileTimeoutWorkItem?.cancel()
        displayProfileTimeoutWorkItem = nil
        if !preservePreProfileReconnectPolicy {
            cancelPreProfileReconnect(resetPolicy: true)
        }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        stopCaptureWatchdog()
        if let directDisplayStream {
            directDisplayStream.stop()
            self.directDisplayStream = nil
        }
        if let stream = scStream {
            if let delegate = captureDelegate {
                try? stream.removeStreamOutput(delegate, type: .screen)
                try? stream.removeStreamOutput(delegate, type: .audio)
            }
            stream.stopCapture(completionHandler: nil)
            scStream = nil
        }
        captureDelegate = nil
        endCaptureActivity()
        let pipelineStopOutcome = pipeline?.stop() ?? .stopped
        pipeline = nil
        releaseInjectedModifiersIfNeeded()
        remoteHeldModifierKeyCodes.removeAll()
        injectedLeftClickTracker.reset()
        suppressedTriggerKeyCode = nil
        connectionToClose?.stateUpdateHandler = nil
        connection = nil
        sendTeardownAndClose(
            reason: teardownReason,
            over: connectionToClose,
            completion: teardownCompletion
        )
        let currentSession = session
        Task { @MainActor in
            currentSession.destroy()
        }
        activeProfile = nil
        receiverSurfaceState = TBMonotonicBooleanState(value: true)
        lastSentSourceDisplayEpoch = nil
        lastAcknowledgedReceiverSurfaceEpoch = nil
        displayLifecycleTransitionGeneration &+= 1
        activeCodecType = nil
        activeCodecName = nil
        isConnected = false
        isStreaming = false
        isCableTesting = false
        isCableTestConnection = false
        if let status {
            setStatus(status)
        }
        refreshLocalizedText()
        liveMetrics.senderFPS = 0
        sentSnapshot = 0
        sessionAckSent = false
        baselineDisplayIDs = []
        cursorDisplayID = kCGNullDirectDisplay
        lastCursorPacket = nil
        captureDisplayText = TBDisplaySenderL10n.captureDisplayNotAvailable(language)
        displayStateText = TBDisplaySenderL10n.displayStateNotAvailable(language)
        requestProcessRecoveryIfNeeded(
            after: pipelineStopOutcome,
            context: "full pipeline stop"
        )
    }

    /// Recover the receiver's intentional wake-broker handoff without relying
    /// on LaunchAgent automation. Only a connection that previously reached
    /// TCP ready without a display profile can enter this path.
    @discardableResult
    private func requestPreProfileReconnect(
        after event: TBPreProfileReconnectPolicy.Event,
        teardownReason: String
    ) -> Bool {
        guard activeProfile == nil, !isCableTestConnection else { return false }

        switch preProfileReconnectPolicy.handle(event) {
        case .none:
            return false

        case .exhausted:
            TBLog.connection.error(
                "connect: pre-profile reconnect budget exhausted after \(TBPreProfileReconnectPolicy.retryDelays.count, privacy: .public) attempts"
            )
            return false

        case .retry(let retry):
            TBLog.connection.info(
                "connect: receiver wake handoff; retry \(retry.attempt, privacy: .public)/\(retry.maximumAttempts, privacy: .public) in \(retry.delay, privacy: .public)s"
            )
            setStatus(.connecting(receiverDisplayName))
            stop(
                resetStatusTo: nil,
                persistArrangement: false,
                teardownReason: teardownReason,
                preservePreProfileReconnectPolicy: true
            )

            preProfileReconnectGeneration &+= 1
            let generation = preProfileReconnectGeneration
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.preProfileReconnectGeneration == generation,
                          self.connection == nil,
                          self.activeProfile == nil
                    else { return }
                    self.preProfileReconnectWorkItem = nil
                    self.connect(preservingPreProfileReconnectPolicy: true)
                }
            }
            preProfileReconnectWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + retry.delay, execute: workItem)
            return true
        }
    }

    private func cancelPreProfileReconnect(resetPolicy: Bool) {
        preProfileReconnectGeneration &+= 1
        preProfileReconnectWorkItem?.cancel()
        preProfileReconnectWorkItem = nil
        if resetPolicy {
            _ = preProfileReconnectPolicy.handle(.stopped)
        }
    }

    /// A quarantined C encoder intentionally survives Swift teardown because a
    /// late Metal completion may still reach it. Once ordinary session cleanup
    /// is complete, terminate the poisoned process exactly once; the installed
    /// LaunchAgent's KeepAlive path can then start a clean process, and a manual
    /// launch exits instead of accumulating another quarantined encoder.
    @discardableResult
    private func requestProcessRecoveryIfNeeded(
        after outcome: TBVideoPipelineStopOutcome,
        context: String
    ) -> Bool {
        guard outcome.requiresProcessTermination else { return false }
        if TBDPCMEncoderProcessState.shared.claimTerminationIfPoisoned() {
            NSLog(
                "TargetBridge DPCM: quarantined encoder during %@; terminating poisoned process for recovery",
                context
            )
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
        return true
    }

    /// Stable per-receiver discriminator: the connection address when known
    /// (distinct per machine even when two identical iMacs report the same SDL
    /// display name), falling back to the receiver-reported name.
    private func receiverIdentityDiscriminator(for profile: TBMonitorDisplayProfile) -> String {
        // Bonjour keeps the service name stable across Thunderbolt link-local IP
        // changes. Using the address here made macOS forget a receiver's virtual
        // display identity and saved placement after a wake or reconnect.
        if let receiver = TBDisplaySenderService.shared.discoveredReceivers.first(where: {
            $0.id == selectedReceiverID ||
            $0.preferredIP == receiverIP ||
            $0.thunderboltIP == receiverIP ||
            $0.networkIP == receiverIP
        }) {
            return receiver.stableIdentity
        }

        let selectedID = selectedReceiverID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let serviceName = selectedID.split(separator: "|", maxSplits: 1).first,
           !serviceName.isEmpty {
            return "service:\(serviceName)"
        }

        if let host = shortHostName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return "host:\(host)"
        }

        let receiverName = profile.receiverName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !receiverName.isEmpty {
            return "receiver:\(receiverName)"
        }

        return "address:\(receiverIP.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Key used to derive the extended-desktop virtual display identity. Shares
    /// the same receiver discriminator as the saved-arrangement key so a given
    /// receiver maps to one stable virtual display identity across reconnects.
    private func extendedDisplayIdentityKey(for profile: TBMonitorDisplayProfile) -> String {
        "\(receiverIdentityDiscriminator(for: profile))|\(profile.panelWidth)x\(profile.panelHeight)"
    }

    private func extendedArrangementDefaultsKey(for profile: TBMonitorDisplayProfile) -> String {
        let normalizedIdentity = receiverIdentityDiscriminator(for: profile).replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        )
        return "\(Self.extendedArrangementDefaultsPrefix).\(normalizedIdentity).\(profile.panelWidth)x\(profile.panelHeight)"
    }

    private func loadSavedExtendedDisplayArrangement(for profile: TBMonitorDisplayProfile) -> SavedExtendedDisplayArrangement? {
        let key = extendedArrangementDefaultsKey(for: profile)
        guard let stored = UserDefaults.standard.dictionary(forKey: key) else {
            return nil
        }

        if let dx = stored["dx"] as? Int,
           let dy = stored["dy"] as? Int {
            return SavedExtendedDisplayArrangement(
                x: Int32(dx),
                y: Int32(dy),
                isRelativeToMainDisplay: true
            )
        }

        guard let x = stored["x"] as? Int,
              let y = stored["y"] as? Int
        else {
            return nil
        }
        return SavedExtendedDisplayArrangement(
            x: Int32(x),
            y: Int32(y),
            isRelativeToMainDisplay: false
        )
    }

    private func persistExtendedDisplayArrangementIfNeeded() {
        guard captureSource == .extendedDesktop,
              let profile = activeProfile,
              session.displayID != kCGNullDirectDisplay,
              CGDisplayIsInMirrorSet(session.displayID) == 0
        else { return }

        let bounds = CGDisplayBounds(session.displayID)
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let key = extendedArrangementDefaultsKey(for: profile)
        let payload: [String: Int] = [
            "dx": Int((bounds.origin.x - mainBounds.origin.x).rounded()),
            "dy": Int((bounds.origin.y - mainBounds.origin.y).rounded()),
            "x": Int(bounds.origin.x.rounded()),
            "y": Int(bounds.origin.y.rounded())
        ]
        UserDefaults.standard.set(payload, forKey: key)
    }

    private func sendHello() {
        let name = Host.current().localizedName ?? "MacBook"
        let preset = capturePreset
        let helloCodecType = resolvedCodecType(for: preset, profile: activeProfile)
        // The first HELLO precedes the receiver capability profile. Report the
        // requested wire transport then; the second HELLO, sent after profile
        // negotiation, reports the capability-gated transport actually used.
        let helloUsesDPCM = activeProfile.map { dpcmEnabled(for: $0) }
            ?? dpcmRequestedByEnvironment()
        let helloUsesRawNV12 = activeProfile.map {
            !helloUsesDPCM && rawNV12Enabled(for: $0)
        } ?? (!helloUsesDPCM && rawNV12RequestedByEnvironment())
        let helloCodecName = TBMonitorCodecLabel.resolve(
            usesDPCM: helloUsesDPCM,
            usesRawNV12: helloUsesRawNV12,
            encodedCodecName: codecName(for: helloCodecType)
        )
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .helloReceiver,
            value: TBMonitorHelloReceiver(
                senderName: name,
                uiLanguage: language.fileStem,
                capturePreset: preset.title,
                captureSource: captureSource.title(language),
                captureWidth: preset.width,
                captureHeight: preset.height,
                codec: helloCodecName
            )
        ) else { return }
        send(packet)
    }

    private func sendInputControlModeUpdate() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .inputControlMode,
            value: TBMonitorInputControlMode(mode: inputControlRole.rawValue)
        ) else { return }
        TBInputDebugLog.log("sender send control mode update \(inputControlRole.rawValue) to \(receiverIP)")
        send(packet)
    }

    private func sendBrightnessUpdate() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .brightness,
            value: TBMonitorBrightness(level: brightness)
        ) else { return }
        send(packet)
    }

    private func applyReportedDisplayTweaks(_ tweaks: TBMonitorDisplayTweaks) {
        guard nightShiftEnabled != tweaks.nightShift || trueToneEnabled != tweaks.trueTone else { return }
        adoptingReportedTweaks = true
        nightShiftEnabled = tweaks.nightShift
        trueToneEnabled = tweaks.trueTone
        adoptingReportedTweaks = false
    }

    private func sendDisplayTweaks() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .displayTweaks,
            value: TBMonitorDisplayTweaks(nightShift: nightShiftEnabled, trueTone: trueToneEnabled)
        ) else { return }
        send(packet)
    }

    private func sendVolumeUpdate() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .volume,
            value: TBMonitorVolume(level: volume)
        ) else { return }
        send(packet)
    }

    func sendClipboardText(_ text: String) {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .clipboard,
            value: TBMonitorClipboard(text: text)
        ) else { return }
        send(packet)
    }

    private func sendHeartbeat() {
        heartbeatSequence += 1
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .heartbeat,
            value: TBMonitorHeartbeat(sequence: heartbeatSequence)
        ) else { return }
        send(packet)
    }

    private func sendSourceDisplayStateIfNeeded(force: Bool = false) {
        guard activeProfile?.supportsDisplayLifecycle == true else { return }
        guard force ||
                lastSentSourceDisplayEpoch != sourceDisplayState.epoch ||
                lastAcknowledgedReceiverSurfaceEpoch != receiverSurfaceState.epoch
        else { return }
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .sourceDisplayState,
            value: TBMonitorSourceDisplayState(
                awake: sourceDisplayState.value,
                epoch: sourceDisplayState.epoch,
                receiverEpoch: receiverSurfaceState.epoch
            )
        ) else { return }
        send(packet)
        lastSentSourceDisplayEpoch = sourceDisplayState.epoch
        lastAcknowledgedReceiverSurfaceEpoch = receiverSurfaceState.epoch
    }

    private func sendTeardownAndClose(
        reason: String,
        over connection: NWConnection?,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let connection else {
            completion?()
            return
        }
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .teardown,
            value: TBMonitorTeardown(reason: reason)
        ) else {
            connection.cancel()
            completion?()
            return
        }

        // Preserve the explicit user/internal reason before closing the socket.
        // Otherwise the Receiver cannot distinguish Stop from a dropped cable.
        connection.send(
            content: packet,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
                guard let completion else { return }
                Task { @MainActor in completion() }
            }
        )
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
            connection.cancel()
        }
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isDone, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.recvBuffer.append(data)
                    self.drainPackets()
                }
                if error != nil || isDone {
                    if self.activeProfile == nil,
                       self.requestPreProfileReconnect(
                           after: .connectionEndedBeforeProfile,
                           teardownReason: "sender_pre_profile_connection_ended"
                       ) {
                        return
                    }
                    if let error {
                        self.setStatus(.connectionClosed(error.localizedDescription))
                    } else if self.activeProfile == nil {
                        self.setStatus(.connectionClosed("Receiver closed before providing a display profile"))
                    } else if case .startingCapture = self.statusState {
                        self.setStatus(.receiverClosedDuringCapture)
                    } else if case .captureActive = self.statusState {
                        self.setStatus(.receiverClosedConnection)
                    }
                    self.stop(resetStatusTo: nil)
                    return
                }
                self.receiveLoop(on: connection)
            }
        }
    }

    private func drainPackets() {
        do {
            try drainPacketsOrThrow()
        } catch {
            // Corrupt length prefix: the framing is unrecoverable, so tear the
            // connection down instead of buffering inbound data forever.
            TBLog.connection.error("corrupt inbound stream (\(String(describing: error), privacy: .public)); closing connection")
            recvBuffer.removeAll(keepingCapacity: false)
            setStatus(.connectionClosed(String(describing: error)))
            stop(resetStatusTo: nil)
        }
    }

    private func drainPacketsOrThrow() throws {
        while let (type, payload) = try TBMonitorProtocol.drainPacket(from: &recvBuffer) {
            switch type {
            case .displayProfile:
                handleDisplayProfile(payload)
            case .receiverSurfaceState:
                if let state = TBMonitorProtocol.decodeJSON(
                    TBMonitorReceiverSurfaceState.self,
                    from: payload
                ) {
                    handleReceiverSurfaceState(state)
                }
            case .inputEvent:
                if inputControlRole == .receiverMaster,
                   let event = TBMonitorProtocol.decodeJSON(TBMonitorInputEvent.self, from: payload) {
                    receivedInputEventCount += 1
                    if receivedInputEventCount <= 20 || receivedInputEventCount.isMultiple(of: 100) {
                        TBInputDebugLog.log("sender received #\(receivedInputEventCount) kind=\(event.kind) dx=\(event.dx ?? 0) dy=\(event.dy ?? 0) sx=\(event.scrollX ?? 0) sy=\(event.scrollY ?? 0) key=\(event.keyCode ?? 0)")
                    }
                    if event.kind == "switchPrevTarget" {
                        releaseInjectedModifiersIfNeeded()
                        onRemoteSwitchRequest?(-1)
                    } else if event.kind == "switchNextTarget" {
                        releaseInjectedModifiersIfNeeded()
                        onRemoteSwitchRequest?(1)
                    } else if event.kind == "switchPrevSpace" {
                        releaseInjectedModifiersIfNeeded()
                        postLocalSpaceSwitch(direction: -1)
                    } else if event.kind == "switchNextSpace" {
                        releaseInjectedModifiersIfNeeded()
                        postLocalSpaceSwitch(direction: 1)
                    } else if event.kind == "deactivateInputControl" {
                        releaseInjectedModifiersIfNeeded()
                        onRemoteDeactivateInputRequest?()
                    } else {
                        applyIncomingInputEvent(event, payload: payload)
                    }
                }
            case .heartbeat:
                break
            case .teardown:
                setStatus(.receiverTerminatedSession)
                stop(resetStatusTo: nil)
                return
            case .displayTweaks:
                // Receiver reporting its real state (it may have been changed on
                // that Mac directly). Adopt it without sending anything back —
                // the didSet observers would otherwise bounce it straight to the
                // receiver and the two could ping-pong.
                if let tweaks = TBMonitorProtocol.decodeJSON(TBMonitorDisplayTweaks.self, from: payload) {
                    applyReportedDisplayTweaks(tweaks)
                }
            case .clipboard:
                if let clipboard = TBMonitorProtocol.decodeJSON(TBMonitorClipboard.self, from: payload) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(clipboard.text, forType: .string)
                }
            default:
                break
            }
        }
    }

    private func currentLocalMouseLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    // Bounds of every active display, in the Quartz global coordinate space
    // (top-left origin) — matching CGEvent locations and CGWarpMouseCursorPosition.
    // NSScreen.frame uses AppKit's bottom-left origin and must not be mixed in here.
    private func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private func screenFrame(containing point: CGPoint) -> CGRect? {
        activeDisplayBounds().first(where: { $0.contains(point) })
    }

    private func clampedMouseTarget(from current: CGPoint, dx: Int, dy: Int) -> CGPoint {
        let rawTarget = CGPoint(x: current.x + CGFloat(dx), y: current.y + CGFloat(dy))
        let displays = activeDisplayBounds()
        guard !displays.isEmpty else { return rawTarget }

        // If the target lands on any display, allow it unchanged. This lets the
        // relayed cursor cross from one screen onto an adjacent one (e.g. the
        // receiver-backed virtual extended display), matching how the pointer
        // behaves with the local touchpad. Clamping to a single screen's bounds
        // previously trapped the pointer on the sender's main display (issue #97).
        if displays.contains(where: { $0.contains(rawTarget) }) {
            return rawTarget
        }

        // Off every display: keep the pointer on the display it is currently on so
        // the injected cursor can never get lost in a gap between displays.
        let frame = displays.first(where: { $0.contains(current) }) ?? displays[0]
        let minX = frame.minX
        let maxX = frame.maxX - 1
        let minY = frame.minY
        let maxY = frame.maxY - 1

        return CGPoint(
            x: min(max(rawTarget.x, minX), maxX),
            y: min(max(rawTarget.y, minY), maxY)
        )
    }

    private func localInputEventSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }

    private func logLocalInputInjectionStateIfNeeded(context: String) {
        let trusted = AXIsProcessTrusted()
        TBInputDebugLog.log("sender input injection state trusted=\(trusted) context=\(context)")
    }

    private func postLocalMouseMove(dx: Int, dy: Int, type: CGEventType = .mouseMoved, button: CGMouseButton = .left) {
        logLocalInputInjectionStateIfNeeded(context: "mouseMove")
        guard let current = injectedRemoteMouseLocation ?? currentLocalMouseLocation() else { return }
        let target = clampedMouseTarget(from: current, dx: dx, dy: dy)
        injectedRemoteMouseLocation = target
        let shouldWarp = (type == .mouseMoved)
        if shouldWarp {
            CGWarpMouseCursorPosition(target)
        }
        guard let event = CGEvent(mouseEventSource: localInputEventSource(), mouseType: type, mouseCursorPosition: target, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.post(tap: .cghidEventTap)

        // Auto-hidden menu bar / Dock reveal on macOS depends on the pointer
        // really landing on a screen edge. A second edge-pinned move helps the
        // system treat relayed motion like a native "push against the border".
        if type == .mouseMoved,
           let frame = screenFrame(containing: target),
           target.x <= frame.minX || target.x >= frame.maxX - 1 ||
           target.y <= frame.minY || target.y >= frame.maxY - 1,
           let edgeEvent = CGEvent(mouseEventSource: localInputEventSource(), mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: button) {
            edgeEvent.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
            edgeEvent.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
            edgeEvent.post(tap: .cghidEventTap)
        }
    }

    private func postLocalMouseButton(type: CGEventType, button: CGMouseButton, clickCount: Int? = nil) {
        logLocalInputInjectionStateIfNeeded(context: "mouseButton")
        guard let current = injectedRemoteMouseLocation ?? currentLocalMouseLocation() else { return }
        guard let event = CGEvent(mouseEventSource: localInputEventSource(), mouseType: type, mouseCursorPosition: current, mouseButton: button) else { return }
        if let clickCount {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(min(max(clickCount, 1), 3)))
        } else if button == .left {
            let clickState: Int
            if type == .leftMouseDown {
                clickState = injectedLeftClickTracker.registerClick(
                    at: current,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    doubleClickInterval: NSEvent.doubleClickInterval
                )
            } else {
                clickState = max(injectedLeftClickTracker.currentClickState, 1)
            }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        event.post(tap: .cghidEventTap)
    }

    private func postLocalScroll(scrollX: Int, scrollY: Int) {
        logLocalInputInjectionStateIfNeeded(context: "scroll")
        guard let event = CGEvent(
            scrollWheelEvent2Source: localInputEventSource(),
            units: .line,
            wheelCount: 2,
            wheel1: Int32(scrollY),
            wheel2: Int32(scrollX),
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postLocalKey(keyCode: UInt16, isDown: Bool) {
        logLocalInputInjectionStateIfNeeded(context: "key")
        switch keyCode {
        case 54, 55: injectedCommandDown = isDown
        case 56, 60: injectedShiftDown = isDown
        case 58, 61: injectedOptionDown = isDown
        case 59, 62: injectedControlDown = isDown
        case 57: injectedCapsDown = isDown
        default: break
        }
        guard let event = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(keyCode), keyDown: isDown) else { return }
        event.flags = currentInjectedModifierFlags()
        event.post(tap: .cghidEventTap)
    }

    private func currentInjectedModifierFlags() -> CGEventFlags {
        var flags: CGEventFlags = []
        if injectedCommandDown {
            flags.insert(.maskCommand)
        }
        if injectedShiftDown {
            flags.insert(.maskShift)
        }
        if injectedOptionDown {
            flags.insert(.maskAlternate)
        }
        if injectedControlDown {
            flags.insert(.maskControl)
        }
        if injectedCapsDown {
            flags.insert(.maskAlphaShift)
        }
        return flags
    }

    private func releaseInjectedModifiersIfNeeded() {
        if injectedCommandDown {
            postLocalKey(keyCode: 55, isDown: false)
            injectedCommandDown = false
        }
        if injectedShiftDown {
            postLocalKey(keyCode: 56, isDown: false)
            injectedShiftDown = false
        }
        if injectedOptionDown {
            postLocalKey(keyCode: 58, isDown: false)
            injectedOptionDown = false
        }
        if injectedControlDown {
            postLocalKey(keyCode: 59, isDown: false)
            injectedControlDown = false
        }
        if injectedCapsDown {
            postLocalKey(keyCode: 57, isDown: false)
            injectedCapsDown = false
        }
    }

    private func postLocalSpaceSwitch(direction: Int) {
        logLocalInputInjectionStateIfNeeded(context: "spaceSwitch")

        let controlKeyCode: UInt16 = 59
        let arrowKeyCode: UInt16 = direction < 0 ? 123 : 124

        guard let controlDown = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(controlKeyCode), keyDown: true),
              let arrowDown = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(arrowKeyCode), keyDown: true),
              let arrowUp = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(arrowKeyCode), keyDown: false),
              let controlUp = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(controlKeyCode), keyDown: false)
        else {
            return
        }

        controlDown.flags = .maskControl
        arrowDown.flags = .maskControl
        arrowUp.flags = .maskControl
        controlUp.flags = []

        controlDown.post(tap: .cghidEventTap)
        arrowDown.post(tap: .cghidEventTap)
        arrowUp.post(tap: .cghidEventTap)
        controlUp.post(tap: .cghidEventTap)
    }

    private func applyIncomingInputEvent(_ event: TBMonitorInputEvent, payload: Data) {
        TBInputDebugLog.log("sender applying incoming event kind=\(event.kind)")
        switch event.kind {
        case "move":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0)
        case "leftDrag":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0, type: .leftMouseDragged, button: .left)
        case "rightDrag":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0, type: .rightMouseDragged, button: .right)
        case "otherDrag":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0, type: .otherMouseDragged, button: .center)
        case "leftDown":
            let buttonEvent = TBMonitorProtocol.decodeJSON(TBMonitorInputButtonEvent.self, from: payload)
            postLocalMouseButton(type: .leftMouseDown, button: .left, clickCount: buttonEvent?.clickCount)
        case "leftUp":
            let buttonEvent = TBMonitorProtocol.decodeJSON(TBMonitorInputButtonEvent.self, from: payload)
            postLocalMouseButton(type: .leftMouseUp, button: .left, clickCount: buttonEvent?.clickCount)
        case "rightDown":
            let buttonEvent = TBMonitorProtocol.decodeJSON(TBMonitorInputButtonEvent.self, from: payload)
            postLocalMouseButton(type: .rightMouseDown, button: .right, clickCount: buttonEvent?.clickCount)
        case "rightUp":
            let buttonEvent = TBMonitorProtocol.decodeJSON(TBMonitorInputButtonEvent.self, from: payload)
            postLocalMouseButton(type: .rightMouseUp, button: .right, clickCount: buttonEvent?.clickCount)
        case "otherDown":
            let buttonEvent = TBMonitorProtocol.decodeJSON(TBMonitorInputButtonEvent.self, from: payload)
            postLocalMouseButton(type: .otherMouseDown, button: .center, clickCount: buttonEvent?.clickCount)
        case "otherUp":
            let buttonEvent = TBMonitorProtocol.decodeJSON(TBMonitorInputButtonEvent.self, from: payload)
            postLocalMouseButton(type: .otherMouseUp, button: .center, clickCount: buttonEvent?.clickCount)
        case "scroll":
            postLocalScroll(scrollX: event.scrollX ?? 0, scrollY: event.scrollY ?? 0)
        case "keyDown":
            if let keyCode = event.keyCode {
                updateRemoteModifierState(keyCode: keyCode, isDown: true)
                if handleIncomingTriggerKeyDown(keyCode) { return }
                postLocalKey(keyCode: keyCode, isDown: true)
            }
        case "keyUp":
            if let keyCode = event.keyCode {
                updateRemoteModifierState(keyCode: keyCode, isDown: false)
                if keyCode == suppressedTriggerKeyCode {
                    suppressedTriggerKeyCode = nil
                    return
                }
                postLocalKey(keyCode: keyCode, isDown: false)
            }
        default:
            break
        }
    }

    /// receiverMaster: if the incoming key-down completes a binding trigger,
    /// inject the action locally and swallow the trigger. Returns true if handled.
    private func handleIncomingTriggerKeyDown(_ keyCode: UInt16) -> Bool {
        guard !TBInputBindingEngine.isModifierKeyCode(keyCode), !inputBindings.isEmpty else { return false }
        // Debounce key-repeat: ignore repeats while the trigger is still held.
        if keyCode == suppressedTriggerKeyCode { return true }
        let held = currentHeldModifierBits()
        guard let binding = TBInputBindingEngine.match(keyCode: keyCode, modifiers: held, in: inputBindings) else {
            return false
        }
        suppressedTriggerKeyCode = keyCode
        TBInputDebugLog.log("binding MATCH: trigger=\(binding.trigger.displayString) -> inject \(binding.action.displayString)")
        injectActionViaSystemEvents(binding.action)
        return true
    }

    /// Inject a binding action through System Events (AppleScript) rather than a
    /// raw CGEvent. The WindowServer ignores synthetic CGEvent presses for
    /// protected symbolic hotkeys (e.g. ⌃← to switch Spaces), but honors the same
    /// shortcut when it comes from the trusted System Events process.
    ///
    /// The user may be holding the trigger's modifiers, which we inject as held
    /// CGEvent state — that would contaminate the action (e.g. a stray ⌥). So we
    /// release the held modifiers first so System Events sees a clean combo. On
    /// completion, restore only modifiers that the receiver still holds.
    private func injectActionViaSystemEvents(_ action: TBInputShortcut) {
        let heldKeyCodes = currentlyHeldRemoteModifierKeyCodes()
        for keyCode in heldKeyCodes { postLocalKey(keyCode: keyCode, isDown: false) }

        // Run the AppleScript in-process (NSAppleScript), NOT via /usr/bin/osascript:
        // when spawned, osascript is the keystroke-sending client and lacks
        // Accessibility (error 1002). In-process, this app is the client and it
        // already holds Accessibility + Automation, so System Events is allowed
        // to post the shortcut.
        let source = "tell application \"System Events\" to key code \(action.keyCode)\(Self.appleScriptModifierClause(action.modifiers))"
        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            let failure: String? = errorInfo.map { "\($0)" }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let failure { TBInputDebugLog.log("system-events inject error: \(failure)") }
                guard self.inputControlRole == .receiverMaster else { return }
                for keyCode in self.currentlyHeldRemoteModifierKeyCodes() {
                    self.postLocalKey(keyCode: keyCode, isDown: true)
                }
            }
        }
    }

    private func updateRemoteModifierState(keyCode: UInt16, isDown: Bool) {
        guard TBInputBindingEngine.modifierBit(for: keyCode) != nil else { return }
        if isDown {
            remoteHeldModifierKeyCodes.insert(keyCode)
        } else {
            remoteHeldModifierKeyCodes.remove(keyCode)
        }
    }

    private func currentlyHeldRemoteModifierKeyCodes() -> [UInt16] {
        TBInputShortcut.modifierTable.compactMap { modifier in
            remoteHeldModifierKeyCodes.first {
                TBInputBindingEngine.modifierBit(for: $0) == modifier.bit
            }
        }
    }

    private static func appleScriptModifierClause(_ modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & TBInputShortcut.control != 0 { parts.append("control down") }
        if modifiers & TBInputShortcut.option  != 0 { parts.append("option down") }
        if modifiers & TBInputShortcut.shift   != 0 { parts.append("shift down") }
        if modifiers & TBInputShortcut.command != 0 { parts.append("command down") }
        guard !parts.isEmpty else { return "" }
        return " using {" + parts.joined(separator: ", ") + "}"
    }

    /// Current held modifier state (our bitmask) reconstructed from injected keys.
    private func currentHeldModifierBits() -> UInt32 {
        var m: UInt32 = 0
        if injectedControlDown { m |= TBInputShortcut.control }
        if injectedOptionDown  { m |= TBInputShortcut.option }
        if injectedShiftDown   { m |= TBInputShortcut.shift }
        if injectedCommandDown { m |= TBInputShortcut.command }
        return m
    }

    private func handleDisplayProfile(_ payload: Data) {
        guard activeProfile == nil,
              let profile = TBMonitorProtocol.decodeJSON(TBMonitorDisplayProfile.self, from: payload)
        else { return }

        displayProfileTimeoutWorkItem?.cancel()
        displayProfileTimeoutWorkItem = nil
        cancelPreProfileReconnect(resetPolicy: false)
        _ = preProfileReconnectPolicy.handle(.displayProfileReceived)
        activeProfile = profile
        if profile.supportsDisplayLifecycle == true {
            // A capable receiver must explicitly publish its current Aqua
            // surface before any capture work begins. Legacy profiles retain
            // the compatibility default established at connect().
            receiverSurfaceState = TBMonotonicBooleanState(value: false)
        }
        if let supportsHEVCDecode = profile.supportsHEVCDecode {
            receiverSupportsHEVCDecodeHint = supportsHEVCDecode
        }
        if let inputMonitoringTrusted = profile.inputMonitoringTrusted {
            receiverInputMonitoringTrustedHint = inputMonitoringTrusted
        }
        if let accessibilityTrusted = profile.accessibilityTrusted {
            receiverAccessibilityTrustedHint = accessibilityTrusted
        }
        receiverSupportsNightShift = profile.supportsNightShift ?? false
        receiverSupportsTrueTone = profile.supportsTrueTone ?? false
        receiverPanelText = TBDisplaySenderL10n.receiverSummary(profile, language: language)
        lastSentSourceDisplayEpoch = nil
        sendHello()
        sendSourceDisplayStateIfNeeded(force: true)
        sendInputControlModeUpdate()
        sendBrightnessUpdate()
        sendVolumeUpdate()

        Task { @MainActor in
            if self.isCableTestConnection {
                self.setStatus(.testingCable)
                do {
                    let rate = try await self.performCableTest()
                    self.cableTestResult = rate
                } catch {
                    NSLog("TargetBridge: cable test failed: \(error)")
                    self.stop(resetStatusTo: .connectionFailed(error.localizedDescription))
                    return
                }
                self.isCableTestConnection = false
                self.isCableTesting = false
                self.stop(resetStatusTo: .stopped)
                return
            }

            // A headless Sender may still expose a sleeping physical display.
            // Wake and hold the graphical session before virtual display setup.
            self.beginCaptureActivity(wakeDisplay: self.shouldProduceDisplayFrames)
            self.setStatus(.creatingVirtualDisplay)
            self.baselineDisplayIDs = self.captureSource == .extendedDesktop
                ? await self.fetchShareableDisplayIDs()
                : []
            let receiverKey = self.extendedDisplayIdentityKey(for: profile)
            let modeOverride: TBVirtualDisplayModeSize? = (self.matchRenderToStream && self.captureSource == .extendedDesktop)
                ? self.capturePreset.renderMatchedDisplayMode
                : nil
            if let modeOverride {
                NSLog(
                    "TargetBridge: render matching on, virtual display mode %dx%d (backing %dx%d) for %dx%d stream",
                    modeOverride.width, modeOverride.height,
                    modeOverride.backingWidth, modeOverride.backingHeight,
                    self.capturePreset.width, self.capturePreset.height
                )
            }
            guard self.session.create(
                from: profile,
                refreshRate: self.capturePreset.virtualDisplayRefreshRate,
                modeOverride: modeOverride,
                identity: self.captureSource.virtualDisplayIdentity(receiverKey: receiverKey),
                receiverKey: receiverKey
            ) else {
                self.setStatus(.virtualDisplayCreationFailed)
                self.stop(resetStatusTo: nil)
                return
            }
            guard await self.session.waitForPreferredModeActivation() else {
                TBLog.connection.error(
                    "capture: refusing to start because the exact requested Retina backing mode did not activate"
                )
                self.setStatus(.virtualDisplayCreationFailed)
                self.stop(resetStatusTo: nil)
                return
            }
            if self.captureSource == .desktopMirror {
                if CGDisplayIsInMirrorSet(self.session.displayID) == 0 {
                    let displayReady = await self.waitForOnlineDisplay(self.session.displayID)
                    let mirrorConfigured = displayReady && self.configureDesktopMirror(for: self.session.displayID)
                    if !mirrorConfigured {
                        NSLog(
                            "TargetBridge: unable to enable mirror mode for virtual display %u on first attempt; scheduling retry",
                            self.session.displayID
                        )
                    }
                }
            }
            self.virtualDisplayText = TBDisplaySenderL10n.virtualDisplaySummary(
                name: self.session.displayName,
                id: self.session.displayID,
                language: self.language
            )
            self.displayStateText = self.describeDisplayState(for: self.session.displayID)

            // Reset the first-frame flag BEFORE capture starts. startCapture() is
            // async and frames can begin flowing (firing handleFirstEncodedFrame,
            // which sets sessionAckSent = true) during its suspension. Resetting
            // afterward would clobber that true back to false, leaving the watchdog
            // armed against a session that has already delivered frames — it then
            // tears down a healthy stream ~4s in. See onFirstFrame wiring below.
            self.sessionAckSent = false
            self.captureBlockedByScreenRecordingPermission = false
            if self.shouldProduceDisplayFrames {
                await self.resumeCaptureForDisplayLifecycle(
                    profile: profile,
                    reason: "initial receiver readiness"
                )
            } else {
                // Keep the receiver-backed virtual display (and therefore the
                // user's native arrangement) alive while capture/GPU/network
                // frame production remains stopped.
                self.endCaptureActivity()
                self.setStatus(.startingCapture(
                    self.capturePreset.description,
                    self.captureSource
                ))
                self.scheduleDisplayLifecycleReconciliation(
                    reason: "initial receiver surface unavailable"
                )
            }
        }
    }

    private func beginCaptureAttempt() -> (generation: UInt64, gate: TBCaptureAttemptGate) {
        captureAttemptGate?.deactivate()
        captureAttemptGeneration &+= 1
        if captureAttemptGeneration == 0 { captureAttemptGeneration = 1 }
        captureAttemptFirstFrameSeen = false
        let gate = TBCaptureAttemptGate()
        captureAttemptGate = gate
        return (captureAttemptGeneration, gate)
    }

    private func invalidateCaptureAttempt() {
        captureAttemptGate?.deactivate()
        captureAttemptGate = nil
        captureAttemptGeneration &+= 1
        if captureAttemptGeneration == 0 { captureAttemptGeneration = 1 }
        captureAttemptFirstFrameSeen = false
    }

    private func captureAttemptIsCurrent(
        _ attempt: UInt64,
        gate: TBCaptureAttemptGate,
        connection expectedConnection: NWConnection
    ) -> Bool {
        captureAttemptGeneration == attempt &&
            captureAttemptGate === gate &&
            gate.isActive &&
            connection === expectedConnection &&
            shouldProduceDisplayFrames
    }

    private func abandonCaptureStart(
        pipeline candidate: TBVideoPipeline,
        gate: TBCaptureAttemptGate
    ) {
        gate.deactivate()
        if pipeline === candidate {
            _ = candidate.stop()
            pipeline = nil
        }
    }

    private func startCapture(for profile: TBMonitorDisplayProfile) async -> CaptureStartResult {
        do {
            guard CGPreflightScreenCaptureAccess() else {
                captureBlockedByScreenRecordingPermission = true
                _ = CGRequestScreenCaptureAccess()
                setStatus(.captureDesktopError(
                    TBDisplaySenderL10n.missingScreenRecordingPermission(language: language)
                ))
                TBLog.connection.error("capture: screen recording permission missing; automatic reconnect suspended")
                return .failed
            }

            let preset = capturePreset
            let dpcmRequired = dpcmRequestedByEnvironment()
            guard !dpcmRequired || profile.supportsDPCM == true else {
                setStatus(.captureDesktopError(
                    "The receiver withdrew lossless DPCM capability; refusing a lower-quality fallback."
                ))
                TBLog.connection.error(
                    "capture: DPCM was required but receiver capability is unavailable; refusing codec fallback"
                )
                return .failed
            }
            let usesDPCM = dpcmEnabled(for: profile)
            let usesRawNV12 = !usesDPCM && rawNV12Enabled(for: profile)
            let codecType = resolvedCodecType(for: preset, profile: profile)
            let codecName = TBMonitorCodecLabel.resolve(
                usesDPCM: usesDPCM,
                usesRawNV12: usesRawNV12,
                encodedCodecName: self.codecName(for: codecType)
            )
            activeCodecType = (usesDPCM || usesRawNV12) ? nil : codecType
            activeCodecName = codecName
            guard let connection else { return .failed }
            let captureAttempt = beginCaptureAttempt()
            let attempt = captureAttempt.generation
            let attemptGate = captureAttempt.gate

            // The encode/send pipeline runs entirely on its own serial queue,
            // off the main thread, so SwiftUI layout can never stall frame
            // delivery. Preset/dimensions/codec are immutable for a session
            // (the pickers are disabled while streaming), so we capture them once.
            let pipeline = TBVideoPipeline(
                preset: preset,
                codecType: codecType,
                connection: connection,
                displayName: session.displayName,
                displayID: session.displayID,
                usesDPCM: usesDPCM,
                usesRawNV12: usesRawNV12,
                ackAlreadySent: sessionAckSent,
                attemptGate: attemptGate,
                onFirstFrame: { [weak self] in
                    Task { @MainActor in
                        self?.handleFirstEncodedFrame(attempt: attempt)
                    }
                }
            )
            guard pipeline.start() else {
                attemptGate.deactivate()
                return .failed
            }
            self.pipeline = pipeline
            TBLog.connection.info("capture: pipeline started preset=\(preset.rawValue, privacy: .public) source=\(String(describing: self.captureSource), privacy: .public) codec=\(codecName, privacy: .public) dpcm=\(usesDPCM, privacy: .public) rawNV12=\(usesRawNV12, privacy: .public)")

            let display: SCDisplay
            if captureSource == .desktopMirror {
                if let mirrorDisplay = try await resolveMirrorCaptureDisplay() {
                    guard captureAttemptIsCurrent(
                        attempt,
                        gate: attemptGate,
                        connection: connection
                    ) else {
                        abandonCaptureStart(pipeline: pipeline, gate: attemptGate)
                        return .cancelled
                    }
                    display = mirrorDisplay
                } else if let fallbackDisplayID = directMirrorFallbackDisplayID() {
                    guard captureAttemptIsCurrent(
                        attempt,
                        gate: attemptGate,
                        connection: connection
                    ) else {
                        abandonCaptureStart(pipeline: pipeline, gate: attemptGate)
                        return .cancelled
                    }
                    TBLog.connection.warning("capture: no virtual ScreenCaptureKit display; using direct fallback id=\(fallbackDisplayID, privacy: .public)")
                    return startDirectDisplayStream(
                        displayID: fallbackDisplayID,
                        preset: preset,
                        pipeline: pipeline,
                        attempt: attempt,
                        gate: attemptGate,
                        connection: connection
                    ) ? .started(attempt: attempt) : .failed
                } else {
                    abandonCaptureStart(pipeline: pipeline, gate: attemptGate)
                    return .failed
                }
            } else {
                guard session.displayID != kCGNullDirectDisplay else {
                    throw NSError(
                        domain: "TargetBridgeCapture",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "extended capture has no receiver-backed virtual display ID"]
                    )
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard captureAttemptIsCurrent(
                    attempt,
                    gate: attemptGate,
                    connection: connection
                ) else {
                    abandonCaptureStart(pipeline: pipeline, gate: attemptGate)
                    return .cancelled
                }
                if let targetDisplay = content.displays.first(where: { $0.displayID == session.displayID }) {
                    display = targetDisplay
                } else {
                    display = try await waitForCaptureDisplay()
                    guard captureAttemptIsCurrent(
                        attempt,
                        gate: attemptGate,
                        connection: connection
                    ) else {
                        abandonCaptureStart(pipeline: pipeline, gate: attemptGate)
                        return .cancelled
                    }
                }
                guard display.displayID == session.displayID else {
                    throw NSError(
                        domain: "TargetBridgeCapture",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey:
                            "ScreenCaptureKit selected display \(display.displayID), expected receiver-backed display \(session.displayID)"]
                    )
                }
            }

            let usesCursorOverlay = inputControlRole.usesLowLatencyCursorOverlay(
                largeCursorEnabled: largeCursor
            )
            let configuration = SCStreamConfiguration()
            configuration.width = preset.width
            configuration.height = preset.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(preset.captureRequestFrameRate))
            configuration.queueDepth = preset.queueDepth
            configuration.pixelFormat = usesDPCM
                ? kCVPixelFormatType_32BGRA
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            if usesDPCM {
                // TBD2 preserves the packed RGB bytes but intentionally carries
                // no per-frame color metadata. Make the wire contract explicit:
                // 8-bit SDR Display P3 at capture and presentation.
                configuration.colorSpaceName = CGColorSpace.displayP3
                if #available(macOS 15.0, *) {
                    configuration.captureDynamicRange = .SDR
                }
            }
            configuration.shouldBeOpaque = true
            configuration.showsCursor = !usesCursorOverlay
            configuration.scalesToFit = true
            configuration.captureResolution = preset.captureResolution
            configuration.capturesAudio = shouldRelayAudio
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48000
            configuration.channelCount = 2

            streamResolutionText = TBDisplaySenderL10n.streamSummary(
                preset: preset,
                source: captureSource,
                language: language,
                codecName: codecName
            )

            let delegate = CaptureDelegate()
            delegate.expectedDisplayID = session.displayID
            delegate.captureDisplayID = display.displayID
            delegate.requiresRasterExactCapture = usesDPCM
            delegate.expectedPixelWidth = preset.width
            delegate.expectedPixelHeight = preset.height
            delegate.onFrame = { sampleBuffer in
                // ScreenCaptureKit already invokes this closure on pipeline.queue.
                // Encode immediately so its IOSurface returns to WindowServer
                // without an extra dispatch hop.
                pipeline.encode(sampleBuffer)
            }
            delegate.onAudio = { [weak self] sampleBuffer in
                self?.processAudio(sampleBuffer)
            }
            delegate.onError = { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.captureAttemptIsCurrent(
                        attempt,
                        gate: attemptGate,
                        connection: connection
                    ) else { return }
                    self.setStatus(.captureError(self.formattedCaptureErrorMessage(for: error)))
                    self.stop(resetStatusTo: nil)
                }
            }
            captureDelegate = delegate

            let filter = SCContentFilter(display: display, excludingWindows: [])
            captureDisplayText = TBDisplaySenderL10n.captureDisplaySCDisplay(language, id: display.displayID)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
            try stream.addStreamOutput(
                delegate,
                type: .screen,
                sampleHandlerQueue: pipeline.queue
            )
            if shouldRelayAudio {
                try stream.addStreamOutput(
                    delegate,
                    type: .audio,
                    sampleHandlerQueue: DispatchQueue(label: "fd.tbmonitor.sender.audio", qos: .userInteractive)
                )
            }
            try await stream.startCapture()
            guard captureAttemptIsCurrent(
                attempt,
                gate: attemptGate,
                connection: connection
            ) else {
                try? stream.removeStreamOutput(delegate, type: .screen)
                try? stream.removeStreamOutput(delegate, type: .audio)
                stream.stopCapture(completionHandler: nil)
                abandonCaptureStart(pipeline: pipeline, gate: attemptGate)
                return .cancelled
            }
            scStream = stream
            isStreaming = true
            if usesCursorOverlay { startCursorUpdates(displayID: display.displayID) }
            beginCaptureActivity(wakeDisplay: false)
            startFPSTimer()
            startCaptureWatchdog()
            return .started(attempt: attempt)
        } catch {
            if captureAttemptGate?.isActive != true || !shouldProduceDisplayFrames {
                return .cancelled
            }
            if error.localizedDescription.hasPrefix("no virtual SCDisplay available") {
                setStatus(.noShareableDisplay(error.localizedDescription))
            } else {
                setStatus(.captureDesktopError(formattedCaptureErrorMessage(for: error)))
            }
            return .failed
        }
    }

    /// Waking a headless graphical session is asynchronous. Poll briefly for a
    /// receiver-native ScreenCaptureKit surface before using the direct fallback.
    private func resolveMirrorCaptureDisplay() async throws -> SCDisplay? {
        for attempt in 0..<30 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if session.displayID != kCGNullDirectDisplay,
               let virtualDisplay = content.displays.first(where: { $0.displayID == session.displayID }) {
                TBLog.connection.info("capture: using receiver-native mirrored display id=\(virtualDisplay.displayID, privacy: .public)")
                return virtualDisplay
            }
            if let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) {
                TBLog.connection.info("capture: using main display id=\(mainDisplay.displayID, privacy: .public)")
                return mainDisplay
            }
            if attempt == 0 {
                TBLog.connection.info("capture: graphical session is waking; waiting for a shareable display")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func directMirrorFallbackDisplayID() -> CGDirectDisplayID? {
        if session.displayID != kCGNullDirectDisplay, CGDisplayIsOnline(session.displayID) != 0 {
            return session.displayID
        }
        let mainDisplayID = CGMainDisplayID()
        if mainDisplayID != kCGNullDirectDisplay, CGDisplayIsOnline(mainDisplayID) != 0 {
            return mainDisplayID
        }
        return nil
    }

    private func startDirectDisplayStream(
        displayID: CGDirectDisplayID,
        preset: TBDisplayCapturePreset,
        pipeline: TBVideoPipeline,
        attempt: UInt64,
        gate: TBCaptureAttemptGate,
        connection: NWConnection
    ) -> Bool {
        guard self.pipeline === pipeline,
              captureAttemptIsCurrent(attempt, gate: gate, connection: connection)
        else { return false }
        let usesCursorOverlay = inputControlRole.usesLowLatencyCursorOverlay(
            largeCursorEnabled: largeCursor
        )
        let codecName = activeCodecName ?? codecName(for: activeCodecType ?? preset.codecType)
        streamResolutionText = TBDisplaySenderL10n.streamSummary(
            preset: preset,
            source: captureSource,
            language: language,
            codecName: codecName
        )

        // Deliver frames straight onto the pipeline's own queue — the handler
        // runs there, so encode happens off the main thread with no extra hop.
        let directCapture = TBDirectDisplayStreamCapture(pipeline: pipeline, queue: pipeline.queue)
        guard directCapture.start(displayID: displayID, preset: preset, showCursor: !usesCursorOverlay) else {
            return false
        }
        guard captureAttemptIsCurrent(attempt, gate: gate, connection: connection) else {
            directCapture.stop()
            abandonCaptureStart(pipeline: pipeline, gate: gate)
            return false
        }

        directDisplayStream = directCapture
        captureDisplayText = TBDisplaySenderL10n.captureDisplayCGDisplayStream(language, id: displayID)
        isStreaming = true
        if usesCursorOverlay { startCursorUpdates(displayID: displayID) }
        beginCaptureActivity(wakeDisplay: false)
        startFPSTimer()
        startCaptureWatchdog()
        return true
    }

    private func activityOptions() -> ProcessInfo.ActivityOptions {
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        if preventDisplaySleep {
            options.insert(.idleDisplaySleepDisabled)
        }
        return options
    }

    private func beginCaptureActivity(wakeDisplay: Bool = true) {
        if streamingActivity == nil {
            streamingActivity = ProcessInfo.processInfo.beginActivity(
                options: activityOptions(),
                reason: "TargetBridge streaming active"
            )
        }
        guard wakeDisplay, preventDisplaySleep else { return }

        let result = IOPMAssertionDeclareUserActivity(
            "TargetBridge capture requested" as CFString,
            kIOPMUserActiveLocal,
            &displayWakeAssertionID
        )
        if result == kIOReturnSuccess {
            TBLog.connection.info("capture: requested graphical-session wake")
        } else {
            TBLog.connection.error("capture: unable to wake graphical session result=\(result, privacy: .public)")
        }
    }

    private func endCaptureActivity() {
        if displayWakeAssertionID != 0 {
            IOPMAssertionRelease(displayWakeAssertionID)
            displayWakeAssertionID = 0
        }
        if let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
    }

    private func waitForCaptureDisplay() async throws -> SCDisplay {
        let targetDisplayID = session.displayID != kCGNullDirectDisplay
            ? session.displayID
            : CGMainDisplayID()
        return try await waitForVirtualDisplay(
            matching: targetDisplayID,
            baselineDisplayIDs: baselineDisplayIDs
        )
    }

    private func waitForVirtualDisplay(
        matching targetDisplayID: CGDirectDisplayID,
        baselineDisplayIDs: Set<CGDirectDisplayID>
    ) async throws -> SCDisplay {
        enum DisplayLookupError: LocalizedError {
            case notFound(details: String)

            var errorDescription: String? {
                switch self {
                case .notFound(let details):
                    return details
                }
            }
        }

        var lastContent: SCShareableContent?
        for _ in 0..<80 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            lastContent = content
            if let display = content.displays.first(where: { $0.displayID == targetDisplayID }) {
                return display
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        let content: SCShareableContent
        if let lastContent {
            content = lastContent
        } else {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        let availableIDs = content.displays.map { String($0.displayID) }.sorted().joined(separator: ", ")
        let baselineIDs = baselineDisplayIDs.map(String.init).sorted().joined(separator: ", ")
        let onlineIDs = onlineDisplayIDs().map(String.init).sorted().joined(separator: ", ")
        throw DisplayLookupError.notFound(
            details: "no virtual SCDisplay available (target=\(targetDisplayID), baseline=[\(baselineIDs)], available=[\(availableIDs)], online=[\(onlineIDs)])"
        )
    }

    private func fetchShareableDisplayIDs() async -> Set<CGDirectDisplayID> {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return Set(content.displays.map(\.displayID))
        } catch {
            return []
        }
    }

    /// A freshly created virtual display can be reported by CoreGraphics before
    /// it is usable in a display configuration. Waiting briefly avoids racing
    /// `CGConfigureDisplayMirrorOfDisplay` on first connect.
    private func waitForOnlineDisplay(_ displayID: CGDirectDisplayID) async -> Bool {
        for _ in 0..<20 {
            if onlineDisplayIDs().contains(displayID) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return onlineDisplayIDs().contains(displayID)
    }

    /// DPCM is opt-in until sender and receiver hardware tests prove it safe as
    /// a default. Older receivers never see its packet type because capability
    /// advertisement and the environment switch are both required.
    private func dpcmEnabled(for profile: TBMonitorDisplayProfile) -> Bool {
        guard profile.supportsDPCM == true else { return false }
        return dpcmRequestedByEnvironment()
    }

    private func dpcmRequestedByEnvironment() -> Bool {
        guard let value = ProcessInfo.processInfo.environment["DPCM"]?.lowercased() else {
            return false
        }
        return value == "1" || value == "true"
    }

    /// RAW remains an explicit diagnostic-only transport until a selectable
    /// profile and sustained hardware tests prove it safe for normal sessions.
    private func rawNV12Enabled(for profile: TBMonitorDisplayProfile) -> Bool {
        guard profile.supportsRawNV12 == true else { return false }
        return rawNV12RequestedByEnvironment()
    }

    private func rawNV12RequestedByEnvironment() -> Bool {
        guard let value = ProcessInfo.processInfo.environment["RAW"]?.lowercased() else { return false }
        return value == "1" || value == "true"
    }

    private func configureDesktopMirror(for virtualDisplayID: CGDirectDisplayID) -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            var displayConfig: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&displayConfig) == .success, let cfg = displayConfig else {
                return false
            }

            var completed = false
            defer {
                if !completed {
                    CGCancelDisplayConfiguration(cfg)
                }
            }

            let result = CGConfigureDisplayMirrorOfDisplay(cfg, virtualDisplayID, CGMainDisplayID())
            if result == .success {
                let complete = CGCompleteDisplayConfiguration(cfg, .forSession)
                if complete == .success {
                    completed = true
                    return true
                }
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        return false
    }

    private func scheduleExtendedDesktopRecovery(for virtualDisplayID: CGDirectDisplayID) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            var hasAppliedArrangement = false

            for attempt in 1...12 {
                try? await Task.sleep(nanoseconds: 500_000_000)

                guard self.captureSource == .extendedDesktop,
                      self.session.displayID == virtualDisplayID,
                      self.activeProfile != nil
                else { return }

                // A newly recreated virtual display can already be outside a mirror set
                // while still sitting at macOS's default placement on the right.
                // Force at least one explicit extended-desktop configuration pass so
                // we can reapply the saved arrangement for this receiver.
                if CGDisplayIsInMirrorSet(virtualDisplayID) == 0 && hasAppliedArrangement {
                    self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                    return
                }

                let configured = self.configureExtendedDesktop(for: virtualDisplayID)
                if configured {
                    hasAppliedArrangement = true
                }
                self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                NSLog(
                    "TargetBridge: extended desktop recovery attempt %d for %u configured=%d state=%@",
                    attempt,
                    virtualDisplayID,
                    configured,
                    self.displayStateText
                )

                if configured || (CGDisplayIsInMirrorSet(virtualDisplayID) == 0 && hasAppliedArrangement) {
                    return
                }
            }
        }
    }

    private func scheduleDesktopMirrorRecovery(for virtualDisplayID: CGDirectDisplayID) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 1...12 {
                try? await Task.sleep(nanoseconds: 500_000_000)

                guard self.captureSource == .desktopMirror,
                      self.session.displayID == virtualDisplayID,
                      self.activeProfile != nil
                else { return }

                if CGDisplayIsInMirrorSet(virtualDisplayID) != 0 {
                    self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                    return
                }

                let configured = self.configureDesktopMirror(for: virtualDisplayID)
                self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                NSLog(
                    "TargetBridge: desktop mirror recovery attempt %d for %u configured=%d state=%@",
                    attempt,
                    virtualDisplayID,
                    configured,
                    self.displayStateText
                )

                if configured || CGDisplayIsInMirrorSet(virtualDisplayID) != 0 {
                    return
                }
            }
        }
    }

    private func configureExtendedDesktop(for virtualDisplayID: CGDirectDisplayID) -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            var displayConfig: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&displayConfig) == .success, let cfg = displayConfig else {
                return false
            }

            var completed = false
            defer {
                if !completed {
                    CGCancelDisplayConfiguration(cfg)
                }
            }

            let mainDisplayID = CGMainDisplayID()
            let mainBounds = CGDisplayBounds(mainDisplayID)
            let mainMirrorResult = CGConfigureDisplayMirrorOfDisplay(cfg, mainDisplayID, kCGNullDirectDisplay)
            let virtualMirrorResult = CGConfigureDisplayMirrorOfDisplay(cfg, virtualDisplayID, kCGNullDirectDisplay)
            if mainMirrorResult != .success || virtualMirrorResult != .success {
                NSLog(
                    "TargetBridge: failed to detach mirror set for extended desktop (main=%d virtual=%d)",
                    mainMirrorResult.rawValue,
                    virtualMirrorResult.rawValue
                )
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
                continue
            }

            let mainOriginResult = CGConfigureDisplayOrigin(cfg, mainDisplayID, 0, 0)
            let savedArrangement = activeProfile.flatMap { loadSavedExtendedDisplayArrangement(for: $0) }
            let defaultTargetX = Int32((mainBounds.maxX - mainBounds.origin.x).rounded())
            let targetX: Int32
            let targetY: Int32
            if let savedArrangement {
                if savedArrangement.isRelativeToMainDisplay {
                    targetX = Int32(mainBounds.origin.x.rounded()) + savedArrangement.x
                    targetY = Int32(mainBounds.origin.y.rounded()) + savedArrangement.y
                } else {
                    targetX = savedArrangement.x
                    targetY = savedArrangement.y
                }
            } else {
                targetX = defaultTargetX
                targetY = 0
            }
            let originResult = CGConfigureDisplayOrigin(cfg, virtualDisplayID, targetX, targetY)
            if mainOriginResult != .success || originResult != .success {
                NSLog(
                    "TargetBridge: failed to position displays for extended desktop (main=%d virtual=%u targetX=%d targetY=%d result=%d)",
                    mainOriginResult.rawValue,
                    virtualDisplayID,
                    targetX,
                    targetY,
                    originResult.rawValue
                )
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
                continue
            }

            let complete = CGCompleteDisplayConfiguration(cfg, .forSession)
            if complete == .success {
                completed = true
                return true
            }
            NSLog(
                "TargetBridge: CGCompleteDisplayConfiguration failed while forcing extended desktop for %u (result=%d)",
                virtualDisplayID,
                complete.rawValue
            )

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        return CGDisplayIsInMirrorSet(virtualDisplayID) == 0
    }

    private func describeDisplayState(for virtualDisplayID: CGDirectDisplayID) -> String {
        let mainDisplayID = CGMainDisplayID()
        let virtualMirror = CGDisplayIsInMirrorSet(virtualDisplayID) != 0
        let mainMirror = CGDisplayIsInMirrorSet(mainDisplayID) != 0
        let virtualMirrors = CGDisplayMirrorsDisplay(virtualDisplayID)
        let mainMirrors = CGDisplayMirrorsDisplay(mainDisplayID)
        let identity = session.identityDescription.isEmpty ? "identity=n/a" : session.identityDescription
        return TBDisplaySenderL10n.displayStateSummary(
            language: language,
            identity: identity,
            virtual: virtualDisplayID,
            virtualMirror: virtualMirror,
            virtualMirrors: virtualMirrors,
            main: mainDisplayID,
            mainMirror: mainMirror,
            mainMirrors: mainMirrors
        )
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }
    private func startCursorUpdates(displayID: CGDirectDisplayID) {
        cursorTimer?.invalidate()
        cursorDisplayID = displayID
        lastCursorPacket = nil

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                sendCursorUpdateIfNeeded()
            }
        }
        cursorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        sendCursorUpdateIfNeeded(force: true)
    }

    private func sendHiddenCursorPacketIfNeeded() {
        guard isConnected else { return }

        let cursor = TBMonitorCursor(
            x: 0,
            y: 0,
            width: capturePreset.width,
            height: capturePreset.height,
            visible: false,
            type: 0,
            large: false
        )
        lastCursorPacket = cursor
        if let packet = TBMonitorProtocol.makeJSONPacket(type: .cursor, value: cursor) {
            send(packet)
        }
    }

    private func applyCursorOverlayMode() {
        if inputRelayActive {
            cursorTimer?.invalidate()
            cursorTimer = nil
            sendHiddenCursorPacketIfNeeded()
            return
        }

        let usesCursorOverlay = inputControlRole.usesLowLatencyCursorOverlay(
            largeCursorEnabled: largeCursor
        )
        guard usesCursorOverlay, isStreaming, cursorDisplayID != kCGNullDirectDisplay else { return }
        startCursorUpdates(displayID: cursorDisplayID)
    }

    private func getCurrentCursorType() -> Int {
        guard let current = NSCursor.currentSystem else { return 0 }
        if let last = lastCheckedCursor, last == current {
            return lastCheckedCursorType
        }

        lastCheckedCursor = current

        if let currentPng = Self.normalizedPng(for: current.image),
           let matchedType = Self.standardCursorPngs[currentPng] {
            lastCheckedCursorType = matchedType
            return matchedType
        }

        let size = current.image.size
        let hotSpot = current.hotSpot
        let type: Int
        if size.width > 0 && size.height > 0 {
            if hotSpot.x > 0 && hotSpot.x < 10 && hotSpot.y == 0 {
                type = 2 // Pointing Hand
            } else if size.width < size.height && abs(hotSpot.x - size.width / 2) < 2 && abs(hotSpot.y - size.height / 2) < 2 {
                type = 1 // I-Beam
            } else if abs(hotSpot.x - size.width / 2) < 2 && abs(hotSpot.y - size.height / 2) < 2 {
                if size.width > size.height {
                    type = 3 // Resize Horizontal
                } else if size.height > size.width {
                    type = 4 // Resize Vertical
                } else {
                    type = 3 // Default fallback for square symmetric cursors: Resize Horizontal
                }
            } else {
                type = 0 // Arrow
            }
        } else {
            type = 0 // Arrow
        }

        lastCheckedCursorType = type
        return type
    }

    private func sendCursorUpdateIfNeeded(force: Bool = false) {
        guard !inputRelayActive else { return }
        guard isConnected, isStreaming, cursorDisplayID != kCGNullDirectDisplay else { return }
        guard let point = CGEvent(source: nil)?.location else { return }

        let bounds = CGDisplayBounds(cursorDisplayID)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let localX = point.x - bounds.origin.x
        let localY = point.y - bounds.origin.y
        let visible = localX >= 0 && localY >= 0 && localX <= bounds.width && localY <= bounds.height

        let scaledX = Int((max(0, min(bounds.width, localX)) / bounds.width) * Double(capturePreset.width))
        let scaledY = Int((max(0, min(bounds.height, localY)) / bounds.height) * Double(capturePreset.height))
        let cursor = TBMonitorCursor(
            x: scaledX,
            y: scaledY,
            width: capturePreset.width,
            height: capturePreset.height,
            visible: visible,
            type: getCurrentCursorType(),
            large: largeCursor
        )

        if !force, let previous = lastCursorPacket {
            let movement = abs(previous.x - cursor.x) + abs(previous.y - cursor.y)
            if movement < 2,
               previous.visible == cursor.visible,
               previous.width == cursor.width,
               previous.height == cursor.height,
               previous.type == cursor.type,
               previous.large == cursor.large {
                return
            }
        }

        lastCursorPacket = cursor
        if let packet = TBMonitorProtocol.makeJSONPacket(type: .cursor, value: cursor) {
            send(packet)
        }
    }

    private func registerDisplayLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let register: (Notification.Name, Bool) -> Void = { [weak self] name, awake in
            self?.wakeObservers.append(
                center.addObserver(
                    forName: name,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.handleSourceDisplayAvailability(awake: awake)
                    }
                }
            )
        }

        // These are public NSWorkspace notifications. No private lock or
        // screensaver notification is treated as an authorization signal.
        register(NSWorkspace.willSleepNotification, false)
        register(NSWorkspace.screensDidSleepNotification, false)
        register(NSWorkspace.sessionDidResignActiveNotification, false)
        register(NSWorkspace.didWakeNotification, true)
        register(NSWorkspace.screensDidWakeNotification, true)
        register(NSWorkspace.sessionDidBecomeActiveNotification, true)
    }

    /// Seed lifecycle state from public CoreGraphics facts so an app launched
    /// after a display transition does not assume that its source is drawable.
    private static func currentSourceDisplayAvailable() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true
        else { return false }

        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return false
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return false
        }
        return displays.prefix(Int(count)).contains {
            CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0
        }
    }

    private func registerDisplayReconfigurationCallback() {
        guard !displayReconfigurationCallbackRegistered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback, context)
        displayReconfigurationCallbackRegistered = (result == .success)
        if verboseDisplayLogging {
            startVerboseLoggingTimer()
        }
    }

    private func handleDisplayReconfiguration(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        let isOurs = session.displayID != kCGNullDirectDisplay && displayID == session.displayID
        guard verboseDisplayLogging || isOurs else { return }
        var parts: [String] = []
        if flags.contains(.addFlag) { parts.append("add") }
        if flags.contains(.removeFlag) { parts.append("remove") }
        if flags.contains(.enabledFlag) { parts.append("enabled") }
        if flags.contains(.disabledFlag) { parts.append("disabled") }
        if flags.contains(.mirrorFlag) { parts.append("mirror") }
        if flags.contains(.unMirrorFlag) { parts.append("unMirror") }
        if flags.contains(.movedFlag) { parts.append("moved") }
        if flags.contains(.setMainFlag) { parts.append("setMain") }
        if flags.contains(.setModeFlag) { parts.append("setMode") }
        if flags.contains(.beginConfigurationFlag) { parts.append("beginConfiguration") }
        if flags.contains(.desktopShapeChangedFlag) { parts.append("desktopShapeChanged") }
        let flagText = parts.isEmpty ? "none" : parts.joined(separator: "|")
        NSLog(
            "TargetBridge: display reconfiguration displayID=%u ours=%@ flags=%@ online=[%@]",
            displayID,
            isOurs ? "yes" : "no",
            flagText,
            onlineDisplayIDs().map(String.init).joined(separator: ",")
        )
        if isOurs, session.displayID != kCGNullDirectDisplay {
            displayStateText = describeDisplayState(for: session.displayID)
        }
    }

    private func startVerboseLoggingTimer() {
        stopVerboseLoggingTimer()
        guard verboseDisplayLogging else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logStreamSnapshot()
            }
        }
        verboseLoggingTimer = timer
        logStreamSnapshot()
    }

    private func stopVerboseLoggingTimer() {
        verboseLoggingTimer?.invalidate()
        verboseLoggingTimer = nil
    }

    private func startCaptureWatchdog() {
        captureHealthWatchdog?.invalidate()
        if let progress = pipeline?.progressSnapshot() {
            postFirstFrameProgressWatchdog.reset(
                capturedFrames: progress.capturedFrames,
                sentFrames: progress.sentFrames
            )
        } else {
            postFirstFrameProgressWatchdog.reset()
        }
        captureHealthWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkCaptureHealth()
            }
        }
    }

    private func stopCaptureWatchdog() {
        captureHealthWatchdog?.invalidate()
        captureHealthWatchdog = nil
        postFirstFrameProgressWatchdog.reset()
    }

    private func checkCaptureHealth() {
        guard isStreaming, activeProfile != nil, !isRestartingCaptureAfterWake, let pipeline else { return }
        let progress = pipeline.progressSnapshot()
        switch postFirstFrameProgressWatchdog.observe(
            progress,
            hasDeliveredFirstFrame: sessionAckSent
        ) {
        case .none:
            break
        case .tearDownPreservingCodec:
            NSLog(
                "TargetBridge DPCM: progress watchdog tripped — captured=%d sent=%d; tearing down without codec downgrade",
                progress.capturedFrames,
                progress.sentFrames
            )
            TBSenderAutomation.preserveAutomaticReconnectAfterTransientCaptureFailure()
            stop(
                resetStatusTo: .captureError("DPCM delivery stopped after capture remained active"),
                persistArrangement: false,
                teardownReason: "sender_dpcm_progress_timeout"
            )
            return
        case .terminatePoisonedProcess:
            NSLog(
                "TargetBridge DPCM: terminal encoder health detected by progress watchdog — captured=%d sent=%d",
                progress.capturedFrames,
                progress.sentFrames
            )
            stop(
                resetStatusTo: .captureError("DPCM GPU encoder became unresponsive"),
                persistArrangement: false,
                teardownReason: "sender_dpcm_gpu_quarantine"
            )
            requestProcessRecoveryIfNeeded(
                after: .dpcmEncoderQuarantined,
                context: "post-first-frame progress watchdog"
            )
            return
        }
        /* After the first delivered frame, silence alone is not a failure:
         * CGDisplayStream is event-driven and a static desktop can legitimately
         * produce nothing. Only the captured-versus-sent evidence above may
         * recover a post-first-frame session. */
        guard !sessionAckSent else { return }
        let elapsed = Date().timeIntervalSince(pipeline.lastCaptureFrameAtSnapshot)
        guard elapsed >= 8.0 else { return }
        NSLog("TargetBridge: capture watchdog tripped — %.1fs since last frame, soft restart", elapsed)
        scheduleCaptureRestart(reason: "watchdog (\(Int(elapsed))s without frames)", delaySeconds: 0.5)
    }

    private func logStreamSnapshot() {
        guard verboseDisplayLogging else { return }
        let online = onlineDisplayIDs()
        let virtualOnline = online.contains(session.displayID)
        let diag = pipeline?.diagnosticsSnapshot() ?? (
            pending: 0,
            inFlight: 0,
            ptsSeq: 0,
            captured: 0,
            droppedPacing: 0,
            droppedPre: 0,
            droppedPost: 0
        )
        NSLog(
            "TargetBridge: stream snapshot streaming=%@ fps=%d virtualID=%u online=%@ pendingPackets=%d inFlightEncode=%d ptsSeq=%lld captured=%d droppedPacing=%d droppedPre=%d droppedPost=%d",
            isStreaming ? "yes" : "no",
            liveMetrics.senderFPS,
            session.displayID,
            virtualOnline ? "yes" : "no",
            diag.pending,
            diag.inFlight,
            diag.ptsSeq,
            diag.captured,
            diag.droppedPacing,
            diag.droppedPre,
            diag.droppedPost
        )
    }

    private func handleSourceDisplayAvailability(awake: Bool) {
        if !TBDisplayLifecyclePolicy.shouldApplySourceTransition(
            awake: awake,
            autoRestartOnWake: autoRestartOnWake
        ) {
            TBLog.connection.info(
                "display lifecycle: automatic wake resume disabled by preference"
            )
            return
        }
        guard sourceDisplayState.value != awake else { return }
        var nextEpoch = sourceDisplayState.epoch &+ 1
        if nextEpoch == 0 { nextEpoch = 1 }
        guard sourceDisplayState.apply(value: awake, epoch: nextEpoch) == .applied else {
            return
        }
        TBLog.connection.info(
            "display lifecycle: sourceAwake=\(awake, privacy: .public) epoch=\(nextEpoch, privacy: .public)"
        )
        scheduleDisplayLifecycleReconciliation(reason: awake ? "source wake" : "source sleep")
    }

    private func handleReceiverSurfaceState(_ state: TBMonitorReceiverSurfaceState) {
        switch receiverSurfaceState.apply(value: state.available, epoch: state.epoch) {
        case .applied:
            TBLog.connection.info(
                "display lifecycle: receiverSurface=\(state.available, privacy: .public) epoch=\(state.epoch, privacy: .public)"
            )
            scheduleDisplayLifecycleReconciliation(reason: "receiver surface state")
        case .duplicate:
            break
        case .stale:
            TBLog.connection.info(
                "display lifecycle: ignored stale receiver surface epoch=\(state.epoch, privacy: .public)"
            )
        }
    }

    private var shouldProduceDisplayFrames: Bool {
        TBDisplayLifecyclePolicy.shouldProduceFrames(
            sourceAwake: sourceDisplayState.value,
            receiverSurfaceAvailable: receiverSurfaceState.value,
            peerSupportsLifecycle: activeProfile?.supportsDisplayLifecycle == true
        )
    }

    private func scheduleDisplayLifecycleReconciliation(reason: String) {
        displayLifecycleTransitionGeneration &+= 1
        // Close the per-frame gate immediately, even when a prior async
        // capture start is still suspended and this reconciliation task must
        // wait for it to return.
        if !shouldProduceDisplayFrames {
            invalidateCaptureAttempt()
        }
        guard !displayLifecycleTransitionInFlight else { return }
        displayLifecycleTransitionInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                let generation = self.displayLifecycleTransitionGeneration
                let shouldProduce = self.shouldProduceDisplayFrames

                if shouldProduce {
                    // Reliable NWConnection sends preserve this control packet
                    // ahead of the first frame produced after wake.
                    self.sendSourceDisplayStateIfNeeded()
                    if !self.isStreaming,
                       let profile = self.activeProfile,
                       self.session.displayID != kCGNullDirectDisplay {
                        await self.resumeCaptureForDisplayLifecycle(
                            profile: profile,
                            reason: reason
                        )
                    }
                } else {
                    if self.isStreaming {
                        self.pauseCaptureForDisplayLifecycle(reason: reason)
                    }
                    // Stop and drain the producer before ordering source-sleep
                    // behind its last whole frame on the reliable connection.
                    self.sendSourceDisplayStateIfNeeded()
                }

                if generation == self.displayLifecycleTransitionGeneration {
                    break
                }
            } while self.activeProfile != nil
            self.displayLifecycleTransitionInFlight = false
        }
    }

    func restartCaptureNow() {
        scheduleCaptureRestart(reason: "manual restart", delaySeconds: 0.0)
    }

    var canRestartCapture: Bool {
        isStreaming && activeProfile != nil && !isRestartingCaptureAfterWake
    }

    private func scheduleCaptureRestart(reason: String, delaySeconds: Double) {
        guard isStreaming, !isRestartingCaptureAfterWake, let profile = activeProfile else { return }
        isRestartingCaptureAfterWake = true
        NSLog("TargetBridge: \(reason) — soft restart of capture pipeline")
        Task { @MainActor [weak self] in
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            guard let self else { return }
            guard self.isStreaming, self.activeProfile?.receiverName == profile.receiverName else {
                self.isRestartingCaptureAfterWake = false
                return
            }
            await self.softRestartCapture(for: profile)
            self.isRestartingCaptureAfterWake = false
        }
    }

    private func softRestartCapture(for profile: TBMonitorDisplayProfile) async {
        // Tear down only the capture pipeline — keep the network connection and virtual display.
        let pipelineStopOutcome = stopCapturePipelinePreservingSession()
        if pipelineStopOutcome.requiresProcessTermination {
            stop(
                resetStatusTo: .captureError("DPCM GPU encoder became unresponsive"),
                persistArrangement: false,
                teardownReason: "sender_dpcm_gpu_quarantine"
            )
            requestProcessRecoveryIfNeeded(
                after: pipelineStopOutcome,
                context: "soft capture restart"
            )
            return
        }

        beginCaptureActivity(wakeDisplay: shouldProduceDisplayFrames)
        switch await startCapture(for: profile) {
        case .started(let attempt):
            if captureAttemptGeneration == attempt && !captureAttemptFirstFrameSeen {
                setStatus(.captureStartedWaitingFirstFrame)
                startFirstFrameWatchdog(for: attempt)
            }
        case .cancelled:
            return
        case .failed:
            NSLog("TargetBridge: soft restart after wake failed — falling back to full stop")
            stop(resetStatusTo: .captureError("capture restart after wake failed"))
        }
    }

    @discardableResult
    private func stopCapturePipelinePreservingSession() -> TBVideoPipelineStopOutcome {
        invalidateCaptureAttempt()
        cursorTimer?.invalidate()
        cursorTimer = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        stopCaptureWatchdog()
        if let directDisplayStream {
            directDisplayStream.stop()
            self.directDisplayStream = nil
        }
        if let stream = scStream {
            if let delegate = captureDelegate {
                try? stream.removeStreamOutput(delegate, type: .screen)
                try? stream.removeStreamOutput(delegate, type: .audio)
            }
            stream.stopCapture(completionHandler: nil)
            scStream = nil
        }
        captureDelegate = nil
        endCaptureActivity()
        let pipelineStopOutcome = pipeline?.stop() ?? .stopped
        pipeline = nil
        isStreaming = false
        liveMetrics.senderFPS = 0
        senderFPS = 0
        sentSnapshot = 0
        cursorDisplayID = kCGNullDirectDisplay
        lastCursorPacket = nil
        return pipelineStopOutcome
    }

    private func pauseCaptureForDisplayLifecycle(reason: String) {
        let outcome = stopCapturePipelinePreservingSession()
        if outcome.requiresProcessTermination {
            stop(
                resetStatusTo: .captureError("DPCM GPU encoder became unresponsive"),
                persistArrangement: false,
                teardownReason: "sender_dpcm_gpu_quarantine"
            )
            requestProcessRecoveryIfNeeded(
                after: outcome,
                context: "display lifecycle pause"
            )
            return
        }
        NSLog("TargetBridge: display lifecycle paused capture (%@)", reason)
    }

    private func resumeCaptureForDisplayLifecycle(
        profile: TBMonitorDisplayProfile,
        reason: String
    ) async {
        guard shouldProduceDisplayFrames,
              activeProfile?.receiverName == profile.receiverName,
              connection != nil else { return }
        captureBlockedByScreenRecordingPermission = false
        setStatus(.startingCapture(capturePreset.description, captureSource))
        let captureResult = await startCapture(for: profile)
        let attempt: UInt64
        switch captureResult {
        case .started(let startedAttempt):
            attempt = startedAttempt
        case .cancelled:
            return
        case .failed:
            if captureBlockedByScreenRecordingPermission {
                captureBlockedByScreenRecordingPermission = false
                TBSenderAutomation.suspendAutomaticReconnectForRequiredPermission()
                stop(
                    resetStatusTo: nil,
                    persistArrangement: false,
                    teardownReason: "sender_user_stop"
                )
            } else {
                stop(resetStatusTo: .captureError("capture resume after display wake failed"))
            }
            return
        }
        guard captureAttemptGeneration == attempt,
              shouldProduceDisplayFrames else { return }
        if captureSource == .extendedDesktop {
            scheduleExtendedDesktopRecovery(for: session.displayID)
        } else if captureSource == .desktopMirror {
            scheduleDesktopMirrorRecovery(for: session.displayID)
        }
        if !captureAttemptFirstFrameSeen {
            setStatus(.captureStartedWaitingFirstFrame)
            startFirstFrameWatchdog(for: attempt)
        }
        NSLog("TargetBridge: display lifecycle resumed capture (%@)", reason)
    }

    private func handleFirstEncodedFrame(attempt: UInt64) {
        guard captureAttemptGeneration == attempt,
              captureAttemptGate?.isActive == true,
              !captureAttemptFirstFrameSeen else { return }
        captureAttemptFirstFrameSeen = true
        sessionAckSent = true
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        TBLog.connection.info("capture: first encoded frame received")
        setStatus(.captureActive(capturePreset.description, activeCodecName ?? capturePreset.codecName, captureSource))
    }

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        sentSnapshot = pipeline?.sentFramesSnapshot ?? 0
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let total = pipeline?.sentFramesSnapshot ?? 0
                let fps = total - sentSnapshot
                liveMetrics.senderFPS = fps
                senderFPS = fps
                sentSnapshot = total
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendHeartbeat()
            }
        }
        heartbeatTimer = timer
        // The receiver deliberately expires a peer after 15 seconds without
        // traffic. A default-mode timer pauses while a menu, modal panel, or
        // event-tracking loop owns AppKit's run loop, which can make a healthy
        // parked display session look dead. Common mode keeps the inexpensive
        // two-second control-plane heartbeat alive without starting capture.
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startFirstFrameWatchdog(for attempt: UInt64) {
        // If the first encoded frame already arrived (handleFirstEncodedFrame ran
        // while startCapture was still suspended), there is nothing to watch for —
        // arming would only leave a no-op timer dangling for 4s.
        guard captureAttemptGeneration == attempt,
              !captureAttemptFirstFrameSeen else { return }
        firstFrameTimer?.invalidate()
        firstFrameTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard isStreaming,
                      captureAttemptGeneration == attempt,
                      !captureAttemptFirstFrameSeen else { return }
                let sentFrames = self.pipeline?.sentFramesSnapshot ?? 0
                TBLog.connection.error("capture: first-frame timeout preset=\(self.capturePreset.rawValue, privacy: .public) source=\(String(describing: self.captureSource), privacy: .public) connected=\(self.isConnected, privacy: .public) sentFrames=\(sentFrames, privacy: .public)")
                if self.capturePreset == .retina4k60 || self.capturePreset == .native5k || self.capturePreset == .native5k60Experimental {
                    setStatus(.hevcNoFrames)
                } else {
                    setStatus(.noFirstFrame)
                }
                TBSenderAutomation.preserveAutomaticReconnectAfterTransientCaptureFailure()
                stop(
                    resetStatusTo: nil,
                    persistArrangement: false,
                    teardownReason: "sender_capture_first_frame_timeout"
                )
            }
        }
    }

    private func startConnectWatchdog() {
        connectTimeoutWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isConnected else { return }

                let timeoutMessage: String
                switch self.language {
                case .italian: timeoutMessage = "Connessione scaduta"
                case .english: timeoutMessage = "Connection timed out"
                case .german: timeoutMessage = "Verbindungs-Zeitüberschreitung"
                case .french: timeoutMessage = "Délai de connexion dépassé"
                case .chinese: timeoutMessage = "连接超时"
                }

                // Attach where we dialed, from which interface, and the last
                // state the network stack reported — previously all of this
                // was discarded and the user saw only the bare timeout.
                let detail = TBConnectionDiagnostics.failureDetail(
                    receiverHost: self.receiverIP,
                    port: TBMonitorProtocol.port,
                    localIP: self.localInterfaceIP,
                    interfaceName: self.connectInterfaceName,
                    transport: self.transportKind.rawValue,
                    lastNetworkState: self.lastConnectionStateDetail
                )
                TBLog.connection.error("connect: timed out — \(detail, privacy: .public)")
                if self.requestPreProfileReconnect(
                    after: .retryConnectionFailedOrTimedOut,
                    teardownReason: "sender_pre_profile_connect_timeout"
                ) {
                    return
                }
                self.setStatus(.connectionFailed("\(timeoutMessage) — \(detail)"))
                self.stop(resetStatusTo: nil)
            }
        }
        
        connectTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }

    private func startDisplayProfileWatchdog(for expectedConnection: NWConnection) {
        displayProfileTimeoutWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self, weak expectedConnection] in
            Task { @MainActor [weak self, weak expectedConnection] in
                guard let self,
                      let expectedConnection,
                      self.connection === expectedConnection,
                      self.isConnected,
                      self.activeProfile == nil
                else { return }

                let detail = TBConnectionDiagnostics.failureDetail(
                    receiverHost: self.receiverIP,
                    port: TBMonitorProtocol.port,
                    localIP: self.localInterfaceIP,
                    interfaceName: self.connectInterfaceName,
                    transport: self.transportKind.rawValue,
                    lastNetworkState: "TCP ready; display profile missing"
                )
                TBLog.connection.error(
                    "connect: receiver profile timed out after TCP became ready — \(detail, privacy: .public)"
                )
                if self.requestPreProfileReconnect(
                    after: .displayProfileTimedOut,
                    teardownReason: "sender_pre_profile_timeout"
                ) {
                    return
                }
                self.setStatus(.connectionFailed(
                    "Receiver did not provide a display profile within 5 seconds — \(detail)"
                ))
                self.stop(
                    resetStatusTo: nil,
                    persistArrangement: false,
                    teardownReason: "sender_profile_timeout"
                )
            }
        }

        displayProfileTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }

    private func processAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isStreaming, shouldRelayAudio else { return }
        guard let data = audioConverter.convert(sampleBuffer: sampleBuffer) else { return }
        let packet = TBMonitorProtocol.makePacket(type: .audioFrame, payload: data)
        send(packet)
    }

    private var shouldRelayAudio: Bool {
        audioEnabled && audioAddonAvailable
    }

    private func send(_ packet: Data) {
        connection?.send(content: packet, completion: .contentProcessed({ _ in }))
    }

    func sendInputEvent(_ event: TBMonitorInputEvent) {
        guard isConnected else { return }
        send(TBMonitorProtocol.makeInputEventPacket(event))
    }

    func updateInputControlMode() {
        guard isConnected else { return }
        sendInputControlModeUpdate()
    }

}

private final class SBAudioConverter: Sendable {
    private let converterState: LockedConverterState = LockedConverterState()

    private final class LockedConverterState: @unchecked Sendable {
        private let lock = NSLock()
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        let outputFormat: AVAudioFormat

        init() {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48000.0,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 16,
                mReserved: 0
            )
            self.outputFormat = AVAudioFormat(streamDescription: &asbd)!
        }

        func convert(sampleBuffer: CMSampleBuffer) -> Data? {
            lock.lock()
            defer { lock.unlock() }

            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
            guard let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
            let inputASBD = asbdPointer.pointee

            // Recreate converter if input format changes
            if inputFormat == nil ||
               inputFormat!.streamDescription.pointee.mFormatFlags != inputASBD.mFormatFlags ||
               inputFormat!.streamDescription.pointee.mSampleRate != inputASBD.mSampleRate ||
               inputFormat!.streamDescription.pointee.mChannelsPerFrame != inputASBD.mChannelsPerFrame {
                var mutableASBD = inputASBD
                guard let inFormat = AVAudioFormat(streamDescription: &mutableASBD) else { return nil }
                self.inputFormat = inFormat
                self.converter = AVAudioConverter(from: inFormat, to: outputFormat)
            }

            guard let converter = self.converter, let inFormat = self.inputFormat else { return nil }

            let frameCount = sampleBuffer.numSamples
            guard frameCount > 0 else { return nil }
            let audioFrameCount = AVAudioFrameCount(frameCount)

            // Create input buffer
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: audioFrameCount) else { return nil }
            inputBuffer.frameLength = audioFrameCount

            // Extract audio data from sampleBuffer into inputBuffer
            let channelCount = Int(inFormat.channelCount)
            let bufferListSize = MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size
            let bufferListRaw = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { bufferListRaw.deallocate() }

            let ablPointer = bufferListRaw.assumingMemoryBound(to: AudioBufferList.self)
            var blockBuffer: CMBlockBuffer?

            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: ablPointer,
                bufferListSize: bufferListSize,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            )

            guard status == noErr else { return nil }

            let sourceBuffers = UnsafeMutableAudioBufferListPointer(ablPointer)
            let destinationBuffers = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
            guard sourceBuffers.count == destinationBuffers.count else { return nil }

            // ScreenCaptureKit may supply either one interleaved buffer or one
            // buffer per channel. Copy the actual AudioBufferList layout rather
            // than assuming a non-interleaved Float32 input.
            for index in 0..<sourceBuffers.count {
                let source = sourceBuffers[index]
                let destination = destinationBuffers[index]
                guard let sourceData = source.mData, let destinationData = destination.mData else {
                    return nil
                }

                let destinationByteCount = Int(destination.mDataByteSize)
                let byteCount = min(Int(source.mDataByteSize), destinationByteCount)
                guard byteCount > 0 else { return nil }
                memcpy(destinationData, sourceData, byteCount)
                if byteCount < destinationByteCount {
                    memset(destinationData.advanced(by: byteCount), 0, destinationByteCount - byteCount)
                }
            }

            // Perform conversion to outputFormat
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: audioFrameCount) else { return nil }

            var error: NSError?
            var inputConsumed = false
            let convertStatus = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if convertStatus == .error || error != nil {
                return nil
            }

            guard let channels = outputBuffer.int16ChannelData else { return nil }
            let dataSize = Int(outputBuffer.frameLength) * 4 // 2 channels * 2 bytes = 4 bytes per frame
            let rawPointer = UnsafeRawPointer(channels.pointee)
            return Data(bytes: rawPointer, count: dataSize)
        }
    }

    func convert(sampleBuffer: CMSampleBuffer) -> Data? {
        return converterState.convert(sampleBuffer: sampleBuffer)
    }
}

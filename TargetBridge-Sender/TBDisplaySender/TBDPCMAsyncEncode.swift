import CoreMedia
import CoreVideo
import Foundation
import IOSurface

enum TBDPCMDrainStatus: Equatable {
    case drained
    case quarantined
}

/// One GPU quarantine poisons DPCM for the lifetime of the process. The C
/// encoder must deliberately retain quarantined state because Metal may still
/// reach it; allowing a soft restart to construct another encoder would turn a
/// persistent GPU wedge into an unbounded leak. This lock also makes the
/// create-vs-poison decision linearizable across multiple display sessions.
final class TBDPCMEncoderProcessState: @unchecked Sendable {
    static let shared = TBDPCMEncoderProcessState()

    private let lock = NSLock()
    private var poisoned = false
    private var terminationClaimed = false

    init() {}

    var isPoisoned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return poisoned
    }

    func createIfHealthy<T>(_ create: () -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard !poisoned else { return nil }
        return create()
    }

    func recordDrain(isQuarantined: Bool) -> TBDPCMDrainStatus {
        guard isQuarantined else { return .drained }
        lock.lock()
        poisoned = true
        lock.unlock()
        return .quarantined
    }

    /// The service can have several display sessions stopping concurrently.
    /// Only the first poisoned stop should ask AppKit to terminate, while every
    /// later caller must still suppress encoder reconstruction.
    func claimTerminationIfPoisoned() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard poisoned, !terminationClaimed else { return false }
        terminationClaimed = true
        return true
    }
}

/// Minimal ownership-safe adapter around the asynchronous TBD2 GPU encoder.
///
/// The C encoder reads the pixel bytes after `submit` returns and recycles its
/// output as soon as the callback returns. Each submission therefore owns both
/// ends of that lifetime: the input sample/pixel buffer remains retained and
/// locked until completion, while the encoded bytes are copied into `Data`
/// before the callback gives the encoder its job slot back.
final class TBDPCMAsyncEncode: @unchecked Sendable {
    fileprivate final class Submission: @unchecked Sendable {
        // Keep both references explicitly. CMSampleBuffer owns capture timing
        // and attachments, while CVPixelBuffer owns the IOSurface being read.
        let sampleBuffer: CMSampleBuffer?
        let pixelBuffer: CVPixelBuffer
        let completion: @Sendable (Data?) -> Void
        private var isLocked = true

        init(sampleBuffer: CMSampleBuffer?,
             pixelBuffer: CVPixelBuffer,
             completion: @escaping @Sendable (Data?) -> Void) {
            self.sampleBuffer = sampleBuffer
            self.pixelBuffer = pixelBuffer
            self.completion = completion
        }

        func finish(with packet: Data?) {
            releaseInput()
            completion(packet)
        }

        /// Rejected C submissions promise no callback. Release the retained
        /// context and input lock without manufacturing a completion, so the
        /// pipeline does not decrement its in-flight count twice.
        func cancel() {
            releaseInput()
        }

        private func releaseInput() {
            if isLocked {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                isLocked = false
            }
        }
    }

    private let encoder: OpaquePointer
    private let processState: TBDPCMEncoderProcessState

    init?(processState: TBDPCMEncoderProcessState = .shared) {
        guard let encoder: OpaquePointer = processState.createIfHealthy({
            tb_dpcm_gpu_create()
        }) else { return nil }
        self.encoder = encoder
        self.processState = processState
    }

    deinit {
        // destroy() drains too, but spelling out the ordering here documents
        // that no callback may outlive this Swift owner. drain() also poisons
        // process-wide creation when C had to quarantine this encoder.
        _ = drain()
        tb_dpcm_gpu_destroy(encoder)
    }

    var deviceName: String {
        String(cString: tb_dpcm_gpu_device_name(encoder))
    }

    /// Submit one complete 8-bit BGRA frame as one TBD2 band. Returns false for
    /// malformed input or ordinary encoder backpressure; no callback follows a
    /// rejected submission.
    func submit(sampleBuffer: CMSampleBuffer,
                completion: @escaping @Sendable (Data?) -> Void) -> Bool {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return false
        }
        return submit(
            pixelBuffer: pixelBuffer,
            retaining: sampleBuffer,
            completion: completion
        )
    }

    /// The direct CGDisplayStream fallback already supplies an IOSurface-backed
    /// BGRA CVPixelBuffer, but has no CMSampleBuffer to retain.
    func submit(pixelBuffer: CVPixelBuffer,
                completion: @escaping @Sendable (Data?) -> Void) -> Bool {
        submit(pixelBuffer: pixelBuffer, retaining: nil, completion: completion)
    }

    @discardableResult
    func drain() -> TBDPCMDrainStatus {
        tb_dpcm_gpu_drain(encoder)
        return processState.recordDrain(
            isQuarantined: tb_dpcm_gpu_is_quarantined(encoder) != 0
        )
    }

    private func submit(pixelBuffer: CVPixelBuffer,
                        retaining sampleBuffer: CMSampleBuffer?,
                        completion: @escaping @Sendable (Data?) -> Void) -> Bool {
        guard !processState.isPoisoned else { return false }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 0
        else { return false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0,
              width <= 8192, height <= 8192,
              width <= Int(Int32.max), height <= Int(Int32.max),
              stride <= Int(Int32.max), stride.isMultiple(of: 4),
              width <= Int.max / 4, stride >= width * 4,
              width <= (1 << 27) / height,
              height <= Int.max / stride
        else { return false }

        let byteCount = stride * height
        let maximumEncodedBytes = tb_dpcm_max_size(Int32(width), Int32(height))
        guard byteCount <= CVPixelBufferGetDataSize(pixelBuffer),
              maximumEncodedBytes > 0,
              maximumEncodedBytes <= Int(TBMonitorProtocol.maxPacketLength) - 1,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return false }

        let pageSize = Int(getpagesize())
        guard byteCount <= Int.max - (pageSize - 1) else { return false }
        let mappedByteCount = ((byteCount + pageSize - 1) / pageSize) * pageSize
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else { return false }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            return false
        }
        let surfaceBaseAddress = IOSurfaceGetBaseAddress(surface)
        let baseValue = Int(bitPattern: baseAddress)
        let surfaceBaseValue = Int(bitPattern: surfaceBaseAddress)
        let allocationSize = IOSurfaceGetAllocSize(surface)
        guard baseValue.isMultiple(of: pageSize),
              baseValue >= surfaceBaseValue,
              baseValue - surfaceBaseValue <= allocationSize,
              mappedByteCount <= allocationSize - (baseValue - surfaceBaseValue)
        else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            return false
        }

        let submission = Submission(
            sampleBuffer: sampleBuffer,
            pixelBuffer: pixelBuffer,
            completion: completion
        )
        let context = Unmanaged.passRetained(submission).toOpaque()
        let result = tb_dpcm_gpu_encode_bands_async(
            encoder,
            baseAddress.assumingMemoryBound(to: UInt8.self),
            Int32(stride),
            Int32(width),
            Int32(height),
            1, // one whole-frame band
            0, // 8-bit BGRA, never ARGB2101010
            TBMonitorProtocol.headerSize,
            tbDPCMEncodeFinished,
            context
        )
        guard result == 0 else {
            Unmanaged<Submission>.fromOpaque(context).takeRetainedValue().cancel()
            return false
        }
        return true
    }
}

private let tbDPCMEncodeFinished: tb_dpcm_gpu_done = { context, ok, band, index, last in
    guard let context else { return }
    // This adapter only ever submits one band, so its sole callback must also
    // be the terminal callback that transfers the retained context back.
    let submission = Unmanaged<TBDPCMAsyncEncode.Submission>
        .fromOpaque(context)
        .takeRetainedValue()

    let packet: Data?
    if ok != 0,
       index == 0,
       last != 0,
       let band,
       let base = band.pointee.blob,
       let count = Int(exactly: band.pointee.len) {
        // framedPacket writes into the five reserved bytes and then copies the
        // entire packet. The copy must finish before this callback returns,
        // because the C encoder recycles `base` immediately afterward.
        packet = TBMonitorProtocol.framedPacket(
            type: .rawDPCM,
            base: base,
            totalCount: count
        )
    } else {
        packet = nil
    }
    submission.finish(with: packet)
}

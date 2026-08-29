import Foundation

@MainActor
enum TBInputDebugLog {
    private static let fileManager = FileManager.default
    private static let maximumLogBytes: UInt64 = 1_048_576

    private static var logURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("TargetBridge", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("input-debug.log", isDirectory: false)
    }

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        let url = logURL
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if let data = line.data(using: .utf8) {
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber,
               size.uint64Value + UInt64(data.count) > maximumLogBytes {
                let rotated = url.appendingPathExtension("1")
                try? fileManager.removeItem(at: rotated)
                try? fileManager.moveItem(at: url, to: rotated)
            }
            if fileManager.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    static var currentLogPath: String {
        logURL.path
    }
}

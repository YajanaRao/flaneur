import Darwin
import Foundation

/// Append-only debug log at `~/Library/Logs/Flaneur/flaneur.log` (Console.app lists it under Log Reports).
/// Every line is also echoed to stderr so `flaneur` run from a terminal behaves as before.
public enum Log {
    public static let shared = LogFile(url: defaultURL)

    public static var url: URL { shared.url }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Flaneur/flaneur.log")
    }

    public static func info(_ message: @autoclosure () -> String) {
        shared.write("INFO", message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        shared.write("ERROR", message())
    }

    /// Blocks until queued lines are on disk. Call right before the process exits.
    public static func flush() {
        shared.flush()
    }

    private static let reasonLock = NSLock()
    private static var reason: String?

    /// Set just before calling `NSApp.terminate` so the terminate log line can say why.
    public static var pendingQuitReason: String? {
        get { reasonLock.withLock { reason } }
        set { reasonLock.withLock { reason = newValue } }
    }
}

public final class LogFile: @unchecked Sendable {
    public let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "com.yajanarao.flaneur.log")
    private let formatter: ISO8601DateFormatter
    private let pid = ProcessInfo.processInfo.processIdentifier
    private var writesSinceSizeCheck = 0

    init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
    }

    func write(_ level: String, _ message: String) {
        let now = Date()
        queue.async { [self] in
            let line = "\(formatter.string(from: now)) [\(pid)] \(level) \(message)\n"
            FileHandle.standardError.write(Data("flaneur: \(message)\n".utf8))
            append(line)
        }
    }

    func flush() {
        queue.sync {}
    }

    private func append(_ line: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded(manager)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    /// One previous generation (`flaneur.log.1`) is enough for a launcher.
    private func rotateIfNeeded(_ manager: FileManager) {
        writesSinceSizeCheck += 1
        guard writesSinceSizeCheck == 1 || writesSinceSizeCheck % 50 == 0 else { return }
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        let previous = url.appendingPathExtension("1")
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: url, to: previous)
    }
}

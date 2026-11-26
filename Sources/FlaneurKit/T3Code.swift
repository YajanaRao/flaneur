import AppKit
import Foundation
import SQLite3

enum T3Code {
    static let bundleID = "com.t3tools.t3code"
    private static let limit = 30

    private static var userdata: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".t3/userdata")
    }

    static func collect() async throws -> [T3Thread] {
        guard await installed() else { return [] }
        let database = userdata.appendingPathComponent("statev2.sqlite").path
        guard let environmentID = environmentID(), FileManager.default.isReadableFile(atPath: database) else {
            return []
        }
        return try threads(database: database, environmentID: environmentID)
    }

    /// Bring the desktop app up, then hand it the thread link. The URL must not be the
    /// launch event: a t3code:// link that cold-launches the app is dropped upstream
    /// (t3code#18613), so a fresh start gets a beat to register its router first.
    static func focus(environmentID: String, threadID: String) async throws {
        var components = URLComponents()
        components.scheme = "t3code"
        components.host = "threads"
        components.path = "/\(environmentID)/\(threadID)"
        guard let link = components.url else { throw CollectFailure.malformed("t3 thread link") }
        let running = await MainActor.run {
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
        let appURL = await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        guard let appURL else { throw ActivationError.notRunning }
        try await Apps.open(appURL)
        if !running { try await Task.sleep(for: .seconds(1)) }
        try await Links.open(link)
    }

    private static func environmentID() -> String? {
        let path = userdata.appendingPathComponent("environment-id").path
        return try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func installed() async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }
    }

    static func threads(database path: String, environmentID: String) throws -> [T3Thread] {
        guard let database = open(path) else { throw CollectFailure.unavailable }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = """
        SELECT t.thread_id, t.title, COALESCE(p.title, ''),
               COALESCE(json_extract(t.payload_json, '$.branch'), ''), t.updated_at
        FROM orchestration_v2_projection_threads AS t
        LEFT JOIN projection_projects AS p ON p.project_id = t.project_id
        WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
        ORDER BY t.updated_at DESC
        LIMIT \(limit)
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(database))
            throw CollectFailure.malformed("t3 sqlite: \(message)")
        }
        defer { sqlite3_finalize(statement) }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var threads: [T3Thread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let updated = text(statement, 4).flatMap { dates.date(from: $0) ?? plain.date(from: $0) } ?? .distantPast
            threads.append(T3Thread(
                threadID: text(statement, 0) ?? "",
                environmentID: environmentID,
                title: text(statement, 1) ?? "",
                project: text(statement, 2) ?? "",
                branch: text(statement, 3) ?? "",
                updatedAt: updated
            ))
        }
        return threads.filter { !$0.threadID.isEmpty }
    }

    private static func open(_ path: String) -> OpaquePointer? {
        var database: OpaquePointer?
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        // Not immutable: fresh writes live in the WAL until a checkpoint, and rows must stay fresh.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2("file:\(escaped)?mode=ro", &database, flags, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        return database
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }
}

import Foundation

public enum RexEvents {
    public static func notices(_ yield: @escaping @Sendable (RexNotice) -> Void) async {
        while !Task.isCancelled {
            await follow(yield)
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Tools that write the same alert twice (OSC 9 and OSC 777 for compatibility, tmux
    /// re-emitting) come through as two events. Drop exact repeats inside a short window;
    /// the same text again later is a new notification.
    struct NoticeDedupe {
        private var seen: [String: Date] = [:]
        static let window: TimeInterval = 2

        mutating func isDuplicate(_ notice: RexNotice) -> Bool {
            seen = seen.filter { notice.date.timeIntervalSince($0.value) < Self.window }
            let key = [notice.blockID, notice.title, notice.body].joined(separator: "\u{1F}")
            defer { seen[key] = notice.date }
            return seen[key] != nil
        }
    }

    private static func follow(_ yield: @escaping @Sendable (RexNotice) -> Void) async {
        guard FileManager.default.isExecutableFile(atPath: Rex.binary) else { return }
        var labels = (try? await sessionLabels()) ?? [:]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Rex.binary)
        process.arguments = ["--timeout", "2s", "--autostart=false", "events", "--all", "--json"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        do {
            try process.run()
        } catch {
            return
        }
        defer { if process.isRunning { process.terminate() } }

        var dedupe = NoticeDedupe()
        await withTaskCancellationHandler {
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    if let (id, label) = sessionCreated(line: line) {
                        labels[id] = label
                    } else if let notice = notice(line: line, labels: labels), !dedupe.isDuplicate(notice) {
                        yield(notice)
                    }
                }
            } catch {
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// One event line → a notice. OSC 9 carries only a body; it becomes the title.
    static func notice(line: String, labels: [String: String], now: Date = Date()) -> RexNotice? {
        guard line.contains("\"desktop_notification\""),
              let wire = try? JSONDecoder().decode(SessionEventWire.self, from: Data(line.utf8)),
              wire.type == "session_event",
              wire.payload.event.type == "block_event",
              wire.payload.event.payload.name == "desktop_notification"
        else { return nil }
        let event = wire.payload.event.payload
        var title = event.payload.title ?? ""
        var body = event.payload.body ?? ""
        if title.isEmpty { (title, body) = (body, "") }
        guard !title.isEmpty else { return nil }
        return RexNotice(
            id: UUID().uuidString,
            blockID: event.block_id,
            sessionID: wire.payload.session_id,
            sessionLabel: labels[wire.payload.session_id] ?? "",
            title: title,
            body: body,
            date: now
        )
    }

    static func sessionCreated(line: String) -> (String, String)? {
        guard line.contains("\"session_created\""),
              let wire = try? JSONDecoder().decode(SessionCreatedWire.self, from: Data(line.utf8)),
              wire.type == "session_created"
        else { return nil }
        return (wire.payload.session.session_id, wire.payload.session.label)
    }

    private static func sessionLabels() async throws -> [String: String] {
        let data = try await Shell.run(
            Rex.binary, ["--timeout", "1s", "--autostart=false", "ls", "--json"], timeout: .seconds(2)
        )
        let list = try JSONDecoder().decode(SessionListWire.self, from: data)
        return Dictionary(list.sessions.map { ($0.session_id, $0.label) }) { first, _ in first }
    }

    private struct SessionEventWire: Decodable {
        var type: String
        var payload: Payload

        struct Payload: Decodable {
            var session_id: String
            var event: Event

            struct Event: Decodable {
                var type: String
                var payload: Block

                struct Block: Decodable {
                    var block_id: String
                    var name: String
                    var payload: Note

                    struct Note: Decodable {
                        var title: String?
                        var body: String?
                    }
                }
            }
        }
    }

    private struct SessionCreatedWire: Decodable {
        var type: String
        var payload: Payload

        struct Payload: Decodable {
            var session: Session

            struct Session: Decodable {
                var session_id: String
                var label: String
            }
        }
    }

    private struct SessionListWire: Decodable {
        var sessions: [Session]

        struct Session: Decodable {
            var session_id: String
            var label: String
        }
    }
}

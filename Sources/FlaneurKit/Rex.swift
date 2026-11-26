import Foundation

enum Rex {
    static let bundleID = "com.superlogical.rex"
    /// The CLI ships inside the Rex server bundle; `Versions/Current` follows updates.
    static let binary = NSHomeDirectory()
        + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
    private static let timeout: Duration = .seconds(2)

    /// One row per block across every session, including detached ones (`block ls` has them,
    /// `session.view` does not), plus one row per session. A missing CLI or a server that is
    /// down is an empty list, not a failure — the same as a browser that is not running.
    static func collect() async throws -> RexListing {
        let sessionsData: Data
        do {
            sessionsData = try await Shell.run(
                binary, ["--timeout", "1s", "--autostart=false", "ls", "--json"], timeout: timeout
            )
        } catch ShellError.launchFailed {
            return RexListing(sessions: [], blocks: [])
        } catch ShellError.exit {
            return RexListing(sessions: [], blocks: [])
        }
        let sessions: [SessionWire]
        do {
            sessions = try JSONDecoder().decode(SessionListWire.self, from: sessionsData).sessions
        } catch {
            throw CollectFailure.malformed(error.localizedDescription)
        }
        var sessionRows: [RexSession] = []
        var blocks: [RexBlock] = []
        for session in sessions {
            // A session that vanishes mid-collect is no failure; the rest still list.
            var placed: [RexBlock] = []
            var windowCount = 0
            if let data = try? await Shell.run(
                binary,
                ["--timeout", "1s", "--autostart=false", "api", "call", "-s", session.session_id, "session.view"],
                timeout: timeout
            ) {
                let view = try parse(view: data)
                placed = view.blocks
                windowCount = view.windowCount
            }
            blocks += placed
            var seen = Set(placed.map(\.blockID))
            if let data = try? await Shell.run(
                binary,
                ["--timeout", "1s", "--autostart=false", "block", "ls", "-s", session.session_id, "--json"],
                timeout: timeout
            ), let listing = try? JSONDecoder().decode(BlockListWire.self, from: data) {
                for block in listing.blocks where seen.insert(block.block_id).inserted && block.placement != "placed" {
                    blocks.append(RexBlock(
                        blockID: block.block_id, windowID: "", sessionID: session.session_id,
                        label: block.label.isEmpty ? "shell" : block.label,
                        windowLabel: "", sessionLabel: session.label, detached: true
                    ))
                }
            }
            sessionRows.append(RexSession(
                sessionID: session.session_id, label: session.label, windowCount: windowCount
            ))
        }
        return RexListing(sessions: sessionRows, blocks: blocks)
    }

    /// The panel is already gone. Rex still comes forward when the focus command fails.
    /// `session.select` shows the session (and tab) in the app first: focusing a block
    /// alone cannot switch the app to another session. `block focus` is best-effort:
    /// a detached block is in no window and rejects it by contract — the session shows.
    static func focus(blockID: String, sessionID: String, windowID: String) async throws {
        _ = try? await Shell.run(
            binary,
            ["--timeout", "1s", "--autostart=false", "do", "session.select", "session_id=\(sessionID)"]
                + (windowID.isEmpty ? [] : ["window_id=\(windowID)"]),
            timeout: timeout
        )
        // Notification rows reach here without a window id; the block knows its own.
        _ = try? await Shell.run(
            binary, ["--timeout", "1s", "--autostart=false", "block", "focus", blockID], timeout: timeout
        )
        try await Apps.activate(bundleID: bundleID)
    }

    static func focus(sessionID: String) async throws {
        _ = try? await Shell.run(
            binary,
            ["--timeout", "1s", "--autostart=false", "do", "session.select", "session_id=\(sessionID)"],
            timeout: timeout
        )
        try await Apps.activate(bundleID: bundleID)
    }

    static func close(blockID: String) async throws {
        _ = try await Shell.run(
            binary, ["--timeout", "1s", "--autostart=false", "block", "close", blockID], timeout: timeout
        )
    }

    static func rows(from data: Data) throws -> [RexBlock] {
        try parse(view: data).blocks
    }

    static func parse(view data: Data) throws -> (windowCount: Int, blocks: [RexBlock]) {
        let view: ViewWire
        do {
            view = try JSONDecoder().decode(ViewWire.self, from: data)
        } catch {
            throw CollectFailure.malformed(error.localizedDescription)
        }
        var seen = Set<String>()
        var rows: [RexBlock] = []
        for window in view.windows {
            for layer in window.layers {
                for block in layer.blocks {
                    guard seen.insert(block.block_id).inserted else { continue }
                    rows.append(RexBlock(
                        blockID: block.block_id,
                        windowID: window.window_id,
                        sessionID: view.session_id,
                        label: block.label.isEmpty ? "shell" : block.label,
                        windowLabel: window.label,
                        sessionLabel: view.label,
                        focused: block.block_id == window.focused_block_id
                            && window.window_id == view.active_window_id
                    ))
                }
            }
        }
        return (view.windows.count, rows)
    }

    private struct SessionListWire: Decodable {
        var sessions: [SessionWire]
    }

    private struct SessionWire: Decodable {
        var session_id: String
        var label: String

        private enum CodingKeys: String, CodingKey { case session_id, label }
    }

    private struct ViewWire: Decodable {
        var session_id: String
        var label: String
        var active_window_id: String?
        var windows: [WindowWire]

        private enum CodingKeys: String, CodingKey { case session_id, label, active_window_id, windows }
    }

    private struct WindowWire: Decodable {
        var window_id: String
        var label: String
        var focused_block_id: String?
        var layers: [LayerWire]

        private enum CodingKeys: String, CodingKey { case window_id, label, focused_block_id, layers }
    }

    private struct LayerWire: Decodable {
        var blocks: [BlockWire]

        private enum CodingKeys: String, CodingKey { case blocks }
    }

    private struct BlockWire: Decodable {
        var block_id: String
        var label: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            block_id = try container.decode(String.self, forKey: .block_id)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        }

        private enum CodingKeys: String, CodingKey { case block_id, label }
    }

    private struct BlockListWire: Decodable {
        var blocks: [BlockEntryWire]
    }

    /// `block ls`: every block in the session; `placement` is "placed" while it lives in a window.
    private struct BlockEntryWire: Decodable {
        var block_id: String
        var label: String
        var placement: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            block_id = try container.decode(String.self, forKey: .block_id)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
            placement = try container.decodeIfPresent(String.self, forKey: .placement)
        }

        private enum CodingKeys: String, CodingKey { case block_id, label, placement }
    }
}

import AppKit
import Foundation

enum Links {
    /// Hands the URL to whatever owns its scheme (default browser, Slack, …) and brings that app forward.
    static func open(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(url, configuration: configuration)
    }
}

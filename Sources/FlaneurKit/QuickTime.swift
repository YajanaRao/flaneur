import AppKit
import Foundation

enum QuickTime {
    static let bundleID = "com.apple.QuickTimePlayerX"
    private static let timeout: Duration = .seconds(20)

    static func collect() async -> [Recording] {
        guard await installed() else { return [] }
        return [Recording(title: "Screen Recording", subtitle: "QuickTime Player")]
    }

    /// `activate` launches the player when it is not running; `new screen recording`
    /// opens the same overlay the menu item does. The red button is still yours.
    static func startScreenRecording() async throws {
        let script = """
        tell application "QuickTime Player"
            activate
            new screen recording
        end tell
        """
        _ = try await Shell.run("/usr/bin/osascript", ["-e", script], timeout: timeout)
    }

    private static func installed() async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }
    }
}

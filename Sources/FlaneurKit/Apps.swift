import AppKit
import Foundation

enum ActivationError: Error {
    case notRunning
    case refused
}

enum Apps {
    static let bundleID = "com.yajanarao.flaneur"

    private static var roots: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
        ]
    }

    static func collect() async -> [AppEntry] {
        let running = await MainActor.run { runningEntries() }
        let taken = Set(running.map { resolve($0.url) })
        let installed = installedEntries(excluding: taken)
        return (running + installed).sorted { lhs, rhs in
            if lhs.running != rhs.running { return lhs.running && !rhs.running }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func open(_ url: URL) async throws {
        let resolved = resolve(url)
        if let app = await MainActor.run(body: { runningMatch(resolved) }) {
            try await activate(app)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    @MainActor
    static func frontmostURL() -> URL? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.bundleIdentifier != bundleID,
              let url = app.bundleURL
        else { return nil }
        return resolve(url)
    }

    static func activate(bundleID: String) async throws {
        guard let app = await MainActor.run(body: {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }) else {
            throw ActivationError.notRunning
        }
        try await activate(app)
    }

    static func quit(_ url: URL) async throws {
        guard let app = await MainActor.run(body: { runningMatch(resolve(url)) }) else {
            throw ActivationError.notRunning
        }
        await MainActor.run { app.terminate() }
    }

    static func restart(_ url: URL) async throws {
        let resolved = resolve(url)
        guard let app = await MainActor.run(body: { runningMatch(resolved) }) else {
            throw ActivationError.notRunning
        }
        await MainActor.run { app.terminate() }
        let deadline = ContinuousClock.now + .seconds(10)
        while !app.isTerminated, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard app.isTerminated else { throw ActivationError.refused }
        try await open(resolved)
    }

    @MainActor
    private static func activate(_ app: NSRunningApplication) throws {
        NSApp.yieldActivation(to: app)
        guard app.activate(options: []) else { throw ActivationError.refused }
    }

    @MainActor
    private static func runningEntries() -> [AppEntry] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular else { return nil }
            guard app.bundleIdentifier != bundleID else { return nil }
            guard let url = app.bundleURL else { return nil }
            let resolved = resolve(url)
            let name = app.localizedName ?? resolved.deletingPathExtension().lastPathComponent
            return AppEntry(url: resolved, name: name, running: true)
        }
    }

    @MainActor
    private static func runningMatch(_ url: URL) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            app.activationPolicy == .regular && app.bundleURL.map(resolve) == url
        }
    }

    private static func installedEntries(excluding taken: Set<URL>) -> [AppEntry] {
        let manager = FileManager.default
        var entries: [AppEntry] = []
        var seen = taken
        for root in roots {
            guard let urls = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where url.pathExtension == "app" {
                let resolved = resolve(url)
                guard seen.insert(resolved).inserted else { continue }
                if Bundle(url: resolved)?.bundleIdentifier == bundleID { continue }
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else { continue }
                let name = resolved.deletingPathExtension().lastPathComponent
                entries.append(AppEntry(url: resolved, name: name, running: false))
            }
        }
        return entries
    }

    private static func resolve(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

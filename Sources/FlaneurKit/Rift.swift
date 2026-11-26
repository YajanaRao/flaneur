import Foundation

public struct RiftWindow: Hashable, Sendable {
    public let id: Int
    public let app: String
    public let bundleID: String
    public let title: String
    public let focused: Bool
    public let workspace: Int
    public let workspaceName: String

    public init(
        id: Int, app: String, bundleID: String, title: String, focused: Bool,
        workspace: Int, workspaceName: String
    ) {
        self.id = id
        self.app = app
        self.bundleID = bundleID
        self.title = title
        self.focused = focused
        self.workspace = workspace
        self.workspaceName = workspaceName
    }
}

public struct RiftWorkspace: Hashable, Sendable {
    public let index: Int
    public let name: String
    public let focused: Bool
    public let icon: String?
    public let apps: [String]
    public let titles: [String]

    public init(
        index: Int, name: String, focused: Bool, icon: String?, apps: [String], titles: [String]
    ) {
        self.index = index
        self.name = name
        self.focused = focused
        self.icon = icon
        self.apps = apps
        self.titles = titles
    }

    public var windowCount: Int { titles.count }
}

public struct RiftListing: Sendable {
    public let workspaces: [RiftWorkspace]
    public let windows: [RiftWindow]

    public init(workspaces: [RiftWorkspace], windows: [RiftWindow]) {
        self.workspaces = workspaces
        self.windows = windows
    }
}

enum Rift {
    static let binary = "/opt/homebrew/bin/rift-cli"
    private static let timeout: Duration = .seconds(2)

    static func collect() async throws -> RiftListing {
        let data = try await Shell.run(binary, ["query", "workspaces"], timeout: timeout)
        return try listing(from: data)
    }

    static func focus(workspace index: Int) async throws {
        _ = try await Shell.run(binary, ["execute", "workspace", "switch", String(index)], timeout: timeout)
    }

    static func focus(window id: Int) async throws {
        _ = try await Shell.run(binary, ["execute", "window", "focus", "--window-server-id", String(id)], timeout: timeout)
    }

    static func move(window id: Int, toWorkspace index: Int) async throws {
        _ = try await Shell.run(
            binary, ["execute", "workspace", "move-window", String(index), String(id)],
            timeout: timeout
        )
    }

    static func fullscreen(window id: Int) async throws {
        try await focus(window: id)
        _ = try await Shell.run(binary, ["execute", "window", "toggle-fullscreen"], timeout: timeout)
    }

    static func close(window id: Int) async throws {
        _ = try await Shell.run(binary, ["execute", "window", "close", "--window-id", String(id)], timeout: timeout)
    }

    /// Restart the window manager: the fix when rift's event pipeline has silently died
    /// and stopped managing new apps' windows. Re-adopts every window; nothing closes.
    /// `rift-cli service` is a deprecated no-op stub — the commands moved to the `rift`
    /// binary, which only knows its own launchd label. Rift runs supervised one of two
    /// ways — brew services (`sh.brew.rift`) or `rift service install`
    /// (`git.acsandmann.rift`) — so kick whichever label is loaded.
    static func restart() async throws {
        let uid = getuid()
        for label in ["sh.brew.rift", "git.acsandmann.rift"] {
            let target = "gui/\(uid)/\(label)"
            guard (try? await Shell.run("/bin/launchctl", ["print", target], timeout: timeout)) != nil
            else { continue }
            _ = try await Shell.run("/bin/launchctl", ["kickstart", "-k", target], timeout: .seconds(15))
            return
        }
        throw RestartError.unsupervised
    }

    enum RestartError: Error, Sendable {
        case unsupervised
    }

    static func listing(from data: Data) throws -> RiftListing {
        let wire = try JSONDecoder().decode([WorkspaceWire].self, from: data)
        var workspaces: [RiftWorkspace] = []
        var windows: [RiftWindow] = []
        for workspace in wire {
            let ours = workspace.windows.map { window in
                RiftWindow(
                    id: window.window_server_id,
                    app: window.app_name,
                    bundleID: window.bundle_id,
                    title: window.title,
                    focused: window.is_focused,
                    workspace: workspace.index,
                    workspaceName: workspace.name
                )
            }
            windows.append(contentsOf: ours)
            var apps: [String] = []
            for app in ours.map(\.app) where !apps.contains(app) { apps.append(app) }
            workspaces.append(RiftWorkspace(
                index: workspace.index,
                name: workspace.name,
                focused: workspace.is_focused,
                icon: ours.first?.bundleID,
                apps: apps,
                titles: ours.map(\.title)
            ))
        }
        return RiftListing(workspaces: workspaces, windows: windows)
    }

    private struct WorkspaceWire: Decodable {
        let index: Int
        let name: String
        let is_focused: Bool
        let windows: [WindowWire]
    }

    private struct WindowWire: Decodable {
        let app_name: String
        let bundle_id: String
        let title: String
        let is_focused: Bool
        let window_server_id: Int
    }
}

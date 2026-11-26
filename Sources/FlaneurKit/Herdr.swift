import Darwin
import Foundation

enum Herdr {
    static let binary = "/opt/homebrew/bin/herdr"
    private static let timeout: Duration = .seconds(2)
    private static let socketTimeout: TimeInterval = 0.8
    private static let ghostty = Terminal.bundleID

    static func collect() async throws -> [HerdrPane] {
        let loaded: [HerdrPane]
        if let data = await socket(method: "session.snapshot", params: [:]), usable(data) {
            loaded = try panes(from: data)
        } else {
            let data = try await Shell.run(binary, ["api", "snapshot"], timeout: timeout)
            loaded = try panes(from: data)
        }
        let services = await services(for: loaded)
        return loaded.map { showing(services[$0.pane.raw], on: $0) }
    }

    static func focus(agent pane: PaneID) async throws {
        try await focus(["agent", "focus", pane.raw])
    }

    static func focus(tab: TabID) async throws {
        try await focus(["tab", "focus", tab.raw])
    }

    static func focus(workspace id: String) async throws {
        try await focus(["workspace", "focus", id])
    }

    /// The CLI can focus a tab, not a pane. The socket can focus the pane itself.
    static func focus(named pane: PaneID, tab: TabID) async throws {
        if let data = await socket(method: "pane.focus", params: ["pane_id": pane.raw]), usable(data) {
            try await Apps.activate(bundleID: ghostty)
            return
        }
        try await focus(["tab", "focus", tab.raw])
    }

    static func close(tab: TabID) async throws {
        _ = try await Shell.run(binary, ["tab", "close", tab.raw], timeout: timeout)
    }

    static func service(from data: Data) -> String? {
        guard let info = try? JSONDecoder().decode(ProcessEnvelope.self, from: data).result?.running else {
            return nil
        }
        let processes = info.foreground_processes
        if let group = info.foreground_process_group_id,
           let leader = processes.first(where: { $0.pid == group }),
           let label = serviceText(leader)
        {
            return label
        }
        return processes.compactMap(serviceText).first
    }

    static func showing(_ service: String?, on pane: HerdrPane) -> HerdrPane {
        let service = clean(service)
        guard !service.isEmpty else { return pane }
        let described = normalize("\(pane.title) \(pane.subtitle)")
        if described.contains(normalize(service)) { return pane }
        let subtitle = pane.subtitle.isEmpty ? service : "\(service) · \(pane.subtitle)"
        var terms = pane.terms
        terms.append(service)
        return HerdrPane(
            pane: pane.pane, tab: pane.tab, title: pane.title, subtitle: subtitle, agent: pane.agent,
            status: pane.status, focused: pane.focused, kind: pane.kind, workspaceID: pane.workspaceID,
            terms: terms
        )
    }

    static func panes(from data: Data) throws -> [HerdrPane] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw CollectFailure.malformed(error.localizedDescription)
        }
        guard let snapshot = envelope.result.snapshot else {
            throw CollectFailure.malformed("session snapshot")
        }
        return rows(snapshot)
    }

    private static func focus(_ arguments: [String]) async throws {
        do {
            _ = try await Shell.run(binary, arguments, timeout: timeout)
        } catch {
        }
        try await Apps.activate(bundleID: ghostty)
    }

    private static func services(for panes: [HerdrPane]) async -> [String: String] {
        var seen = Set<String>()
        var labels: [String: String] = [:]
        for pane in panes where pane.kind != .workspace {
            let id = pane.pane.raw
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            guard let data = await socket(method: "pane.process_info", params: ["pane_id": id]),
                  let label = service(from: data)
            else { continue }
            labels[id] = label
        }
        return labels
    }

    private static func serviceText(_ process: ForegroundProcess) -> String? {
        let cmdline = clean(process.cmdline)
        let name = clean(process.name)
        if isShell(name) || isShell(cmdline) { return nil }
        if cmdline.contains("/node_modules/") || cmdline.contains("/.npm/") || cmdline.contains(" --service") {
            return nil
        }
        if !cmdline.isEmpty, !cmdline.hasPrefix("/"), cmdline.count <= 60 { return cmdline }
        if isRuntime(name) || name.isEmpty { return nil }
        return name
    }

    private static func isShell(_ text: String) -> Bool {
        guard let word = text.split(whereSeparator: \.isWhitespace).first else { return false }
        var name = String(word).lowercased()
        if name.hasPrefix("-") { name.removeFirst() }
        return ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "nu", "pwsh"].contains(name)
    }

    private static func isRuntime(_ name: String) -> Bool {
        ["node", "nodejs", "python", "python3", "ruby", "perl", "java", "deno"].contains(name.lowercased())
    }

    private static func socket(method: String, params: [String: String]) async -> Data? {
        guard let path = socketPath() else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? Socket.call(path: path, method: method, params: params, timeout: socketTimeout)
        }.value
    }

    private static func socketPath() -> String? {
        if let path = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"], !path.isEmpty {
            return path
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/herdr/herdr.sock").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static func usable(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let error = object["error"] {
            if error is NSNull { return object["result"] != nil }
            return false
        }
        return object["result"] != nil
    }

    private static func rows(_ snapshot: SnapshotWire) -> [HerdrPane] {
        let workspaces = Dictionary(snapshot.workspaces.map { ($0.workspace_id, $0) }, uniquingKeysWith: { first, _ in first })
        let tabs = Dictionary(snapshot.tabs.map { ($0.tab_id, $0) }, uniquingKeysWith: { first, _ in first })
        let panes = Dictionary(snapshot.panes.map { ($0.pane_id, $0) }, uniquingKeysWith: { first, _ in first })
        var agentIDs: [String] = []
        var seenAgents = Set<String>()
        for agent in snapshot.agents where seenAgents.insert(agent.pane_id).inserted {
            agentIDs.append(agent.pane_id)
        }
        for pane in snapshot.panes where !clean(pane.agent).isEmpty && seenAgents.insert(pane.pane_id).inserted {
            agentIDs.append(pane.pane_id)
        }
        let agentTabs = Set(agentIDs.compactMap { paneID -> String? in
            if let tabID = panes[paneID]?.tab_id { return tabID }
            return snapshot.agents.first { $0.pane_id == paneID }?.tab_id
        })
        let agentByPane = Dictionary(snapshot.agents.map { ($0.pane_id, $0) }, uniquingKeysWith: { first, _ in first })

        var rows: [HerdrPane] = []
        var running: [String: [(agent: String, row: HerdrPane)]] = [:]
        for paneID in agentIDs {
            let pane = panes[paneID]
            let agent = agentByPane[paneID]
            let tabID = pane?.tab_id ?? agent?.tab_id ?? ""
            guard !paneID.isEmpty, !tabID.isEmpty else { continue }
            let tab = tabs[tabID]
            let workspaceID = pane?.workspace_id ?? agent?.workspace_id ?? tab?.workspace_id ?? ""
            let row = make(
                kind: .agent,
                paneID: paneID,
                tabID: tabID,
                workspaceID: workspaceID,
                workspace: workspaces[workspaceID],
                tab: tab,
                cwd: pane?.foreground_cwd ?? pane?.cwd ?? agent?.cwd,
                summary: pane?.terminal_title_stripped ?? pane?.terminal_title ?? agent?.terminal_title_stripped ?? agent?.terminal_title,
                paneLabel: pane?.label,
                agent: agent?.agent ?? pane?.agent,
                status: agent?.agent_status ?? pane?.agent_status,
                focused: paneID == snapshot.focused_pane_id
            )
            rows.append(row)
            running[workspaceID, default: []].append((clean(agent?.agent ?? pane?.agent), row))
        }

        for tab in snapshot.tabs where !agentTabs.contains(tab.tab_id) {
            let members = snapshot.panes.filter { $0.tab_id == tab.tab_id }
            let pane = members.first
            let workspaceID = tab.workspace_id ?? pane?.workspace_id ?? ""
            rows.append(make(
                kind: .tab,
                paneID: pane?.pane_id ?? tab.tab_id,
                tabID: tab.tab_id,
                workspaceID: workspaceID,
                workspace: workspaces[workspaceID],
                tab: tab,
                cwd: pane?.foreground_cwd ?? pane?.cwd,
                summary: pane?.terminal_title_stripped ?? pane?.terminal_title,
                paneLabel: nil,
                agent: nil,
                status: pane?.agent_status ?? tab.agent_status,
                focused: tab.tab_id == snapshot.focused_tab_id || members.contains { $0.pane_id == snapshot.focused_pane_id }
            ))
        }

        for pane in snapshot.panes {
            let label = clean(pane.label)
            guard !label.isEmpty else { continue }
            let tab = tabs[pane.tab_id]
            rows.append(make(
                kind: .named,
                paneID: pane.pane_id,
                tabID: pane.tab_id,
                workspaceID: pane.workspace_id ?? tab?.workspace_id ?? "",
                workspace: workspaces[pane.workspace_id ?? ""],
                tab: tab,
                cwd: pane.foreground_cwd ?? pane.cwd,
                summary: tabLabel(tab),
                paneLabel: label,
                agent: pane.agent,
                status: pane.agent_status,
                focused: pane.pane_id == snapshot.focused_pane_id && !agentIDs.contains(pane.pane_id)
            ))
        }

        if snapshot.workspaces.count > 1 {
            for workspace in snapshot.workspaces {
                let label = clean(workspace.label)
                let title = label.isEmpty ? "workspace \(workspace.number.map(String.init) ?? workspace.workspace_id)" : label
                let inside = running[workspace.workspace_id] ?? []
                var names: [String] = []
                for entry in inside where !entry.agent.isEmpty && !names.contains(entry.agent) {
                    names.append(entry.agent)
                }
                var subtitle = names
                if inside.count == 1, let only = inside.first {
                    subtitle.append(only.row.title)
                }
                let status = inside.map(\.row.status).min { urgency($0) < urgency($1) } ?? ""
                rows.append(HerdrPane(
                    pane: PaneID(raw: "workspace:\(workspace.workspace_id)"),
                    tab: TabID(raw: ""),
                    title: title,
                    subtitle: subtitle.joined(separator: " · "),
                    agent: !inside.isEmpty,
                    status: status,
                    focused: false,
                    kind: .workspace,
                    workspaceID: workspace.workspace_id,
                    terms: [title, workspace.workspace_id] + names + inside.map(\.row.title)
                ))
            }
        }
        return rows
    }

    private static func make(
        kind: HerdrKind,
        paneID: String,
        tabID: String,
        workspaceID: String,
        workspace: WorkspaceWire?,
        tab: TabWire?,
        cwd rawCWD: String?,
        summary rawSummary: String?,
        paneLabel: String?,
        agent rawAgent: String?,
        status rawStatus: String?,
        focused: Bool
    ) -> HerdrPane {
        let workspaceLabel = clean(workspace?.label)
        let cwd = shorten(clean(rawCWD))
        let agent = clean(rawAgent)
        let customTab = tabLabel(tab)
        let summary = presentable(clean(rawSummary), cwd: cwd, workspace: workspaceLabel)
        let named = clean(paneLabel)
        let title: String
        if kind == .named, !named.isEmpty {
            title = named
        } else if !customTab.isEmpty {
            title = customTab
        } else if !summary.isEmpty {
            title = summary
        } else if !workspaceLabel.isEmpty {
            title = workspaceLabel
        } else {
            title = tabID
        }
        let detail = summary.isEmpty || normalize(summary) == normalize(title) ? "" : summary
        var subtitle: [String] = []
        if !workspaceLabel.isEmpty, normalize(workspaceLabel) != normalize(title) {
            subtitle.append(workspaceLabel)
        }
        if !agent.isEmpty, normalize(agent) != normalize(title) {
            subtitle.append(agent)
        }
        let tail = detail.isEmpty ? cwd : detail
        if !tail.isEmpty, normalize(tail) != normalize(title) {
            subtitle.append(tail)
        }
        var terms = [workspaceLabel, cwd, agent, detail, summary]
        if let number = tab?.number { terms.append("#\(number)") }
        return HerdrPane(
            pane: PaneID(raw: paneID),
            tab: TabID(raw: tabID),
            title: title,
            subtitle: subtitle.joined(separator: " · "),
            agent: kind == .agent || !agent.isEmpty,
            status: statusLabel(agent: agent, raw: rawStatus),
            focused: focused,
            kind: kind,
            workspaceID: workspaceID,
            terms: terms
        )
    }

    private static func tabLabel(_ tab: TabWire?) -> String {
        let label = clean(tab?.label)
        if label.isEmpty { return "" }
        if let number = tab?.number, label == String(number) { return "" }
        return label
    }

    private static func presentable(_ summary: String, cwd: String, workspace: String) -> String {
        guard let marker = summary.range(of: " | ", options: .backwards) else { return summary }
        let head = clean(String(summary[..<marker.lowerBound]))
        let suffix = normalize(String(summary[marker.upperBound...]))
        let folder = normalize(basename(cwd))
        let space = normalize(workspace)
        if !head.isEmpty, (!folder.isEmpty && suffix == folder) || (!space.isEmpty && suffix == space) {
            return head
        }
        return summary
    }

    private static func urgency(_ status: String) -> Int {
        ["blocked", "done", "working", "idle", "unknown"].firstIndex(of: status) ?? 5
    }

    private static func statusLabel(agent: String, raw: String?) -> String {
        let status = clean(raw).lowercased()
        if status.isEmpty || status == "none" { return "" }
        if status == "unknown" { return agent.isEmpty ? "" : "unknown" }
        return status
    }

    private static func clean(_ text: String?) -> String {
        guard let text else { return "" }
        var kept = ""
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            if scalar == "\u{1B}" {
                // Drop a CSI sequence, ESC [ ... final byte, along with the escape itself.
                if let next = scalars.next(), next == "[" {
                    while let parameter = scalars.next(), parameter.value < 0x40 {}
                }
                continue
            }
            if scalar.value >= 32 || scalar == "\t" {
                kept.unicodeScalars.append(scalar)
            }
        }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shorten(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static func basename(_ path: String) -> String {
        var text = path
        if text.hasSuffix("/") { text.removeLast() }
        if text == "~" { return "" }
        return (text as NSString).lastPathComponent
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private struct ProcessEnvelope: Decodable {
        var result: ProcessResult?
    }

    private struct ProcessResult: Decodable {
        var running: RunningProcesses?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            running = try container.decodeIfPresent(RunningProcesses.self, forKey: .process_info)
        }

        private enum CodingKeys: String, CodingKey { case process_info }
    }

    private struct RunningProcesses: Decodable {
        var foreground_process_group_id: Int?
        var foreground_processes: [ForegroundProcess] = []

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            foreground_process_group_id = decodeInt(container, .foreground_process_group_id)
            foreground_processes = try container.decodeIfPresent([ForegroundProcess].self, forKey: .foreground_processes) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case foreground_process_group_id, foreground_processes
        }
    }

    private struct ForegroundProcess: Decodable {
        var pid: Int
        var name: String
        var cmdline: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pid = decodeInt(container, .pid) ?? -1
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            cmdline = try container.decodeIfPresent(String.self, forKey: .cmdline)
        }

        private enum CodingKeys: String, CodingKey { case pid, name, cmdline }
    }

    private struct Envelope: Decodable {
        var result: ResultBody
    }

    private struct ResultBody: Decodable {
        var snapshot: SnapshotWire?
    }

    private struct SnapshotWire: Decodable {
        var workspaces: [WorkspaceWire] = []
        var tabs: [TabWire] = []
        var panes: [PaneWire] = []
        var agents: [AgentWire] = []
        var focused_pane_id: String?
        var focused_tab_id: String?
        var focused_workspace_id: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            workspaces = try container.decodeIfPresent([WorkspaceWire].self, forKey: .workspaces) ?? []
            tabs = try container.decodeIfPresent([TabWire].self, forKey: .tabs) ?? []
            panes = try container.decodeIfPresent([PaneWire].self, forKey: .panes) ?? []
            agents = try container.decodeIfPresent([AgentWire].self, forKey: .agents) ?? []
            focused_pane_id = try container.decodeIfPresent(String.self, forKey: .focused_pane_id)
            focused_tab_id = try container.decodeIfPresent(String.self, forKey: .focused_tab_id)
            focused_workspace_id = try container.decodeIfPresent(String.self, forKey: .focused_workspace_id)
        }

        private enum CodingKeys: String, CodingKey {
            case workspaces, tabs, panes, agents, focused_pane_id, focused_tab_id, focused_workspace_id
        }
    }

    private struct WorkspaceWire: Decodable {
        var workspace_id: String
        var label: String?
        var number: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            workspace_id = try container.decode(String.self, forKey: .workspace_id)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            number = decodeInt(container, .number)
        }

        private enum CodingKeys: String, CodingKey { case workspace_id, label, number }
    }

    private struct TabWire: Decodable {
        var tab_id: String
        var workspace_id: String?
        var label: String?
        var number: Int?
        var agent_status: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tab_id = try container.decode(String.self, forKey: .tab_id)
            workspace_id = try container.decodeIfPresent(String.self, forKey: .workspace_id)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            number = decodeInt(container, .number)
            agent_status = try container.decodeIfPresent(String.self, forKey: .agent_status)
        }

        private enum CodingKeys: String, CodingKey {
            case tab_id, workspace_id, label, number, agent_status
        }
    }

    private struct PaneWire: Decodable {
        var pane_id: String
        var tab_id: String
        var workspace_id: String?
        var cwd: String?
        var foreground_cwd: String?
        var terminal_title: String?
        var terminal_title_stripped: String?
        var label: String?
        var agent: String?
        var agent_status: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pane_id = try container.decode(String.self, forKey: .pane_id)
            tab_id = try container.decode(String.self, forKey: .tab_id)
            workspace_id = try container.decodeIfPresent(String.self, forKey: .workspace_id)
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
            foreground_cwd = try container.decodeIfPresent(String.self, forKey: .foreground_cwd)
            terminal_title = try container.decodeIfPresent(String.self, forKey: .terminal_title)
            terminal_title_stripped = try container.decodeIfPresent(String.self, forKey: .terminal_title_stripped)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            agent = try container.decodeIfPresent(String.self, forKey: .agent)
            agent_status = try container.decodeIfPresent(String.self, forKey: .agent_status)
        }

        private enum CodingKeys: String, CodingKey {
            case pane_id, tab_id, workspace_id, cwd, foreground_cwd, terminal_title, terminal_title_stripped
            case label, agent, agent_status
        }
    }

    private struct AgentWire: Decodable {
        var pane_id: String
        var tab_id: String?
        var workspace_id: String?
        var cwd: String?
        var terminal_title: String?
        var terminal_title_stripped: String?
        var agent: String?
        var agent_status: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pane_id = try container.decode(String.self, forKey: .pane_id)
            tab_id = try container.decodeIfPresent(String.self, forKey: .tab_id)
            workspace_id = try container.decodeIfPresent(String.self, forKey: .workspace_id)
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
            terminal_title = try container.decodeIfPresent(String.self, forKey: .terminal_title)
            terminal_title_stripped = try container.decodeIfPresent(String.self, forKey: .terminal_title_stripped)
            agent = try container.decodeIfPresent(String.self, forKey: .agent)
            agent_status = try container.decodeIfPresent(String.self, forKey: .agent_status)
        }

        private enum CodingKeys: String, CodingKey {
            case pane_id, tab_id, workspace_id, cwd, terminal_title, terminal_title_stripped, agent, agent_status
        }
    }
}

private func decodeInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
    if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
    if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
    if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Int(value) }
    return nil
}

private enum Socket {
    static func call(path: String, method: String, params: [String: String], timeout: TimeInterval) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ShellError.launchFailed }
        defer { Darwin.close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = path.withCString { source -> Int in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                guard let base = destination.baseAddress else { return 0 }
                let count = min(destination.count - 1, Int(strlen(source)))
                memcpy(base, source, count)
                return count
            }
        }
        guard copied > 0 else { throw ShellError.launchFailed }
        let length = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + copied + 1)
        address.sun_len = UInt8(clamping: Int(length))
        var budget = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &budget, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &budget, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard connected == 0 else { throw ShellError.launchFailed }

        let object: [String: Any] = ["id": "flaneur", "method": method, "params": params]
        var payload = try JSONSerialization.data(withJSONObject: object)
        payload.append(0x0A)
        try writeAll(fd, payload)

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !received.contains(0x0A) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT { throw ShellError.timedOut }
                throw ShellError.launchFailed
            }
            received.append(buffer, count: count)
            if received.count > 8_000_000 { throw ShellError.launchFailed }
        }
        guard let newline = received.firstIndex(of: 0x0A) else { throw ShellError.launchFailed }
        return received[..<newline]
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT { throw ShellError.timedOut }
                    throw ShellError.launchFailed
                }
                sent += count
            }
        }
    }
}

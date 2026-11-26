import AppKit
import Foundation
import Observation

public enum Source: Hashable, Sendable {
    case herdr
    case rex
    case rift
    case t3
    case slack
    case contacts
    case groups
    case browser(Browser)
    case apps
    case projects
    case quickTime
    case clipboard

    public static var allCases: [Source] {
        [.herdr, .rex, .rift, .t3, .slack, .contacts, .groups] + Browser.allCases.map { .browser($0) } + [.apps, .projects, .quickTime, .clipboard]
    }

    var name: String {
        switch self {
        case .herdr: "herdr"
        case .rex: "rex"
        case .rift: "rift"
        case .t3: "t3"
        case .slack: "slack"
        case .contacts: "contacts"
        case .groups: "groups"
        case .browser(let browser): browser.displayName
        case .apps: "apps"
        case .projects: "projects"
        case .quickTime: "quicktime"
        case .clipboard: "clipboard"
        }
    }
}

public enum CollectFailure: Error, Equatable, Hashable, Sendable {
    case unavailable
    case timedOut
    case denied
    case malformed(String)

    var summary: String {
        switch self {
        case .unavailable, .malformed: "unavailable"
        case .timedOut: "timed out"
        case .denied: "denied"
        }
    }

    static func from(_ error: Error) -> CollectFailure {
        if let failure = error as? CollectFailure { return failure }
        guard let shell = error as? ShellError else { return .malformed(String(describing: error)) }
        switch shell {
        case .launchFailed:
            return .unavailable
        case .timedOut:
            return .timedOut
        case .exit(let code, let stderr):
            let text = stderr.lowercased()
            if code == -1743 || text.contains("-1743") || text.contains("not authorized")
                || text.contains("not permitted")
            {
                return .denied
            }
            return .unavailable
        }
    }
}

public enum Snapshot: Sendable {
    case panes(Result<[HerdrPane], CollectFailure>)
    case blocks(Result<RexListing, CollectFailure>)
    case riftLayout(Result<RiftListing, CollectFailure>, restartable: Bool)
    case t3Threads(Result<[T3Thread], CollectFailure>)
    case messages(Result<[SlackMessage], CollectFailure>)
    case contacts(Result<[SlackContact], CollectFailure>)
    case groups(Result<[SlackGroup], CollectFailure>)
    case tabs(Result<[BrowserTab], CollectFailure>)
    case apps([AppEntry])
    case projects([ProjectFolder])
    case recordings([Recording])
    case clips([Clip])
}

public enum Direction: Sendable {
    case up, down
}

public enum QueryScope: String, Sendable {
    case clips = "c"
    case workspaces = "w"
    case apps = "a"
    case tabs = "t"
    case brave = "b"
    case yab = "y"
    case herdr = "h"
    case rex = "r"
    case notifications = "n"
    case slack = "s"
    case t3 = "3"
    case gitHub = "g"

    static func parse(_ query: String) -> (scope: QueryScope?, text: String) {
        if query.count == 1, let scope = QueryScope(rawValue: query) {
            return (scope, "")
        }
        guard query.hasPrefix(","), let letter = query.dropFirst().first,
              let scope = QueryScope(rawValue: String(letter))
        else { return (nil, query) }
        var rest = String(query.dropFirst(2))
        if rest.hasPrefix(" ") { rest.removeFirst() }
        return (scope, rest)
    }

    func contains(_ item: Item) -> Bool {
        let source = item.source
        switch self {
        case .clips: return source == .clipboard
        case .workspaces: return source == .rift
        case .apps: return source == .apps
        case .tabs: if case .browser = source { return true } else { return false }
        case .brave: return source == .browser(.brave)
        case .yab: return source == .browser(.yab)
        case .herdr: return source == .herdr
        case .rex: return source == .rex
        case .notifications: if case .notice = item { return true } else { return false }
        case .slack: return [.slack, .contacts, .groups].contains(source)
        case .t3: return source == .t3
        case .gitHub:
            if case .project(let project) = item { return project.repository != nil }
            return false
        }
    }
}

public enum Event: Sendable {
    case toggle
    case query(String)
    case move(Direction)
    case submit
    /// ⌃O — open the selected row's link in the default browser.
    case open
    /// ⌃Y — copy the selected row's link.
    case yank
    /// ⌘W — close the selected tab, window, or block. The panel stays up.
    case close
    /// ⌘1…0 — move the selected rift window to that workspace. The panel closes; focus stays.
    case moveWindow(Int)
    /// ⌃F — focus the selected rift window and toggle true fullscreen.
    case fullscreen
    /// ⌃⇧Q — quit the selected app.
    case quit
    /// ⌘R — restart the selected app.
    case restart
    /// ⌃R — run a GitHub workflow for the selected repository.
    case runWorkflow
    /// ⌃U — clear the search line.
    case clearLine
    /// The app that was frontmost before the panel took focus.
    case frontmost(URL?)
    case escape
    case backspace
    case resigned
    case settled
    case collected(Source, generation: Int, Snapshot)
    /// Rows from a collect that is still running. Does not finish that collect.
    case updated(Source, generation: Int, Snapshot)
    case activationFailed(generation: Int)
    /// A rex desktop notification arrived. Lands as an unread row, panel open or not.
    case noticed(RexNotice)
    /// The banner was clicked in Notification Center: open the block, forget the notice.
    case noticeOpened(String)
}

public enum Effect: Equatable, Sendable {
    case present
    case dismiss(restoreFocus: Bool)
    case collect(Source, generation: Int)
    case perform(Action, generation: Int)
    case copy(String)
}

public enum ResignArm: Equatable, Sendable {
    case settling, live
}

public enum Phase: Equatable, Sendable {
    case hidden
    case visible(ResignArm)
}

public enum Selection: Equatable, Sendable {
    case top
    case pinned(Item.ID)
}

struct WorkflowRunState: Sendable {
    enum Step: Sendable {
        case workflows
        case branches(Workflow)
        case input(Workflow, branch: String, index: Int)
    }

    let project: ProjectFolder
    let returnQuery: String
    var step = Step.workflows
    var values: [String: String] = [:]
}

public struct LauncherState: Sendable {
    public private(set) var phase: Phase = .hidden
    public private(set) var generation = 0
    public private(set) var query = ""
    private var storedSelection: Selection = .top
    private var slots: [Source: Slot] = [:]
    private var notices: [RexNotice] = []
    private var inFlight: Set<Source> = []
    private var closed: Set<Closed> = []
    private var workflowRun: WorkflowRunState?
    private var activeScope: QueryScope?

    fileprivate var recents: Recents
    private var frontmost: URL? = nil

    init(recents: Recents = Recents()) {
        self.recents = recents
    }

    public var selection: Selection {
        switch storedSelection {
        case .top:
            return .top
        case .pinned(let id):
            return rankedItems().contains(where: { $0.id == id }) ? storedSelection : .top
        }
    }

    var prompt: String {
        if let run = workflowRun {
            switch run.step {
            case .workflows:
                return "\(run.project.name) · Select workflow"
            case .branches(let workflow):
                return "\(run.project.name) › \(workflow.name) · Select branch"
            case .input(let workflow, let branch, let index):
                let input = workflow.inputs[index]
                return "\(workflow.name) › \(branch) · \(input.description.isEmpty ? input.name : input.description)"
            }
        }
        switch activeScope {
        case .clips?: return "Search clipboard"
        case .gitHub?: return "Search GitHub repositories"
        default: return "Search"
        }
    }

    var canPopPickerOnBackspace: Bool {
        query.isEmpty && (activeScope != nil || workflowRun != nil)
    }

    var rows: [PresentedRow] {
        let hits = ranked()
        let selectedID: Item.ID?
        switch selection {
        case .top:
            selectedID = hits.first?.item.id
        case .pinned(let id):
            selectedID = id
        }
        return hits.map { hit in
            PresentedRow(
                id: hit.item.id,
                title: hit.item.title,
                subtitle: hit.item.subtitle,
                icon: hit.item.icon,
                badge: hit.item.status,
                selected: hit.item.id == selectedID,
                titleMarks: hit.title,
                subtitleMarks: hit.subtitle,
                badgeMarks: hit.badge
            )
        }
    }

    public var failures: [String] {
        Source.allCases.compactMap { source in
            if source == .herdr { return nil }
            guard let failure = slots[source]?.failure else { return nil }
            return "\(source.name) \(failure.summary)"
        }
    }

    public struct FooterItem: Equatable, Sendable, Identifiable {
        public let title: String
        public let keyLabel: String
        public var id: String { title }
    }

    public var footer: [FooterItem] {
        var items: [FooterItem] = []
        if let item = selectedItem(in: rankedItems()) {
            var sawMove = false
            for action in item.actions {
                if case .moveWindow = action.chord {
                    if !sawMove { items.append(FooterItem(title: "Move to Workspace", keyLabel: "⌘1–0")) }
                    sawMove = true
                    continue
                }
                items.append(FooterItem(title: action.title, keyLabel: action.keyLabel))
            }
        }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(FooterItem(title: "Clear", keyLabel: "⌃U"))
        }
        return items
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .toggle:
            if case .visible = phase { return hide(restoreFocus: true) }
            return show()
        case .escape:
            if workflowRun != nil { return popWorkflow() }
            if activeScope != nil { return leaveScope() }
            return hide(restoreFocus: true)
        case .backspace:
            guard canPopPickerOnBackspace else { return [] }
            if workflowRun != nil { return popWorkflow() }
            return leaveScope()
        case .resigned:
            guard case .visible(.live) = phase else { return [] }
            return hide(restoreFocus: false)
        case .settled:
            guard case .visible(.settling) = phase else { return [] }
            phase = .visible(.live)
            return []
        case .query(let text):
            guard case .visible = phase else { return [] }
            if activeScope == nil, workflowRun == nil, let scope = Self.scopeHandoff(text) {
                activeScope = scope
                query = ""
            } else {
                query = text
            }
            storedSelection = .top
            return []
        case .clearLine:
            guard case .visible = phase else { return [] }
            query = ""
            storedSelection = .top
            return []
        case .frontmost(let url):
            guard case .visible = phase else { return [] }
            frontmost = url
            return []
        case .move(let direction):
            guard case .visible = phase else { return [] }
            let items = rankedItems()
            guard !items.isEmpty else { return [] }
            let current: Int
            switch selection {
            case .top:
                current = 0
            case .pinned(let id):
                current = items.firstIndex { $0.id == id } ?? 0
            }
            let delta = direction == .up ? -1 : 1
            let next = min(max(current + delta, 0), items.count - 1)
            storedSelection = .pinned(items[next].id)
            return []
        case .submit:
            return act(.enter)
        case .open:
            return act(.open)
        case .yank:
            return act(.yank)
        case .close:
            guard case .visible = phase else { return [] }
            let items = rankedItems()
            guard let item = selectedItem(in: items), let action = item.close else { return [] }
            let index = items.firstIndex { $0.id == item.id } ?? 0
            if case .notice(let notice) = item {
                notices.removeAll { $0.id == notice.id }
                let rest = rankedItems()
                storedSelection = rest.isEmpty ? .top : .pinned(rest[min(index, rest.count - 1)].id)
                return []
            }
            switch action {
            case .closeHerdr(let tab):
                closed.insert(.herdr(tab))
            case .closeRex(let blockID):
                closed.insert(.rex(blockID))
            case .closeBrowser(let browser, let windowID, let tabID):
                closed.insert(.browser(browser, windowID: windowID, tabID: tabID))
            case .riftClose(let windowID):
                closed.insert(.rift(windowID))
            default:
                return []
            }
            let following = items.suffix(from: index + 1).first { !isClosed($0) }
            let previous = items.prefix(index).last { !isClosed($0) }
            dropClosed()
            if let following {
                storedSelection = .pinned(following.id)
            } else if let previous {
                storedSelection = .pinned(previous.id)
            } else {
                storedSelection = .top
            }
            return [.perform(action, generation: generation)]
        case .moveWindow(let index):
            return act(.moveWindow(index))
        case .fullscreen:
            return act(.fullscreen)
        case .quit:
            return act(.quit)
        case .restart:
            return act(.restart)
        case .runWorkflow:
            return act(.runWorkflow)
        case .updated(let source, let generation, let snapshot):
            guard inFlight.contains(source) else { return [] }
            if let stored = slots[source]?.generation, generation < stored { return [] }
            apply(source, generation: generation, snapshot: snapshot)
            return []
        case .collected(let source, let generation, let snapshot):
            inFlight.remove(source)
            if let stored = slots[source]?.generation, generation < stored { return [] }
            apply(source, generation: generation, snapshot: snapshot)
            return []
        case .activationFailed(let finished):
            guard case .hidden = phase, finished == generation else { return [] }
            return [.dismiss(restoreFocus: true)]
        case .noticed(let notice):
            guard !notices.contains(where: { $0.id == notice.id }) else { return [] }
            notices.append(notice)
            if notices.count > 50 { notices.removeFirst(notices.count - 50) }
            return []
        case .noticeOpened(let id):
            guard let notice = notices.first(where: { $0.id == id }) else { return [] }
            notices.removeAll { $0.id == id }
            return [.perform(.rexBlock(blockID: notice.blockID, sessionID: notice.sessionID, windowID: nil), generation: generation)]
        }
    }

    private mutating func act(_ chord: ItemAction.Chord) -> [Effect] {
        guard case .visible = phase else { return [] }
        guard let item = selectedItem(in: rankedItems()),
              let action = item.actions.first(where: { $0.chord == chord })
        else { return [] }
        if case .notice(let notice) = item, chord == .enter {
            notices.removeAll { $0.id == notice.id }
        }
        if action.tracksUse {
            recents.touch(key: item.recentKey, title: item.title)
        }
        let effects: [Effect]
        switch action.run {
        case .perform(let run): effects = [.perform(run, generation: generation)]
        case .copy(let text): effects = [.copy(text)]
        case .startWorkflow(let project):
            workflowRun = WorkflowRunState(project: project, returnQuery: query)
            query = ""
            storedSelection = .top
            return []
        case .chooseWorkflow(let workflow):
            guard var run = workflowRun, case .workflows = run.step else { return [] }
            run.step = .branches(workflow)
            workflowRun = run
            query = ""
            storedSelection = .top
            return []
        case .chooseBranch(let branch):
            guard var run = workflowRun, case .branches(let workflow) = run.step else { return [] }
            run.values = [:]
            if workflow.inputs.isEmpty {
                return finishWorkflow(run, workflow: workflow, branch: branch)
            }
            run.step = .input(workflow, branch: branch, index: 0)
            workflowRun = run
            query = Self.inputQuery(workflow.inputs[0], values: run.values)
            storedSelection = .top
            return []
        case .chooseInput(let value):
            guard var run = workflowRun,
                  case .input(let workflow, let branch, let index) = run.step
            else { return [] }
            let input = workflow.inputs[index]
            if value.isEmpty { run.values.removeValue(forKey: input.name) } else { run.values[input.name] = value }
            let next = index + 1
            if next == workflow.inputs.count {
                return finishWorkflow(run, workflow: workflow, branch: branch)
            }
            run.step = .input(workflow, branch: branch, index: next)
            workflowRun = run
            query = Self.inputQuery(workflow.inputs[next], values: run.values)
            storedSelection = .top
            return []
        }
        switch action.exit {
        case .stay:
            return effects
        case .dismiss:
            phase = .hidden
            return [.dismiss(restoreFocus: false)] + effects
        case .dismissRestore:
            phase = .hidden
            return effects + [.dismiss(restoreFocus: true)]
        }
    }

    private static func inputQuery(_ input: WorkflowInput, values: [String: String]) -> String {
        input.kind == .string ? values[input.name] ?? input.defaultValue : ""
    }

    private mutating func finishWorkflow(
        _ run: WorkflowRunState, workflow: Workflow, branch: String
    ) -> [Effect] {
        let action = Action.githubWorkflow(
            project: run.project, workflow: workflow, branch: branch, inputs: run.values
        )
        phase = .hidden
        workflowRun = nil
        return [.dismiss(restoreFocus: false), .perform(action, generation: generation)]
    }

    private mutating func popWorkflow() -> [Effect] {
        guard var run = workflowRun else { return [] }
        switch run.step {
        case .workflows:
            workflowRun = nil
            query = run.returnQuery
            storedSelection = .pinned(.project(run.project.url.path))
            return []
        case .branches:
            run.step = .workflows
            query = ""
        case .input(let workflow, let branch, let index):
            if index == 0 {
                run.step = .branches(workflow)
                query = ""
            } else {
                let previous = index - 1
                run.step = .input(workflow, branch: branch, index: previous)
                query = Self.inputQuery(workflow.inputs[previous], values: run.values)
            }
        }
        workflowRun = run
        storedSelection = .top
        return []
    }

    private static func scopeHandoff(_ text: String) -> QueryScope? {
        switch text {
        case "c ": .clips
        case "g ": .gitHub
        default: nil
        }
    }

    private mutating func leaveScope() -> [Effect] {
        activeScope = nil
        query = ""
        storedSelection = .top
        return []
    }

    private mutating func show() -> [Effect] {
        generation += 1
        workflowRun = nil
        activeScope = nil
        query = ""
        storedSelection = .top
        closed = []
        frontmost = nil
        phase = .visible(.settling)
        let fresh = Source.allCases.filter { !inFlight.contains($0) }
        inFlight.formUnion(fresh)
        let generation = generation
        return [.present] + fresh.map { .collect($0, generation: generation) }
    }

    private mutating func hide(restoreFocus: Bool) -> [Effect] {
        guard case .visible = phase else { return [] }
        phase = .hidden
        workflowRun = nil
        activeScope = nil
        return [.dismiss(restoreFocus: restoreFocus)]
    }

    private mutating func apply(_ source: Source, generation: Int, snapshot: Snapshot) {
        switch (source, snapshot) {
        case (.herdr, .panes(.success(let panes))):
            store(source, generation: generation, items: panes.map(Item.pane), failure: nil)
        case (.herdr, .panes(.failure(let failure))):
            store(source, generation: generation, items: [], failure: failure)
        case (.rift, .riftLayout(.success(let listing), let restartable)):
            var items = listing.workspaces.map(Item.riftWorkspace) + listing.windows.map(Item.riftWindow)
            if restartable { items.append(.riftService) }
            store(source, generation: generation, items: items, failure: nil)
        case (.rift, .riftLayout(.failure(let failure), let restartable)):
            store(
                source, generation: generation,
                items: restartable ? [.riftService] : [], failure: failure
            )
        case (.rex, .blocks(.success(let listing))):
            store(
                source, generation: generation,
                items: listing.blocks.map(Item.rex) + listing.sessions.map(Item.rexSession),
                failure: nil
            )
        case (.rex, .blocks(.failure(let failure))):
            store(source, generation: generation, items: [], failure: failure)
        case (.t3, .t3Threads(.success(let threads))):
            store(source, generation: generation, items: threads.map(Item.t3), failure: nil)
        case (.t3, .t3Threads(.failure(let failure))):
            store(source, generation: generation, items: [], failure: failure)
        case (.slack, .messages(.success(let messages))):
            store(source, generation: generation, items: messages.map(Item.message), failure: nil)
        case (.slack, .messages(.failure(let failure))):
            store(source, generation: generation, items: [], failure: failure)
        case (.contacts, .contacts(.success(let contacts))):
            store(source, generation: generation, items: contacts.map(Item.contact), failure: nil)
        case (.contacts, .contacts(.failure(let failure))):
            store(source, generation: generation, items: [], failure: failure)
        case (.groups, .groups(.success(let groups))):
            store(source, generation: generation, items: groups.map(Item.group), failure: nil)
        case (.groups, .groups(.failure(let failure))):
            store(source, generation: generation, items: [], failure: failure)
        case (.browser, .tabs(.success(let tabs))):
            store(source, generation: generation, items: tabs.map(Item.tab), failure: nil)
        case (.browser, .tabs(.failure(let failure))):
            store(source, generation: generation, items: [], failure: failure)
        case (.apps, .apps(let apps)):
            store(source, generation: generation, items: apps.map(Item.app), failure: nil)
        case (.projects, .projects(let projects)):
            store(source, generation: generation, items: projects.map(Item.project), failure: nil)
        case (.quickTime, .recordings(let recordings)):
            store(source, generation: generation, items: recordings.map(Item.recording), failure: nil)
        case (.clipboard, .clips(let clips)):
            store(source, generation: generation, items: clips.map(Item.clip), failure: nil)
        default:
            break
        }
    }

    private mutating func store(_ source: Source, generation: Int, items: [Item], failure: CollectFailure?) {
        slots[source] = Slot(generation: generation, items: items.filter { !isClosed($0) }, failure: failure)
        if case .pinned(let id) = storedSelection, !rankedItems().contains(where: { $0.id == id }) {
            storedSelection = .top
        }
    }

    private func rankedItems() -> [Item] {
        ranked().map(\.item)
    }

    private func ranked() -> [Ranking] {
        if let workflowRun { return rankedWorkflow(workflowRun) }
        let items = notices.map(Item.notice) + Source.allCases.flatMap { slots[$0]?.items ?? [] }
        let (transientScope, scopeText) = QueryScope.parse(query)
        let scope = activeScope ?? transientScope
        let text = activeScope == nil ? scopeText : query
        if let scope {
            let pool = items.filter { scope.contains($0) }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return pool.prefix(Match.limit).map { Ranking(item: $0) }
            }
            return Match.rank(text, pool) { self.rank(of: $0) }
        }
        let searching = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let pool = searching
            ? items.filter {
                if case .clip = $0 { return false }
                return true
            }
            : items.filter {
                if case .contact = $0 { return false }
                if case .group = $0 { return false }
                if case .recording = $0 { return false }
                if case .project = $0 { return false }
                if case .clip = $0 { return false }
                if case .riftService = $0 { return false }
                if case .riftWorkspace(let workspace) = $0 { return workspace.windowCount > 0 }
                return true
            }
        guard searching else {
            return Array(resting(pool).prefix(Match.limit)).map { Ranking(item: $0) }
        }
        return Match.rank(text, pool) { self.rank(of: $0) }
    }

    private func rankedWorkflow(_ run: WorkflowRunState) -> [Ranking] {
        let items: [Item]
        let textInput: Bool
        switch run.step {
        case .workflows:
            items = run.project.workflows.map(Item.workflow)
            textInput = false
        case .branches(let workflow):
            items = run.project.branches.map {
                Item.workflowBranch($0, current: $0 == run.project.branch, workflow: workflow)
            }
            textInput = false
        case .input(let workflow, _, let index):
            let input = workflow.inputs[index]
            items = workflowInputItems(input)
            textInput = input.kind == .string
        }
        if textInput { return items.map { Ranking(item: $0) } }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return items.prefix(Match.limit).map { Ranking(item: $0) }
        }
        return Match.rank(query, items)
    }

    private func workflowInputItems(_ input: WorkflowInput) -> [Item] {
        if input.kind == .string {
            let value = query
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if input.required && input.defaultValue.isEmpty { return [] }
                let label = input.defaultValue.isEmpty ? "Skip (use GitHub default)" : "Default: \(input.defaultValue)"
                return [.workflowInput(input, value: "", label: label)]
            }
            return [.workflowInput(input, value: value, label: value)]
        }

        var options = input.kind == .boolean ? ["true", "false"] : input.options
        if let index = options.firstIndex(of: input.defaultValue) {
            options.remove(at: index)
            options.insert(input.defaultValue, at: 0)
        }
        var items = options.map {
            Item.workflowInput(input, value: $0, label: $0)
        }
        if !input.required, input.defaultValue.isEmpty {
            items.insert(.workflowInput(input, value: "", label: "Skip (use GitHub default)"), at: 0)
        }
        return items
    }

    private func rank(of item: Item) -> Int? {
        if case .clip = item { return nil }
        return recents.rank(key: item.recentKey, title: item.title)
    }

    private func resting(_ pool: [Item]) -> [Item] {
        var recent: [(Int, Item)] = []
        var rest: [Item] = []
        var current: [Item] = []
        for item in pool {
            if isCurrent(item) {
                current.append(item)
                continue
            }
            if let rank = recents.rank(key: item.recentKey, title: item.title) {
                recent.append((rank, item))
            } else {
                rest.append(item)
            }
        }
        recent.sort { $0.0 < $1.0 }
        rest.sort { $0.attention < $1.attention }
        var ordered = recent.map(\.1) + rest
        guard !current.isEmpty else { return ordered }
        if ordered.isEmpty { return current }
        var index = min(ordered.count, max(recent.count, 1))
        for item in current {
            ordered.insert(item, at: index)
            index += 1
        }
        return ordered
    }

    private func isCurrent(_ item: Item) -> Bool {
        switch item {
        case .pane(let pane):
            return pane.focused
        case .rex(let block):
            return block.focused
        case .app(let app):
            return app.url == frontmost
        case .riftWindow(let window):
            return window.focused
        case .riftWorkspace(let workspace):
            return workspace.focused
        case .message, .contact, .group, .tab, .rexSession, .notice, .recording, .t3, .clip,
             .riftService, .project, .workflow, .workflowBranch, .workflowInput:
            return false
        }
    }

    private func selectedItem(in items: [Item]) -> Item? {
        switch selection {
        case .top:
            return items.first
        case .pinned(let id):
            return items.first { $0.id == id } ?? items.first
        }
    }

    private mutating func dropClosed() {
        for source in slots.keys {
            guard var slot = slots[source] else { continue }
            slot.items.removeAll { isClosed($0) }
            slots[source] = slot
        }
    }

    private func isClosed(_ item: Item) -> Bool {
        switch item.close {
        case .closeHerdr(let tab):
            return closed.contains(.herdr(tab))
        case .closeRex(let blockID):
            return closed.contains(.rex(blockID))
        case .closeBrowser(let browser, let windowID, let tabID):
            return closed.contains(.browser(browser, windowID: windowID, tabID: tabID))
        case .riftClose(let windowID):
            return closed.contains(.rift(windowID))
        default:
            return false
        }
    }

    private enum Closed: Hashable, Sendable {
        case herdr(TabID)
        case rex(String)
        case browser(Browser, windowID: String, tabID: String)
        case rift(Int)
    }

    private struct Slot: Sendable {
        var generation: Int
        var items: [Item]
        var failure: CollectFailure?
    }
}

@MainActor
@Observable
public final class Launcher {
    public private(set) var theme: Theme
    private var state = LauncherState(recents: Recents.load())
    private var panel: LauncherPanel?

    var rows: [PresentedRow] { state.rows }
    var query: String { state.query }
    var prompt: String { state.prompt }
    var canPopPickerOnBackspace: Bool { state.canPopPickerOnBackspace }
    var failures: [String] { state.failures }
    var footer: [LauncherState.FooterItem] { state.footer }
    var generation: Int { state.generation }

    public init(theme: Theme) {
        self.theme = theme
    }

    public func send(_ event: Event) {
        let before = state.recents
        for effect in state.handle(event) {
            run(effect)
        }
        if state.recents != before {
            state.recents.save()
        }
    }

    private func run(_ effect: Effect) {
        switch effect {
        case .present:
            _ = state.handle(.frontmost(Apps.frontmostURL()))
            theme = Theme.load()
            panelIfNeeded().present()
            Task { @MainActor [weak self] in
                self?.send(.settled)
            }
        case .dismiss(let restoreFocus):
            panel?.dismiss(restoreFocus: restoreFocus)
        case .collect(let source, let generation):
            Task {
                let snapshot = await collectPayload(source) { partial in
                    self.send(.updated(source, generation: generation, partial))
                }
                self.send(.collected(source, generation: generation, snapshot))
            }
        case .perform(let action, let generation):
            Task {
                do {
                    try await perform(action)
                } catch {
                    FileHandle.standardError.write(Data("flaneur: activation failed: \(error)\n".utf8))
                    self.send(.activationFailed(generation: generation))
                }
            }
        case .copy(let text):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    private func panelIfNeeded() -> LauncherPanel {
        if let panel { return panel }
        let panel = LauncherPanel(content: LauncherView(launcher: self)) { [weak self] key in
            guard let self else { return false }
            if key == .backspace, !self.canPopPickerOnBackspace { return false }
            switch key {
            case .up: self.send(.move(.up))
            case .down: self.send(.move(.down))
            case .enter: self.send(.submit)
            case .open: self.send(.open)
            case .yank: self.send(.yank)
            case .close: self.send(.close)
            case .moveWindow(let index): self.send(.moveWindow(index))
            case .fullscreen: self.send(.fullscreen)
            case .quit: self.send(.quit)
            case .quitFlaneur: NSApp.terminate(nil)
            case .restart: self.send(.restart)
            case .runWorkflow: self.send(.runWorkflow)
            case .clear: self.send(.clearLine)
            case .escape: self.send(.escape)
            case .backspace: self.send(.backspace)
            }
            return true
        }
        self.panel = panel
        return panel
    }
}

private func collectPayload(
    _ source: Source,
    update: @escaping @MainActor (Snapshot) -> Void = { _ in }
) async -> Snapshot {
    switch source {
    case .herdr:
        do {
            return .panes(.success(try await Herdr.collect()))
        } catch {
            return .panes(.failure(.from(error)))
        }
    case .rex:
        do {
            return .blocks(.success(try await Rex.collect()))
        } catch {
            return .blocks(.failure(.from(error)))
        }
    case .rift:
        let restartable = FileManager.default.isExecutableFile(atPath: Rift.binary)
        do {
            return .riftLayout(.success(try await Rift.collect()), restartable: restartable)
        } catch {
            return .riftLayout(.failure(.from(error)), restartable: restartable)
        }
    case .t3:
        do {
            return .t3Threads(.success(try await T3Code.collect()))
        } catch {
            return .t3Threads(.failure(.from(error)))
        }
    case .slack:
        do {
            return .messages(.success(try await Slack.collect { messages in
                let snapshot = Snapshot.messages(.success(messages))
                Task { @MainActor in update(snapshot) }
            }))
        } catch {
            return .messages(.failure(.from(error)))
        }
    case .contacts:
        do {
            return .contacts(.success(try await Slack.contacts()))
        } catch {
            return .contacts(.failure(.from(error)))
        }
    case .groups:
        do {
            return .groups(.success(try await Slack.groups()))
        } catch {
            return .groups(.failure(.from(error)))
        }
    case .browser(let browser):
        do {
            return .tabs(.success(try await Browsers.collect(browser)))
        } catch {
            return .tabs(.failure(.from(error)))
        }
    case .apps:
        return .apps(await Apps.collect())
    case .projects:
        let projects = await Projects.collect { projects in
            let snapshot = Snapshot.projects(projects)
            Task { @MainActor in update(snapshot) }
        }
        return .projects(projects)
    case .quickTime:
        return .recordings(await QuickTime.collect())
    case .clipboard:
        return .clips(await ClipboardMonitor.shared.entries)
    }
}

private func perform(_ action: Action) async throws {
    switch action {
    case .herdrAgent(let pane):
        try await Herdr.focus(agent: pane)
    case .herdrTab(let tab):
        try await Herdr.focus(tab: tab)
    case .herdrNamed(let pane, let tab):
        try await Herdr.focus(named: pane, tab: tab)
    case .herdrWorkspace(let id):
        try await Herdr.focus(workspace: id)
    case .rexBlock(let blockID, let sessionID, let windowID):
        try await Rex.focus(blockID: blockID, sessionID: sessionID, windowID: windowID)
    case .riftWorkspace(let index):
        try await Rift.focus(workspace: index)
    case .riftWindow(let window):
        do {
            try await Rift.focus(window: window.id)
        } catch {
            try await Apps.activate(bundleID: window.bundleID)
        }
    case .riftMove(let windowID, let workspace):
        try await Rift.move(window: windowID, toWorkspace: workspace)
    case .riftFullscreen(let window):
        try await Rift.fullscreen(window: window.id)
    case .riftClose(let windowID):
        try await Rift.close(window: windowID)    case .rexSession(let sessionID):
        try await Rex.focus(sessionID: sessionID)
    case .closeRex(let blockID):
        try await Rex.close(blockID: blockID)
    case .t3Thread(let environmentID, let threadID):
        try await T3Code.focus(environmentID: environmentID, threadID: threadID)
    case .dismissNotice:
        break
    case .browser(let browser, let windowID, let tabID):
        try await Browsers.select(browser, windowID: windowID, tabID: tabID)
    case .closeBrowser(let browser, let windowID, let tabID):
        try await Browsers.close(browser, windowID: windowID, tabID: tabID)
    case .closeHerdr(let tab):
        try await Herdr.close(tab: tab)
    case .app(let url):
        try await Apps.open(url)
    case .folder(let url):
        try await Links.open(url)
    case .githubWorkflow(let project, let workflow, let branch, let inputs):
        let output = try await Projects.run(workflow, in: project, branch: branch, inputs: inputs)
        if !output.isEmpty {
            FileHandle.standardError.write(Data("flaneur: \(output)\n".utf8))
        }
    case .screenRecording:
        try await QuickTime.startScreenRecording()
    case .quitApp(let url):
        try await Apps.quit(url)
    case .restartApp(let url):
        try await Apps.restart(url)
    case .riftRestart:
        try await Rift.restart()
    case .slack(let team, let channel, let ts):
        try await Slack.open(team: team, channel: channel, ts: ts)
    case .slackContact(let team, let user):
        try await Slack.open(team: team, user: user)
    case .slackGroup(let team, let channel):
        try await Slack.open(team: team, channel: channel)
    case .link(let url):
        try await Links.open(url)
    }
}

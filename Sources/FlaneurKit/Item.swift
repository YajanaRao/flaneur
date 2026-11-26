import Foundation

public struct PaneID: Hashable, Sendable {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

public struct TabID: Hashable, Sendable {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

enum Terminal {
    static let bundleID = "com.mitchellh.ghostty"
}

enum RowIcon: Hashable, Sendable {
    case file(String)
    case application(String)
    /// An SF Symbol by name, for rows with no app behind them.
    case symbol(String)
    /// A vector image bundled in Contents/Resources, without its extension.
    case bundled(String)
    /// Bytes of a favicon. `fallback` is the app icon when the bytes do not decode.
    case picture(Data, fallback: String)
    /// A profile photo. `fallback` shows until the photo arrives.
    case remote(url: String, fallback: String)

    var template: Bool {
        switch self {
        case .symbol, .bundled: true
        case .file, .application, .picture, .remote: false
        }
    }
}

public enum Browser: String, CaseIterable, Hashable, Sendable {
    case brave, helium, yab

    public var bundleID: String {
        switch self {
        case .brave: "com.brave.Browser"
        case .helium: "net.imput.helium"
        case .yab: "dev.serafim.fast"
        }
    }

    public var displayName: String {
        switch self {
        case .brave: "Brave"
        case .helium: "Helium"
        case .yab: "Yab"
        }
    }
}

public enum HerdrKind: Hashable, Sendable {
    /// One row per agent. Enter focuses that agent.
    case agent
    /// A tab with no agent.
    case tab
    /// A pane given its own name. Enter focuses that pane.
    case named
    /// Shown when the session has more than one workspace.
    case workspace
}

public struct HerdrPane: Hashable, Sendable {
    public let pane: PaneID
    public let tab: TabID
    public let title: String
    public let subtitle: String
    public let agent: Bool
    public let status: String
    /// The Herdr row the session is already on. An empty query does not put it first.
    public let focused: Bool
    public let kind: HerdrKind
    public let workspaceID: String
    /// Searchable text that is not already the title, subtitle, or badge.
    public let terms: [String]

    public init(
        pane: PaneID, tab: TabID, title: String, subtitle: String, agent: Bool, status: String = "",
        focused: Bool = false, kind: HerdrKind? = nil, workspaceID: String = "", terms: [String] = []
    ) {
        self.pane = pane
        self.tab = tab
        self.title = title
        self.subtitle = subtitle
        self.agent = agent
        self.status = status
        self.focused = focused
        self.kind = kind ?? (agent ? .agent : .tab)
        self.workspaceID = workspaceID
        self.terms = terms
    }
}

/// One block in a Rex window. Enter focuses the block; its window follows.
public struct RexBlock: Hashable, Sendable {
    public let blockID: String
    public let windowID: String
    public let sessionID: String
    public let label: String
    public let windowLabel: String
    public let sessionLabel: String
    /// The block the user's cursor is in. An empty query does not put it first.
    public let focused: Bool
    /// Keeps running outside any window. Enter shows its session; there is no pane to focus.
    public let detached: Bool

    public init(
        blockID: String, windowID: String, sessionID: String, label: String,
        windowLabel: String, sessionLabel: String, focused: Bool = false, detached: Bool = false
    ) {
        self.blockID = blockID
        self.windowID = windowID
        self.sessionID = sessionID
        self.label = label
        self.windowLabel = windowLabel
        self.sessionLabel = sessionLabel
        self.focused = focused
        self.detached = detached
    }
}

/// One Rex session — a workspace of tabs. Enter shows it in the app.
public struct RexSession: Hashable, Sendable {
    public let sessionID: String
    public let label: String
    public let windowCount: Int

    public init(sessionID: String, label: String, windowCount: Int) {
        self.sessionID = sessionID
        self.label = label
        self.windowCount = windowCount
    }
}

/// What one rex collect brings in: every session, and every block including detached ones.
public struct RexListing: Sendable {
    public let sessions: [RexSession]
    public let blocks: [RexBlock]

    public init(sessions: [RexSession], blocks: [RexBlock]) {
        self.sessions = sessions
        self.blocks = blocks
    }
}

/// A `desktop_notification` from a program in a rex terminal (OSC 9/777). One unread row
/// in the panel plus a banner; Enter focuses the block and forgets the notice.
public struct RexNotice: Hashable, Sendable {
    public let id: String
    public let blockID: String
    public let sessionID: String
    public let sessionLabel: String
    public let title: String
    /// Empty when the sender gave only one line (OSC 9); it becomes the title.
    public let body: String
    public let date: Date

    public init(
        id: String, blockID: String, sessionID: String, sessionLabel: String,
        title: String, body: String, date: Date
    ) {
        self.id = id
        self.blockID = blockID
        self.sessionID = sessionID
        self.sessionLabel = sessionLabel
        self.title = title
        self.body = body
        self.date = date
    }
}

public struct BrowserTab: Hashable, Sendable {
    public let browser: Browser
    public let windowID: String
    public let tabID: String
    public let title: String
    public let url: String
    /// Favicon from the browser's own store, when it has one for this page.
    public let favicon: Data?

    public init(
        browser: Browser, windowID: String, tabID: String, title: String, url: String, favicon: Data? = nil
    ) {
        self.browser = browser
        self.windowID = windowID
        self.tabID = tabID
        self.title = title
        self.url = url
        self.favicon = favicon
    }
}

public struct SlackMessage: Hashable, Sendable {
    public let team: String
    public let channel: String
    public let ts: String
    /// "#channel", "DM", or the people in a group DM.
    public let place: String
    public let author: String
    public let text: String
    /// First URL mentioned in the message body.
    public let link: URL?
    public let permalink: URL
    public let date: Date
    /// Profile photo for a direct message. Channels keep the Slack icon.
    public let image: String?

    public init(
        team: String, channel: String, ts: String, place: String, author: String, text: String,
        link: URL?, permalink: URL, date: Date, image: String? = nil
    ) {
        self.team = team
        self.channel = channel
        self.ts = ts
        self.place = place
        self.author = author
        self.text = text
        self.link = link
        self.permalink = permalink
        self.date = date
        self.image = image
    }
}

public struct SlackContact: Hashable, Sendable {
    public let team: String
    public let user: String
    public let name: String
    public let handle: String
    public let title: String
    public let realName: String
    /// Profile photo, when Slack has one.
    public let image: String?

    public init(
        team: String, user: String, name: String, handle: String, title: String, realName: String,
        image: String? = nil
    ) {
        self.team = team
        self.user = user
        self.name = name
        self.handle = handle
        self.title = title
        self.realName = realName
        self.image = image
    }
}

public struct SlackGroup: Hashable, Sendable {
    public let team: String
    public let channel: String
    public let name: String
    public let kind: String

    public init(team: String, channel: String, name: String, kind: String) {
        self.team = team
        self.channel = channel
        self.name = name
        self.kind = kind
    }
}

public struct AppEntry: Hashable, Sendable {
    public let url: URL
    public let name: String
    public let running: Bool

    public init(url: URL, name: String, running: Bool) {
        self.url = url
        self.name = name
        self.running = running
    }
}

/// One T3 Code thread — an agent conversation in a project. Enter opens it in the
/// desktop app by deep link.
public struct T3Thread: Hashable, Sendable {
    public let threadID: String
    public let environmentID: String
    public let title: String
    public let project: String
    public let branch: String
    public let updatedAt: Date

    public init(
        threadID: String, environmentID: String, title: String, project: String,
        branch: String, updatedAt: Date
    ) {
        self.threadID = threadID
        self.environmentID = environmentID
        self.title = title
        self.project = project
        self.branch = branch
        self.updatedAt = updatedAt
    }
}

/// A QuickTime Player command as a row. Static, not collected from anywhere — Enter
/// runs the command.
public struct Recording: Hashable, Sendable {
    public let title: String
    public let subtitle: String

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }
}

public enum Action: Hashable, Sendable {
    case herdrAgent(PaneID)
    case herdrTab(TabID)
    case herdrNamed(PaneID, tab: TabID)
    case herdrWorkspace(String)
    case browser(Browser, windowID: String, tabID: String)
    case app(URL)
    case folder(URL)
    case githubWorkflow(project: ProjectFolder, workflow: Workflow, branch: String, inputs: [String: String])
    case slack(team: String, channel: String, ts: String)
    /// Open the DM with this person, ready to type.
    case slackContact(team: String, user: String)
    /// Open a channel, private channel, or group DM.
    case slackGroup(team: String, channel: String)
    /// Open in the default browser.
    case link(URL)
    case closeHerdr(TabID)
    case closeBrowser(Browser, windowID: String, tabID: String)
    case rexBlock(blockID: String, sessionID: String, windowID: String)
    case rexSession(sessionID: String)
    case closeRex(blockID: String)
    /// Open a T3 Code thread in the desktop app: t3code://threads/<environment>/<thread>.
    case t3Thread(environmentID: String, threadID: String)
    /// ⌘W on a notification row: forget the notice. The block it came from stays open.
    case dismissNotice(String)
    /// QuickTime Player: File ▸ New Screen Recording (⌃⌘N).
    case screenRecording
    /// Switch to a rift workspace.
    case riftWorkspace(index: Int)
    /// Focus a rift window; its workspace follows. Falls back to activating the app.
    case riftWindow(RiftWindow)
    /// ⌘1…0 on a rift window row: move it to that workspace. The user stays put.
    case riftMove(windowID: Int, workspace: Int)
    /// ⌃F on a rift window row: focus it and toggle true fullscreen.
    case riftFullscreen(RiftWindow)
    /// ⌘W on a rift window row: close the window. The panel stays open.
    case riftClose(windowID: Int)
    /// ⌃⇧Q on a running app's row.
    case quitApp(URL)
    /// ⌘R on a running app's row: terminate, wait for exit, relaunch.
    case restartApp(URL)
    /// Restart the rift launchd service, re-adopting every window.
    case riftRestart
}

/// One thing a row can do, as data: the chord that fires it, the title and key label
/// the footer (and a future actions menu) show, what to run, and what the panel does
/// after. Keys never name implementations; actions never hardcode keys.
public struct ItemAction: Hashable, Sendable {
    public enum Chord: Hashable, Sendable {
        case enter, open, yank, close, quit, restart, fullscreen, runWorkflow
        case moveWindow(Int)
    }

    public enum Exit: Hashable, Sendable {
        /// The panel stays up (⌘W close: the row drops, collection continues).
        case stay
        /// Go somewhere: close without restoring focus.
        case dismiss
        /// Copy or move something, then hand focus back to what you were doing.
        case dismissRestore
    }

    public enum Run: Hashable, Sendable {
        case perform(Action)
        /// A pasteboard write: clipboard copies and link yanks.
        case copy(String)
        case startWorkflow(ProjectFolder)
        case chooseWorkflow(Workflow)
        case chooseBranch(String)
        case chooseInput(String)
    }

    public let chord: Chord
    public let title: String
    public let keyLabel: String
    public let run: Run
    public let exit: Exit
    /// Opening counts as use for frecency; quitting or closing something does not.
    public let tracksUse: Bool

    public init(
        chord: Chord, title: String, keyLabel: String, run: Run, exit: Exit,
        tracksUse: Bool = true
    ) {
        self.chord = chord
        self.title = title
        self.keyLabel = keyLabel
        self.run = run
        self.exit = exit
        self.tracksUse = tracksUse
    }
}

struct SearchField: Equatable {
    enum Role { case title, subtitle, badge, extra }
    var text: String
    var role: Role
}

public enum Item: Hashable, Sendable, Identifiable {
    case pane(HerdrPane)
    case rex(RexBlock)
    case rexSession(RexSession)
    case notice(RexNotice)
    case message(SlackMessage)
    case contact(SlackContact)
    case group(SlackGroup)
    case tab(BrowserTab)
    case app(AppEntry)
    case project(ProjectFolder)
    case workflow(Workflow)
    case workflowBranch(String, current: Bool, workflow: Workflow)
    case workflowInput(WorkflowInput, value: String, label: String)
    case recording(Recording)
    case t3(T3Thread)
    case clip(Clip)
    case riftWindow(RiftWindow)
    case riftWorkspace(RiftWorkspace)
    /// The rift service as a command row: restart re-adopts every window when rift's
    /// event pipeline has silently died. Search-only, like the Screen Recording row.
    case riftService

    public var id: ID {
        switch self {
        case .pane(let pane):
            switch pane.kind {
            case .named: .named(pane.pane)
            case .workspace: .workspace(pane.workspaceID)
            case .agent, .tab: .pane(pane.pane)
            }
        case .rex(let block):
            .rexBlock(block.blockID)
        case .rexSession(let session):
            .rexSession(session.sessionID)
        case .notice(let notice):
            .notice(notice.id)
        case .message(let message):
            .message(channel: message.channel, ts: message.ts)
        case .contact(let contact):
            .contact(contact.user)
        case .group(let group):
            .group(group.channel)
        case .tab(let tab):
            .tab(tab.browser, windowID: tab.windowID, tabID: tab.tabID)
        case .app(let app):
            .app(app.url)
        case .project(let project):
            .project(project.url.path)
        case .workflow(let workflow):
            .workflow(workflow.fileName)
        case .workflowBranch(let branch, _, _):
            .workflowBranch(branch)
        case .workflowInput(let input, let value, _):
            .workflowInput("\(input.name):\(value)")
        case .recording:
            .recording
        case .t3(let thread):
            .t3(thread.threadID)
        case .clip(let clip):
            .clip(clip.id)
        case .riftWindow(let window):
            .riftWindow(window.id)
        case .riftWorkspace(let workspace):
            .riftWorkspace(workspace.index)
        case .riftService:
            .riftService
        }
    }

    public enum ID: Hashable, Sendable {
        case pane(PaneID)
        case named(PaneID)
        case workspace(String)
        case rexBlock(String)
        case rexSession(String)
        case notice(String)
        case message(channel: String, ts: String)
        case contact(String)
        case group(String)
        case tab(Browser, windowID: String, tabID: String)
        case app(URL)
        case project(String)
        case workflow(String)
        case workflowBranch(String)
        case workflowInput(String)
        case recording
        case t3(String)
        case clip(UUID)
        case riftWindow(Int)
        case riftWorkspace(Int)
        case riftService
    }

    public var title: String {
        switch self {
        case .pane(let pane):
            pane.title
        case .rex(let block):
            block.label
        case .rexSession(let session):
            session.label.isEmpty ? "session" : session.label
        case .notice(let notice):
            notice.title
        case .message(let message):
            message.author
        case .contact(let contact):
            contact.name
        case .group(let group):
            group.name
        case .tab(let tab):
            tab.title.isEmpty ? tab.url : tab.title
        case .app(let app):
            app.name
        case .project(let project):
            project.name
        case .workflow(let workflow):
            workflow.name
        case .workflowBranch(let branch, _, _):
            branch
        case .workflowInput(_, _, let label):
            label
        case .recording(let recording):
            recording.title
        case .t3(let thread):
            thread.title.isEmpty ? "thread" : thread.title
        case .clip(let clip):
            // One line on the row no matter how many were copied.
            String(
                clip.text
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                    .prefix(200)
            )
        case .riftWindow(let window):
            window.title.isEmpty ? window.app : window.title
        case .riftWorkspace(let workspace):
            workspace.apps.isEmpty ? workspace.name : "\(workspace.name) · \(workspace.apps.joined(separator: " · "))"
        case .riftService:
            "Restart Rift"
        }
    }

    var icon: RowIcon {
        switch self {
        case .pane:
            .application(Terminal.bundleID)
        case .rex, .rexSession, .notice:
            .application(Rex.bundleID)
        case .message(let message):
            if let image = message.image {
                .remote(url: image, fallback: Slack.bundleID)
            } else {
                .application(Slack.bundleID)
            }
        case .contact(let contact):
            if let image = contact.image {
                .remote(url: image, fallback: Slack.bundleID)
            } else {
                .application(Slack.bundleID)
            }
        case .group:
            .application(Slack.bundleID)
        case .tab(let tab):
            if let favicon = tab.favicon {
                .picture(favicon, fallback: tab.browser.bundleID)
            } else {
                .application(tab.browser.bundleID)
            }
        case .app(let app):
            .file(app.url.path)
        case .project(let project):
            project.repository == nil ? .file(project.url.path) : .bundled("GitHubMark")
        case .workflow:
            .symbol("play.circle")
        case .workflowBranch:
            .symbol("arrow.triangle.branch")
        case .workflowInput(let input, _, _):
            switch input.kind {
            case .choice: .symbol("list.bullet")
            case .boolean: .symbol("checkmark.circle")
            case .string: .symbol("text.cursor")
            }
        case .recording:
            .application(QuickTime.bundleID)
        case .t3:
            .application(T3Code.bundleID)
        case .clip:
            // A clip's icon says what it is, never where it came from (tinycast keeps
            // the source app in the details panel, not on the row).
            .symbol("doc.on.clipboard")
        case .riftWindow(let window):
            .application(window.bundleID)
        case .riftWorkspace(let workspace):
            if let icon = workspace.icon {
                .application(icon)
            } else {
                .symbol("square.grid.2x2")
            }
        case .riftService:
            .symbol("arrow.clockwise")
        }
    }

    /// Lower comes first when nothing else distinguishes the row. Blocked is waiting on you, done is finished work to look at.
    var attention: Int {
        // An unread notification is waiting on you, the same as a blocked agent.
        if case .notice = self { return 0 }
        guard case .pane(let pane) = self else { return 2 }
        if pane.kind == .workspace { return 3 }
        switch pane.status {
        case "blocked": return 0
        case "done": return 1
        default: return 2
        }
    }

    var status: String {
        switch self {
        case .pane(let pane):
            return pane.status
        case .message(let message):
            return "\(message.place) · \(Slack.age(message.date))"
        case .contact:
            return "DM"
        case .group(let group):
            return group.kind
        case .notice(let notice):
            return Slack.age(notice.date)
        case .t3(let thread):
            return Slack.age(thread.updatedAt)
        case .tab, .app, .rex, .rexSession, .recording:
            return ""
        case .project(let project):
            return project.branch
        case .workflow(let workflow):
            return workflow.inputs.isEmpty ? "" : "\(workflow.inputs.count) inputs"
        case .workflowBranch(_, let current, _):
            return current ? "current" : ""
        case .workflowInput(let input, _, _):
            return input.required ? "required" : "optional"
        case .clip(let clip):
            return Slack.age(clip.at)
        case .riftWindow(let window):
            return window.focused ? "current" : ""
        case .riftWorkspace(let workspace):
            if workspace.focused { return "current" }
            switch workspace.windowCount {
            case 0: return ""
            case 1: return "1 window"
            default: return "\(workspace.windowCount) windows"
            }
        case .riftService:
            return ""
        }
    }

    /// What ⌃O opens and ⌃Y copies. Prefers a link inside a message over the message itself.
    public var link: URL? {
        switch self {
        case .message(let message):
            return message.link ?? message.permalink
        case .tab(let tab):
            guard let url = URL(string: tab.url), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            return url
        case .project(let project):
            return project.repository?.url
        case .pane, .contact, .group, .app, .rex, .rexSession, .notice, .recording, .t3, .clip,
             .riftWindow, .riftWorkspace, .riftService, .workflow, .workflowBranch, .workflowInput:
            return nil
        }
    }

    /// Each query term has to match one of these on its own. Title hits outrank the rest.
    var searchFields: [SearchField] {
        var fields: [SearchField] = []
        func add(_ text: String, _ role: SearchField.Role) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if fields.contains(where: { $0.role == role && $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return
            }
            fields.append(SearchField(text: trimmed, role: role))
        }
        add(title, .title)
        add(subtitle, .subtitle)
        add(status, .badge)
        for term in extraTerms { add(term, .extra) }
        return fields
    }

    /// Hidden words. "slack" finds every unread message; a Herdr cwd stays findable when the
    /// row is showing the task summary instead.
    var extraTerms: [String] {
        switch self {
        case .pane(let pane):
            return pane.terms
        case .rex(let block):
            return ["rex", block.windowLabel, block.sessionLabel]
        case .rexSession:
            return ["rex", "session"]
        case .notice(let notice):
            return ["rex", "notification", notice.sessionLabel]
        case .message:
            return ["slack"]
        case .contact(let contact):
            return [contact.handle, contact.realName, "@\(contact.handle)"]
        case .group:
            return ["slack"]
        case .recording:
            return ["capture"]
        case .t3(let thread):
            // "t3" names every thread the way "slack" names every message.
            return ["t3", "t3code", thread.branch]
        case .clip(let clip):
            // "clip" lists the whole history the way "slack" lists every message; the
            // source app is a search word ("slack" finds what you copied in Slack).
            return ["clip", "clipboard"] + (clip.sourceName.map { [$0] } ?? [])
        case .riftWindow(let window):
            // The workspace number finds its windows: "9" or "workspace 9".
            return ["rift", window.app, window.workspaceName, "workspace \(window.workspaceName)"]
        case .riftWorkspace(let workspace):
            return ["rift", "workspace", "workspace \(workspace.name)"] + workspace.apps + workspace.titles
        case .riftService:
            return ["rift", "restart", "reload", "window manager", "service"]
        case .project(let project):
            var terms = ["folder", project.url.path]
            if project.repository != nil { terms += ["git", "github", "repository", "actions"] }
            return terms
        case .workflow(let workflow):
            return ["github", "actions", "workflow", workflow.fileName]
        case .workflowBranch:
            return ["branch"]
        case .workflowInput(let input, _, _):
            return [input.name, input.description]
        case .tab, .app:
            return []
        }
    }

    var recentKey: String {
        switch id {
        case .pane(let pane): "pane:\(pane.raw)"
        case .named(let pane): "named:\(pane.raw)"
        case .workspace(let id): "workspace:\(id)"
        case .rexBlock(let id): "rex:\(id)"
        case .rexSession(let id): "rexsession:\(id)"
        case .notice(let id): "notice:\(id)"
        case .message(let channel, let ts): "slack:\(channel):\(ts)"
        case .contact(let user): "contact:\(user)"
        case .group(let channel): "group:\(channel)"
        case .tab(let browser, let windowID, let tabID): "tab:\(browser.rawValue):\(windowID):\(tabID)"
        case .app(let url): "app:\(url.path)"
        case .project(let path): "project:\(path)"
        case .workflow(let file): "workflow:\(file)"
        case .workflowBranch(let branch): "workflowbranch:\(branch)"
        case .workflowInput(let value): "workflowinput:\(value)"
        case .recording: "recording:screen"
        case .t3(let id): "t3:\(id)"
        case .clip(let id): "clip:\(id.uuidString)"
        case .riftWindow(let id): "riftwindow:\(id)"
        case .riftWorkspace(let index): "riftworkspace:\(index)"
        case .riftService: "rift:service"
        }
    }

    public var subtitle: String {
        switch self {
        case .pane(let pane):
            return pane.subtitle
        case .rex(let block):
            if block.detached {
                return ["detached", block.sessionLabel]
                    .filter { !$0.isEmpty && $0 != block.label }
                    .joined(separator: " · ")
            }
            return [block.windowLabel, block.sessionLabel]
                .filter { !$0.isEmpty && $0 != block.label }
                .joined(separator: " · ")
        case .rexSession(let session):
            // Rex calls a window a tab.
            return session.windowCount == 0 ? "session" : "session · \(session.windowCount == 1 ? "1 tab" : "\(session.windowCount) tabs")"
        case .notice(let notice):
            return notice.body.isEmpty ? notice.sessionLabel : notice.body
        case .message(let message):
            return message.text
        case .contact(let contact):
            return contact.title.isEmpty ? "@\(contact.handle)" : contact.title
        case .group:
            return ""
        case .tab(let tab):
            return GitHub.words(for: tab.url) ?? Self.host(tab.url)
        case .app(let app):
            return app.running ? "running" : ""
        case .project(let project):
            if let repository = project.repository {
                let count = project.workflows.count
                return "\(repository.nameWithOwner) · \(count == 1 ? "1 workflow" : "\(count) workflows")"
            }
            return project.url.path
        case .workflow(let workflow):
            return workflow.fileName
        case .workflowBranch(_, let current, let workflow):
            return current ? "\(workflow.name) · current branch" : workflow.name
        case .workflowInput(let input, _, _):
            return input.description
        case .recording(let recording):
            return recording.subtitle
        case .t3(let thread):
            return [thread.project, thread.branch]
                .filter { !$0.isEmpty && $0 != thread.title }
                .joined(separator: " · ")
        case .clip:
            return ""
        case .riftWindow(let window):
            return window.title.isEmpty || window.title == window.app
                ? "workspace \(window.workspaceName)"
                : "\(window.app) · workspace \(window.workspaceName)"
        case .riftWorkspace(let workspace):
            return workspace.titles.first ?? "empty"
        case .riftService:
            return "re-adopts every window"
        }
    }

    /// ⌘W. Browser tabs, Herdr tabs and Rex blocks only; apps and Slack messages stay put.
    public var close: Action? {
        switch self {
        case .pane(let pane):
            pane.kind == .workspace || pane.tab.raw.isEmpty ? nil : .closeHerdr(pane.tab)
        case .rex(let block):
            .closeRex(blockID: block.blockID)
        case .notice(let notice):
            .dismissNotice(notice.id)
        case .tab(let tab):
            .closeBrowser(tab.browser, windowID: tab.windowID, tabID: tab.tabID)
        case .riftWindow(let window):
            .riftClose(windowID: window.id)
        case .message, .contact, .group, .app, .project, .workflow, .workflowBranch, .workflowInput,
             .rexSession, .recording, .t3, .clip, .riftWorkspace:
            nil
        case .riftService:
            nil
        }
    }

    /// The row's primary (↵) action. `actions` prepends it to the extras. Nil for clips:
    /// theirs is a pasteboard write (Run.copy), not a performed action.
    var primary: Action? {
        switch self {
        case .pane(let pane):
            switch pane.kind {
            case .agent: .herdrAgent(pane.pane)
            case .tab: .herdrTab(pane.tab)
            case .named: .herdrNamed(pane.pane, tab: pane.tab)
            case .workspace: .herdrWorkspace(pane.workspaceID)
            }
        case .rex(let block):
            .rexBlock(blockID: block.blockID, sessionID: block.sessionID, windowID: block.windowID)
        case .rexSession(let session):
            .rexSession(sessionID: session.sessionID)
        case .notice(let notice):
            // The window is unknown from an event; block focus finds it.
            .rexBlock(blockID: notice.blockID, sessionID: notice.sessionID, windowID: "")
        case .message(let message):
            .slack(team: message.team, channel: message.channel, ts: message.ts)
        case .contact(let contact):
            .slackContact(team: contact.team, user: contact.user)
        case .group(let group):
            .slackGroup(team: group.team, channel: group.channel)
        case .tab(let tab):
            .browser(tab.browser, windowID: tab.windowID, tabID: tab.tabID)
        case .app(let app):
            .app(app.url)
        case .project(let project):
            .folder(project.url)
        case .workflow, .workflowBranch, .workflowInput:
            nil
        case .recording:
            .screenRecording
        case .t3(let thread):
            .t3Thread(environmentID: thread.environmentID, threadID: thread.threadID)
        case .riftWindow(let window):
            .riftWindow(window)
        case .riftWorkspace(let workspace):
            .riftWorkspace(index: workspace.index)
        case .riftService:
            .riftRestart
        case .clip:
            nil
        }
    }

    private var enterTitle: String {
        switch self {
        case .pane, .rex, .riftWindow: "Focus"
        case .riftWorkspace: "Switch"
        case .rexSession: "Show"
        case .recording: "Start Screen Recording"
        case .riftService: "Restart"
        case .clip: "Copy"
        default: "Open"
        }
    }

    private var enterExit: ItemAction.Exit {
        switch self {
        // Rift re-tiles around you; the fix shouldn't move your focus.
        case .riftService: .dismissRestore
        default: .dismiss
        }
    }

    /// Every chord this row answers, primary (↵) first. Key dispatch and the footer hint
    /// both read this list, so adding an action is appending an entry here and nothing else.
    public var actions: [ItemAction] {
        var list: [ItemAction] = []
        if case .clip(let clip) = self {
            // History is strict MRU: opening a clip never boosts it. Re-copying re-lands
            // it on top via the monitor's own capture, so time stays the ranking.
            list.append(ItemAction(chord: .enter, title: enterTitle, keyLabel: "↵", run: .copy(clip.text), exit: .dismissRestore, tracksUse: false))
        } else if case .workflow(let workflow) = self {
            list.append(ItemAction(chord: .enter, title: "Select Workflow", keyLabel: "↵", run: .chooseWorkflow(workflow), exit: .stay, tracksUse: false))
        } else if case .workflowBranch(let branch, _, let workflow) = self {
            let title = workflow.inputs.isEmpty ? "Run Workflow" : "Select Branch"
            list.append(ItemAction(chord: .enter, title: title, keyLabel: "↵", run: .chooseBranch(branch), exit: .stay, tracksUse: false))
        } else if case .workflowInput(_, let value, _) = self {
            list.append(ItemAction(chord: .enter, title: "Use Value", keyLabel: "↵", run: .chooseInput(value), exit: .stay, tracksUse: false))
        } else if let primary {
            list.append(ItemAction(chord: .enter, title: enterTitle, keyLabel: "↵", run: .perform(primary), exit: enterExit))
        }
        if case .project(let project) = self, project.repository != nil, !project.workflows.isEmpty {
            list.append(ItemAction(chord: .runWorkflow, title: "Run Workflow", keyLabel: "⌃R", run: .startWorkflow(project), exit: .stay))
        }
        if let link {
            let openTitle = if case .project = self { "Open on GitHub" } else { "Open Link" }
            list.append(ItemAction(
                chord: .open, title: openTitle, keyLabel: "⌃O",
                run: .perform(.link(link)), exit: .dismiss
            ))
            list.append(ItemAction(
                chord: .yank, title: "Copy Link", keyLabel: "⌃Y",
                run: .copy(link.absoluteString), exit: .dismissRestore
            ))
        }
        if case .riftWindow(let window) = self {
            for index in 0..<10 {
                list.append(ItemAction(
                    chord: .moveWindow(index), title: "Move to Workspace \(index + 1)",
                    keyLabel: "⌘\(index == 9 ? 0 : index + 1)",
                    run: .perform(.riftMove(windowID: window.id, workspace: index)),
                    exit: .dismissRestore
                ))
            }
            list.append(ItemAction(
                chord: .fullscreen, title: "Fullscreen", keyLabel: "⌃F",
                run: .perform(.riftFullscreen(window)), exit: .dismiss
            ))
        }
        if case .app(let app) = self, app.running {
            list.append(ItemAction(
                chord: .restart, title: "Restart", keyLabel: "⌘R",
                run: .perform(.restartApp(app.url)), exit: .dismissRestore, tracksUse: false
            ))
            list.append(ItemAction(
                chord: .quit, title: "Quit", keyLabel: "⌃⇧Q",
                run: .perform(.quitApp(app.url)), exit: .dismissRestore, tracksUse: false
            ))
        }
        if let close {
            list.append(ItemAction(
                chord: .close, title: isNotice ? "Dismiss" : "Close", keyLabel: "⌘W",
                run: .perform(close), exit: .stay, tracksUse: false
            ))
        }
        return list
    }

    private var isNotice: Bool {
        if case .notice = self { return true }
        return false
    }

    /// The collector this row came from.
    var source: Source {
        switch self {
        case .pane: .herdr
        case .rex, .rexSession, .notice: .rex
        case .t3: .t3
        case .message: .slack
        case .contact: .contacts
        case .group: .groups
        case .tab(let tab): .browser(tab.browser)
        case .app: .apps
        case .project, .workflow, .workflowBranch, .workflowInput: .projects
        case .recording: .quickTime
        case .clip: .clipboard
        case .riftWindow, .riftWorkspace, .riftService: .rift
        }
    }

    private static func host(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString),
              let host = components.host, !host.isEmpty else { return urlString }
        guard let port = components.port else { return host }
        let scheme = components.scheme?.lowercased()
        if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) { return host }
        return "\(host):\(port)"
    }
}

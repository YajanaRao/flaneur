import AppKit
import Carbon.HIToolbox
import Foundation
import SQLite3
import Testing
@testable import FlaneurKit

struct LauncherStateTests {
    @Test func secondSubmitWhileHiddenEmitsNothing() {
        var state = LauncherState()
        #expect(state.handle(.submit) == [])

        _ = state.handle(.toggle)
        let app = AppEntry(url: URL(fileURLWithPath: "/Applications/Alpha.app"), name: "Alpha", running: true)
        _ = state.handle(.collected(.apps, generation: 1, .apps([app])))
        #expect(state.handle(.submit) == [.dismiss(restoreFocus: false), .perform(.app(app.url), generation: 1)])
        #expect(state.phase == .hidden)
        #expect(state.handle(.submit) == [])
    }

    @Test func olderGenerationDoesNotReplaceNewerSnapshot() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let older = HerdrPane(pane: PaneID(raw: "old"), tab: TabID(raw: "t"), title: "old", subtitle: "", agent: false)
        let newer = HerdrPane(pane: PaneID(raw: "new"), tab: TabID(raw: "t"), title: "new", subtitle: "", agent: true)
        _ = state.handle(.collected(.herdr, generation: 2, .panes(.success([newer]))))
        _ = state.handle(.collected(.herdr, generation: 1, .panes(.success([older]))))
        #expect(state.rows.map(\.title) == ["new"])
        #expect(Item.pane(newer).primary == .herdrAgent(PaneID(raw: "new")))
        #expect(Item.pane(older).primary == .herdrTab(TabID(raw: "t")))
    }

    @Test func pinSurvivesSnapshotAndFallsBackToTop() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let alpha = AppEntry(url: URL(fileURLWithPath: "/Applications/Alpha.app"), name: "Alpha", running: true)
        let beta = AppEntry(url: URL(fileURLWithPath: "/Applications/Beta.app"), name: "Beta", running: false)
        _ = state.handle(.collected(.apps, generation: 1, .apps([alpha, beta])))
        _ = state.handle(.move(.down))
        #expect(state.selection == .pinned(Item.app(beta).id))

        _ = state.handle(.collected(.apps, generation: 2, .apps([beta, alpha])))
        #expect(state.selection == .pinned(Item.app(beta).id))
        #expect(state.rows.first(where: \.selected)?.title == "Beta")

        _ = state.handle(.collected(.apps, generation: 3, .apps([alpha])))
        #expect(state.selection == .top)
        #expect(state.rows.first(where: \.selected)?.title == "Alpha")
    }

    @Test func rankingPrefersTitleHitAndCapsAt100() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let subtitleHit = BrowserTab(
            browser: .brave,
            windowID: "w",
            tabID: "t",
            title: "notes",
            url: "https://hello.example/x"
        )
        let titleHit = AppEntry(
            url: URL(fileURLWithPath: "/Applications/Hello.app"),
            name: "hello",
            running: false
        )
        _ = state.handle(.collected(.browser(.brave), generation: 1, .tabs(.success([subtitleHit]))))
        _ = state.handle(.collected(.apps, generation: 1, .apps([titleHit])))
        _ = state.handle(.query("hello"))
        #expect(state.rows.first?.title == "hello")

        var capped = LauncherState()
        _ = capped.handle(.toggle)
        let apps = (0..<150).map { index in
            AppEntry(
                url: URL(fileURLWithPath: "/Applications/Item\(index).app"),
                name: "Item\(index)",
                running: false
            )
        }
        _ = capped.handle(.collected(.apps, generation: 1, .apps(apps)))
        #expect(capped.rows.count == 100)
        #expect(capped.rows.first?.title == "Item0")
        _ = capped.handle(.query("Item"))
        #expect(capped.rows.count == 100)
    }

    @Test func emptyQueryOrderIsHerdrThenBrowsersThenApps() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let pane = HerdrPane(pane: PaneID(raw: "p"), tab: TabID(raw: "t"), title: "Pane", subtitle: "cwd", agent: true, status: "working")
        let helium = BrowserTab(browser: .helium, windowID: "hw", tabID: "ht", title: "HeliumTab", url: "https://helium.example")
        let brave = BrowserTab(browser: .brave, windowID: "bw", tabID: "bt", title: "BraveTab", url: "https://brave.example")
        let app = AppEntry(url: URL(fileURLWithPath: "/Applications/Zed.app"), name: "Zed", running: true)
        _ = state.handle(.collected(.browser(.helium), generation: 1, .tabs(.success([helium]))))
        _ = state.handle(.collected(.apps, generation: 1, .apps([app])))
        _ = state.handle(.collected(.herdr, generation: 1, .panes(.success([pane]))))
        _ = state.handle(.collected(.browser(.brave), generation: 1, .tabs(.success([brave]))))
        #expect(state.rows.map(\.title) == ["Pane", "BraveTab", "HeliumTab", "Zed"])
        #expect(state.rows.map(\.subtitle) == ["cwd", "brave.example", "helium.example", "running"])
        #expect(state.rows.map(\.icon) == [
            .application(Terminal.bundleID),
            .application(Browser.brave.bundleID),
            .application(Browser.helium.bundleID),
            .file("/Applications/Zed.app"),
        ])
        #expect(state.rows.map(\.badge) == ["working", "", "", ""])
        _ = state.handle(.query("working"))
        #expect(state.rows.map(\.title) == ["Pane"])
    }

    @Test func screenRecordingWaitsForAQuery() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let row = Recording(title: "Screen Recording", subtitle: "QuickTime Player")
        _ = state.handle(.collected(.quickTime, generation: 1, .recordings([row])))
        #expect(state.rows.isEmpty)

        _ = state.handle(.query("screen"))
        #expect(state.rows.map(\.title) == ["Screen Recording"])
        #expect(state.rows.map(\.subtitle) == ["QuickTime Player"])
        #expect(state.rows.map(\.icon) == [.application(QuickTime.bundleID)])
        #expect(state.handle(.submit) == [.dismiss(restoreFocus: false), .perform(.screenRecording, generation: 1)])
    }

    @Test func t3ThreadsListAtRestAndOpenByDeepLink() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let thread = T3Thread(
            threadID: "t1", environmentID: "e1", title: "Fix the launcher",
            project: "bento", branch: "dev", updatedAt: Date()
        )
        _ = state.handle(.collected(.t3, generation: 1, .t3Threads(.success([thread]))))
        #expect(state.rows.map(\.title) == ["Fix the launcher"])
        #expect(state.rows.map(\.subtitle) == ["bento · dev"])
        #expect(state.rows.map(\.icon) == [.application(T3Code.bundleID)])

        // The hidden term finds every thread, as "slack" does for messages.
        _ = state.handle(.query("t3"))
        #expect(state.rows.count == 1)
        #expect(
            state.handle(.submit)
                == [.dismiss(restoreFocus: false), .perform(.t3Thread(environmentID: "e1", threadID: "t1"), generation: 1)]
        )
    }

    @Test func t3ThreadsComeFromTheStateDatabase() throws {
        let path = NSTemporaryDirectory() + "/flaneur-t3-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let setup = """
        CREATE TABLE orchestration_v2_projection_threads (
          thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
          payload_json TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT);
        CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL);
        INSERT INTO projection_projects VALUES ('p1', 'bento');
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, payload_json, updated_at) VALUES
          ('t1', 'p1', 'Fix the launcher', '{"branch":"dev"}', '2026-11-03T15:41:52.120Z'),
          ('t2', 'p1', 'Older thread', '{}', '2026-11-02T10:00:00Z');
        INSERT INTO orchestration_v2_projection_threads
          (thread_id, project_id, title, payload_json, updated_at, deleted_at) VALUES
          ('t3', 'p1', 'Gone', '{}', '2026-11-03T16:00:00Z', '2026-11-03T16:01:00Z');
        """
        #expect(sqlite3_exec(database, setup, nil, nil, nil) == SQLITE_OK)

        let threads = try T3Code.threads(database: path, environmentID: "env")
        #expect(threads.map(\.threadID) == ["t1", "t2"]) // newest first, deleted row skipped
        #expect(threads.map(\.title) == ["Fix the launcher", "Older thread"])
        #expect(threads.map(\.project) == ["bento", "bento"])
        #expect(threads.map(\.branch) == ["dev", ""])
        #expect(threads.first?.environmentID == "env")
        #expect(threads.first?.updatedAt != .distantPast)
    }

    @Test func herdrThatNeedsYouLeadsTheIdleList() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let working = HerdrPane(pane: PaneID(raw: "p1"), tab: TabID(raw: "t1"), title: "Working", subtitle: "", agent: true, status: "working")
        let blocked = HerdrPane(pane: PaneID(raw: "p2"), tab: TabID(raw: "t2"), title: "Blocked", subtitle: "", agent: true, status: "blocked")
        let done = HerdrPane(pane: PaneID(raw: "p3"), tab: TabID(raw: "t3"), title: "Done", subtitle: "", agent: true, status: "done")
        let quiet = HerdrPane(pane: PaneID(raw: "p4"), tab: TabID(raw: "t4"), title: "Quiet", subtitle: "", agent: false, status: "")
        let app = AppEntry(url: URL(fileURLWithPath: "/Applications/Zed.app"), name: "Zed", running: true)
        _ = state.handle(.collected(.herdr, generation: 1, .panes(.success([working, blocked, done, quiet]))))
        _ = state.handle(.collected(.apps, generation: 1, .apps([app])))
        #expect(state.rows.map(\.title) == ["Blocked", "Done", "Working", "Quiet", "Zed"])

        // A typed query still prefers the better match. Attention only breaks a tie.
        let same = HerdrPane(pane: PaneID(raw: "p5"), tab: TabID(raw: "t5"), title: "notes", subtitle: "", agent: true, status: "working")
        let urgent = HerdrPane(pane: PaneID(raw: "p6"), tab: TabID(raw: "t6"), title: "notes", subtitle: "", agent: true, status: "blocked")
        let titled = AppEntry(url: URL(fileURLWithPath: "/Applications/Notes.app"), name: "notes", running: true)
        var search = LauncherState()
        _ = search.handle(.toggle)
        _ = search.handle(.collected(.herdr, generation: 1, .panes(.success([same, urgent]))))
        _ = search.handle(.collected(.apps, generation: 1, .apps([titled])))
        _ = search.handle(.query("notes"))
        #expect(search.rows.map(\.title) == ["notes", "notes", "notes"])
        #expect(search.rows.map(\.badge) == ["blocked", "working", ""])
    }

    @Test func herdrFailureLeavesOtherSources() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let app = AppEntry(url: URL(fileURLWithPath: "/Applications/Alpha.app"), name: "Alpha", running: true)
        _ = state.handle(.collected(.apps, generation: 1, .apps([app])))
        _ = state.handle(.collected(.herdr, generation: 1, .panes(.failure(.unavailable))))
        #expect(state.rows.map(\.title) == ["Alpha"])
        // herdr down is quiet: no rows, no footer complaint.
        #expect(state.failures.isEmpty)
    }

    @Test func resignWhileHoldingDoesNotHide() {
        var state = LauncherState()
        let effects = state.handle(.toggle)
        #expect(state.phase == .visible(.holding))
        #expect(effects.first == .present)
        #expect(state.handle(.resigned) == [])
        #expect(state.phase == .visible(.holding))
        #expect(state.handle(.armResign) == [])
        #expect(state.phase == .visible(.live))
        #expect(state.handle(.resigned) == [.dismiss(restoreFocus: false)])
        #expect(state.phase == .hidden)
    }

    @Test func inFlightSourceIsNotCollectedTwice() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        #expect(state.handle(.escape) == [.dismiss(restoreFocus: true)])
        #expect(state.handle(.toggle) == [.present])
        #expect(state.phase == .visible(.holding))
    }

    @Test func snapshotRowsUseTheTaskTitle() throws {
        let snapshot = """
        {"result":{"type":"session_snapshot","snapshot":{
          "focused_pane_id":"w1:p2","focused_tab_id":"w1:t2","focused_workspace_id":"w1",
          "workspaces":[
            {"workspace_id":"w1","label":"bento","number":1},
            {"workspace_id":"w2","label":"","number":2}
          ],
          "tabs":[
            {"tab_id":"w1:t1","workspace_id":"w1","label":"1","number":1},
            {"tab_id":"w1:t2","workspace_id":"w1","label":"Fix search","number":2},
            {"tab_id":"w1:t3","workspace_id":"w1","label":"ser\\u001b[31mver\\u0007","number":3},
            {"tab_id":"w2:t1","workspace_id":"w2","label":"logs","number":1}
          ],
          "panes":[
            {"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","cwd":"/tmp/bento","terminal_title":"Fix search | bento","agent":"claude","agent_status":"blocked"},
            {"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","cwd":"/tmp/bento","terminal_title":"Start server","agent":"codex","agent_status":"working","label":"server logs"},
            {"pane_id":"w1:p3","tab_id":"w1:t3","workspace_id":"w1","cwd":"/tmp/plain","terminal_title":"","agent_status":"unknown"},
            {"pane_id":"w2:p1","tab_id":"w2:t1","workspace_id":"w2","cwd":"/tmp/other","terminal_title":"tail -f"}
          ],
          "agents":[
            {"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","agent":"claude","agent_status":"blocked","cwd":"/tmp/bento","terminal_title":"Fix search | bento"},
            {"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","agent":"codex","agent_status":"working","cwd":"/tmp/bento","terminal_title":"Start server"}
          ]
        }}}
        """.data(using: .utf8)!
        let parsed = try Herdr.panes(from: snapshot)
        #expect(parsed.map(\.title) == [
            "Fix search", "Fix search", "server", "logs", "server logs", "bento", "workspace 2",
        ])
        #expect(parsed.map(\.subtitle) == [
            "bento · claude · /tmp/bento",
            "bento · codex · Start server",
            "bento · /tmp/plain",
            "tail -f",
            "bento · codex · Fix search",
            "claude · codex",
            "",
        ])
        #expect(parsed.map(\.status) == ["blocked", "working", "", "", "working", "blocked", ""])
        #expect(parsed[5].terms.contains("claude"))
        #expect(parsed.map(\.focused) == [false, true, false, false, false, false, false])
        #expect(parsed.map(\.kind) == [.agent, .agent, .tab, .tab, .named, .workspace, .workspace])
        #expect(Item.pane(parsed[0]).primary == .herdrAgent(PaneID(raw: "w1:p1")))
        #expect(Item.pane(parsed[2]).primary == .herdrTab(TabID(raw: "w1:t3")))
        #expect(Item.pane(parsed[4]).primary == .herdrNamed(PaneID(raw: "w1:p2"), tab: TabID(raw: "w1:t2")))
        #expect(Item.pane(parsed[5]).primary == .herdrWorkspace("w1"))
        #expect(Item.pane(parsed[4]).id != Item.pane(parsed[1]).id)
        #expect(Item.pane(parsed[5]).close == nil)

        let alone = """
        {"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","label":"bento","number":1}],"tabs":[],"panes":[],"agents":[]}}}
        """.data(using: .utf8)!
        #expect(try Herdr.panes(from: alone).isEmpty)
        #expect(throws: CollectFailure.malformed("session snapshot")) {
            try Herdr.panes(from: Data("{\"result\":{}}".utf8))
        }
    }

    @Test func runningCommandLeadsTheTerminalSubtitle() {
        let dev = """
        {"result":{"process_info":{
          "foreground_process_group_id":14680,
          "foreground_processes":[
            {"pid":14759,"name":"esbuild","cmdline":"/Users/yajanarao/Developer/tofu/node_modules/@esbuild/darwin-arm64/bin/esbuild --service=0.27.7 --ping"},
            {"pid":14681,"name":"node","cmdline":"node /Users/yajanarao/Developer/tofu/node_modules/.bin/react-router dev"},
            {"pid":14680,"name":"bun","cmdline":"bun dev"}
          ]
        }}}
        """.data(using: .utf8)!
        #expect(Herdr.service(from: dev) == "bun dev")

        let shell = """
        {"result":{"process_info":{"foreground_process_group_id":1,"foreground_processes":[{"pid":1,"name":"zsh","cmdline":"-zsh"}]}}}
        """.data(using: .utf8)!
        #expect(Herdr.service(from: shell) == nil)

        let editor = """
        {"result":{"process_info":{"foreground_process_group_id":2,"foreground_processes":[{"pid":2,"name":"nvim","cmdline":"nvim"}]}}}
        """.data(using: .utf8)!
        let nvim = HerdrPane(
            pane: PaneID(raw: "p"), tab: TabID(raw: "t"), title: "sidebar.tsx - Nvim",
            subtitle: "~/Developer/tofu", agent: false
        )
        #expect(Herdr.showing(Herdr.service(from: editor), on: nvim).subtitle == "~/Developer/tofu")

        let server = HerdrPane(
            pane: PaneID(raw: "p"), tab: TabID(raw: "t"), title: "tofu", subtitle: "~/Developer/tofu", agent: false
        )
        let shown = Herdr.showing("bun dev", on: server)
        #expect(shown.subtitle == "bun dev · ~/Developer/tofu")
        #expect(shown.terms == ["bun dev"])

        let agent = HerdrPane(
            pane: PaneID(raw: "p"), tab: TabID(raw: "t"), title: "Image #8 issue", subtitle: "tofu · claude",
            agent: true
        )
        #expect(Herdr.showing("claude", on: agent).subtitle == "tofu · claude")
    }

    @Test func faviconUsesThePageThenTheSiteOrigin() throws {
        let page = "https://github.com/acme/tofu/pull/1?utm=1#diff"
        #expect(Favicons.lookupKeys(page) == [
            "https://github.com/acme/tofu/pull/1?utm=1#diff",
            "https://github.com/acme/tofu/pull/1",
            "https://github.com/",
            "https://github.com",
        ])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("Favicons").path
        let exact = Data([1, 2, 3, 4, 5, 6, 7, 8, 9])
        let origin = Data([9, 8, 7, 6, 5, 4, 3, 2, 1])
        try Favicons.makeTestDatabase(at: database, pages: [
            "https://github.com/acme/tofu/pull/1": exact,
            "https://github.com/": origin,
        ])
        #expect(Favicons.image(forPage: page, database: database) == exact)
        #expect(Favicons.image(forPage: "https://github.com/acme/bento/issues", database: database) == origin)
        #expect(Favicons.image(forPage: "https://example.com/missing", database: database) == nil)

        let tab = BrowserTab(
            browser: .brave, windowID: "w", tabID: "t", title: "PR", url: page, favicon: exact
        )
        #expect(Item.tab(tab).icon == .picture(exact, fallback: Browser.brave.bundleID))
    }

    @Test func themeFallsBackPerKeyAndIgnoresHotkey() {
        let theme = Theme.parsing(
            """
            hotkey = "ctrl+space"

            [theme.dark]
            background = "#112233"
            text = "nope"

            [theme.light]
            accent = "#ABCDEF"
            """
        )
        #expect(theme.dark.codes.background == 0x112233)
        #expect(theme.dark.codes.text == Theme.defaults.dark.codes.text)
        #expect(theme.dark.codes.muted == Theme.defaults.dark.codes.muted)
        #expect(theme.dark.codes.accent == Theme.defaults.dark.codes.accent)
        #expect(theme.light.codes.accent == 0xABCDEF)
        #expect(theme.light.codes.background == Theme.defaults.light.codes.background)
        #expect(theme.light.codes.rule == Theme.defaults.light.codes.rule)
        // Defaults mirror the Rex terminal: misty-forest dark, orchard-breeze light.
        #expect(Theme.defaults.dark.codes.background == 0x131A16)
        #expect(Theme.defaults.light.codes.onAccent == 0xF4F9EF)
    }

    @Test func failedActivationDoesNotReopen() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.escape)
        let effects = state.handle(.activationFinished(generation: 1))
        #expect(!effects.contains { if case .present = $0 { return true }; return false })
        #expect(state.phase == .hidden)
        _ = state.handle(.toggle)
        #expect(state.phase == .visible(.holding))
        #expect(state.handle(.activationFinished(generation: 1)) == [])
        #expect(state.phase == .visible(.holding))
    }

    @Test func controlJAndKMoveLikeArrows() {
        #expect(Key(event: keyEvent(38, .control)) == .down)
        #expect(Key(event: keyEvent(40, .control)) == .up)
        #expect(Key(event: keyEvent(38, [])) == nil)
        #expect(Key(event: keyEvent(40, [])) == nil)
        #expect(Key(event: keyEvent(125, [])) == .down)
        #expect(Key(event: keyEvent(126, [])) == .up)
    }

    @Test func controlOAndYOpenAndYankOnlyWithControl() {
        #expect(Key(event: keyEvent(31, .control)) == .open)
        #expect(Key(event: keyEvent(16, .control)) == .yank)
        #expect(Key(event: keyEvent(31, [])) == nil)
        #expect(Key(event: keyEvent(16, .command)) == nil)
        #expect(Key(event: keyEvent(13, .command)) == .close)
        #expect(Key(event: keyEvent(13, .control)) == nil)
        #expect(Key(event: keyEvent(13, [])) == nil)
        #expect(Key(event: keyEvent(32, .control)) == .clear)
        #expect(Key(event: keyEvent(32, [])) == nil)
    }

    @Test func controlUClearsTheQueryAndKeepsThePanel() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let alpha = AppEntry(url: URL(fileURLWithPath: "/Applications/Alpha.app"), name: "Alpha", running: true)
        let beta = AppEntry(url: URL(fileURLWithPath: "/Applications/Beta.app"), name: "Beta", running: false)
        _ = state.handle(.collected(.apps, generation: 1, .apps([alpha, beta])))
        _ = state.handle(.query("beta"))
        _ = state.handle(.move(.down))
        #expect(state.query == "beta")
        #expect(state.footer.map(\.title) == ["Open", "Clear"])
        #expect(state.handle(.clearLine) == [])
        #expect(state.phase == .visible(.holding))
        #expect(state.query == "")
        #expect(state.selection == .top)
        #expect(state.rows.first?.title == "Alpha")
    }

    @Test func commandWClosesTheTabAndKeepsThePanel() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let first = BrowserTab(browser: .brave, windowID: "w", tabID: "t1", title: "First", url: "https://example.com/a")
        let second = BrowserTab(browser: .brave, windowID: "w", tabID: "t2", title: "Second", url: "https://example.com/b")
        let app = AppEntry(url: URL(fileURLWithPath: "/Applications/Alpha.app"), name: "Alpha", running: true)
        let kept = HerdrPane(pane: PaneID(raw: "p1"), tab: TabID(raw: "tab-a"), title: "Kept", subtitle: "", agent: false)
        let sibling = HerdrPane(pane: PaneID(raw: "p2"), tab: TabID(raw: "tab-b"), title: "Sibling", subtitle: "", agent: false)
        let sameTab = HerdrPane(pane: PaneID(raw: "p3"), tab: TabID(raw: "tab-b"), title: "SameTab", subtitle: "", agent: true)
        _ = state.handle(.collected(.browser(.brave), generation: 1, .tabs(.success([first, second]))))
        _ = state.handle(.collected(.apps, generation: 1, .apps([app])))
        _ = state.handle(.collected(.herdr, generation: 1, .panes(.success([kept, sibling, sameTab]))))

        let effects = state.handle(.close)
        #expect(effects == [.perform(.closeHerdr(TabID(raw: "tab-a")), generation: 1)])
        #expect(state.phase == .visible(.holding))
        #expect(state.rows.map(\.title) == ["Sibling", "SameTab", "First", "Second", "Alpha"])

        _ = state.handle(.move(.down))
        _ = state.handle(.close)
        #expect(state.rows.map(\.title) == ["First", "Second", "Alpha"])
        #expect(state.rows.first(where: \.selected)?.title == "First")

        _ = state.handle(.close)
        #expect(state.rows.map(\.title) == ["Second", "Alpha"])
        // A collect that was already in flight must not put the closed tab back.
        _ = state.handle(.collected(.browser(.brave), generation: 1, .tabs(.success([first, second]))))
        #expect(state.rows.map(\.title) == ["Second", "Alpha"])

        _ = state.handle(.move(.down))
        #expect(state.rows.first(where: \.selected)?.title == "Alpha")
        #expect(state.handle(.close) == [])
        #expect(state.rows.map(\.title) == ["Second", "Alpha"])
    }

    @Test func openAndYankUseTheSelectedRowsLink() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let tab = BrowserTab(browser: .brave, windowID: "w", tabID: "t", title: "PR", url: "https://example.com/pr/1")
        let app = AppEntry(url: URL(fileURLWithPath: "/Applications/Alpha.app"), name: "Alpha", running: true)
        _ = state.handle(.collected(.browser(.brave), generation: 1, .tabs(.success([tab]))))
        _ = state.handle(.collected(.apps, generation: 1, .apps([app])))
        let link = URL(string: "https://example.com/pr/1")!
        #expect(state.footer.map(\.title) == ["Open", "Open Link", "Copy Link", "Close"])
        #expect(state.footer.map(\.keyLabel) == ["↵", "⌃O", "⌃Y", "⌘W"])
        #expect(state.handle(.open) == [.dismiss(restoreFocus: false), .perform(.link(link), generation: 1)])
        #expect(state.phase == .hidden)

        _ = state.handle(.toggle)
        _ = state.handle(.collected(.browser(.brave), generation: 2, .tabs(.success([tab]))))
        _ = state.handle(.collected(.apps, generation: 2, .apps([app])))
        #expect(state.handle(.yank) == [.copy(link.absoluteString), .dismiss(restoreFocus: true)])
        #expect(state.phase == .hidden)

        // Running apps carry Quit and Restart; a non-running one has neither.
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.browser(.brave), generation: 3, .tabs(.success([tab]))))
        _ = state.handle(.collected(.apps, generation: 3, .apps([app])))
        _ = state.handle(.move(.down))
        #expect(state.footer.map(\.title) == ["Open", "Restart", "Quit"])
        #expect(state.handle(.open) == [])
        #expect(state.handle(.yank) == [])
        #expect(state.handle(.quit) == [
            .perform(.quitApp(app.url), generation: 3),
            .dismiss(restoreFocus: true),
        ])
        #expect(state.phase == .hidden)

        _ = state.handle(.toggle)
        _ = state.handle(.collected(.apps, generation: 4, .apps([app])))
        // The tab lingers from its last collect and outranks the app (recents): step onto Alpha.
        _ = state.handle(.move(.down))
        #expect(state.handle(.restart) == [
            .perform(.restartApp(app.url), generation: 4),
            .dismiss(restoreFocus: true),
        ])

        var still = LauncherState()
        _ = still.handle(.toggle)
        _ = still.handle(.collected(.apps, generation: 1, .apps([
            AppEntry(url: URL(fileURLWithPath: "/Applications/Beta.app"), name: "Beta", running: false)
        ])))
        #expect(still.footer.map(\.title) == ["Open"])
        #expect(still.handle(.quit) == [])
        #expect(still.handle(.restart) == [])
    }

    @Test func slackMessagesSitAfterHerdrAndLinkPrefersBodyURL() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let pane = HerdrPane(pane: PaneID(raw: "p"), tab: TabID(raw: "t"), title: "Pane", subtitle: "cwd", agent: false)
        let permalink = URL(string: "https://acme.slack.com/archives/C1/p1700000000000100")!
        let body = URL(string: "https://github.com/acme/bento/pull/647")!
        let withLink = SlackMessage(
            team: "T1", channel: "C1", ts: "1700000000.000100", place: "#eng", author: "Rohan",
            text: "PR is up github.com/acme/bento/pull/647", link: body, permalink: permalink,
            date: Date(timeIntervalSinceNow: -120)
        )
        let plain = SlackMessage(
            team: "T1", channel: "D1", ts: "1700000000.000200", place: "DM", author: "Priya",
            text: "lunch?", link: nil, permalink: permalink, date: Date(timeIntervalSinceNow: -7200),
            image: "https://avatars.slack-edge.com/priya.png"
        )
        let tab = BrowserTab(browser: .brave, windowID: "bw", tabID: "bt", title: "BraveTab", url: "https://brave.example")
        _ = state.handle(.collected(.browser(.brave), generation: 1, .tabs(.success([tab]))))
        _ = state.handle(.collected(.slack, generation: 1, .messages(.success([withLink, plain]))))
        _ = state.handle(.collected(.herdr, generation: 1, .panes(.success([pane]))))
        #expect(state.rows.map(\.title) == ["Pane", "Rohan", "Priya", "BraveTab"])
        #expect(state.rows.map(\.subtitle) == ["cwd", "PR is up github.com/acme/bento/pull/647", "lunch?", "brave.example"])
        #expect(state.rows.map(\.badge) == ["", "#eng · 2m", "DM · 2h", ""])
        #expect(state.rows[1].icon == .application(Slack.bundleID))
        #expect(state.rows[2].icon == .remote(url: "https://avatars.slack-edge.com/priya.png", fallback: Slack.bundleID))
        #expect(Item.message(withLink).link == body)
        #expect(Item.message(plain).link == permalink)
        #expect(Item.message(plain).primary == .slack(team: "T1", channel: "D1", ts: "1700000000.000200"))
        _ = state.handle(.query("eng"))
        #expect(state.rows.map(\.title) == ["Rohan"])
        _ = state.handle(.query("slack"))
        #expect(state.rows.map(\.title) == ["Rohan", "Priya"])
    }

    @Test func slackContactIsFoundByNameAndOpensTheDM() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let contact = SlackContact(
            team: "T1", user: "U9", name: "Rohan", handle: "rohan", title: "Engineer", realName: "Rohan Sharma"
        )
        let app = AppEntry(url: URL(fileURLWithPath: "/Applications/Alpha.app"), name: "Alpha", running: true)
        _ = state.handle(.collected(.contacts, generation: 1, .contacts(.success([contact]))))
        _ = state.handle(.collected(.apps, generation: 1, .apps([app])))
        #expect(state.rows.map(\.title) == ["Alpha"])
        _ = state.handle(.query("sharma"))
        #expect(state.rows.map(\.title) == ["Rohan"])
        #expect(state.rows.map(\.subtitle) == ["Engineer"])
        #expect(state.rows.map(\.badge) == ["DM"])
        #expect(Item.contact(contact).primary == .slackContact(team: "T1", user: "U9"))
        #expect(
            state.handle(.submit) == [
                .dismiss(restoreFocus: false),
                .perform(.slackContact(team: "T1", user: "U9"), generation: 1),
            ]
        )
    }

    @Test func slackDirectoryDropsBotsDeactivatedAndSelf() throws {
        let json = """
        {"members":[
          {"id":"U1","name":"rohan","real_name":"Rohan Sharma","profile":{"display_name":"Rohan","title":"Engineer","image_72":"https://avatars.slack-edge.com/rohan.png"}},
          {"id":"U2","name":"me","profile":{"display_name":"Me"}},
          {"id":"B1","name":"helper","is_bot":true,"profile":{"display_name":"Helper"}},
          {"id":"U3","name":"gone","deleted":true,"profile":{"display_name":"Gone"}},
          {"id":"USLACKBOT","name":"slackbot","profile":{"display_name":"slackbot"}}
        ]}
        """.data(using: .utf8)!
        let people = try Slack.people(list: json, team: "T1", selfID: "U2")
        #expect(people.map(\.name) == ["Rohan"])
        #expect(people.map(\.user) == ["U1"])
        #expect(people.map(\.handle) == ["rohan"])
        #expect(people.map(\.image) == ["https://avatars.slack-edge.com/rohan.png"])
        #expect(Slack.picture("http://avatars.slack-edge.com/rohan.png") == nil)

        var failed = LauncherState()
        _ = failed.handle(.toggle)
        _ = failed.handle(.collected(.slack, generation: 1, .messages(.failure(.denied))))
        #expect(failed.failures == ["slack denied"])
    }

    @Test func slackGroupsAreSearchOnlyAndOpenInSlack() throws {
        let json = """
        {"channels":[
          {"id":"C1","name":"engineering","is_private":false},
          {"id":"G1","name":"leadership","is_private":true},
          {"id":"M1","name":"mpdm-alice--bob--carol-1","is_mpim":true},
          {"id":"D1","is_im":true,"user":"U1"}
        ]}
        """.data(using: .utf8)!
        let groups = try Slack.groups(list: json, team: "T1")
        #expect(groups.map(\.name) == ["#engineering", "#leadership", "alice, bob, carol"])
        #expect(groups.map(\.kind) == ["channel", "private channel", "group DM"])

        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.groups, generation: 1, .groups(.success(groups))))
        #expect(state.rows.isEmpty)
        _ = state.handle(.query("leadership"))
        #expect(state.rows.map(\.title) == ["#leadership"])
        #expect(state.rows.map(\.badge) == ["private channel"])
        #expect(
            state.handle(.submit) == [
                .dismiss(restoreFocus: false),
                .perform(.slackGroup(team: "T1", channel: "G1"), generation: 1),
            ]
        )
    }

    @Test func slackPreviewShowsWhileTheCollectIsStillRunning() {
        var state = LauncherState()
        let message = SlackMessage(
            team: "T1", channel: "C1", ts: "1700000000.000100", place: "#general", author: "Rohan",
            text: "ship it", link: nil, permalink: URL(string: "https://acme.slack.com/archives/C1/p1")!,
            date: Date(timeIntervalSinceNow: -30)
        )
        _ = state.handle(.updated(.slack, generation: 1, .messages(.success([message]))))
        #expect(state.rows.isEmpty)

        _ = state.handle(.toggle)
        _ = state.handle(.updated(.slack, generation: 1, .messages(.success([message]))))
        #expect(state.rows.map(\.title) == ["Rohan"])
        _ = state.handle(.escape)
        let again = state.handle(.toggle)
        #expect(again.contains { if case .collect(.slack, _) = $0 { return true }; return false } == false)
    }

    @Test func slackRenderFlattensMrkdwnAndFindsFirstLink() {
        let names = ["U1": "Rohan"]
        let (text, link) = Slack.render(
            "<@U1> see <https://github.com/acme/bento/pull/647|the PR> in <#C9|eng>\n<!here> &amp; <https://docs.example>",
            names: names
        )
        #expect(text == "@Rohan see the PR in #eng @here & https://docs.example")
        #expect(link == URL(string: "https://github.com/acme/bento/pull/647"))
        #expect(Slack.render("<@U7> hi", names: [:]).text == "@U7 hi")
        #expect(Slack.render("<!subteam^S1|@infra> ping  <mailto:a@b.c|a@b.c>", names: [:]).link == nil)
        #expect(Slack.render("<!subteam^S1|@infra> ping", names: [:]).text == "@infra ping")
        #expect(Slack.groupName("mpdm-alice--bob--carol-1") == "alice, bob, carol")
        #expect(
            Slack.permalink(base: URL(string: "https://acme.slack.com/")!, channel: "C1", ts: "1700000000.000100")
                == URL(string: "https://acme.slack.com/archives/C1/p1700000000000100")
        )
        let now = Date()
        #expect(Slack.age(now.addingTimeInterval(-10), now: now) == "now")
        #expect(Slack.age(now.addingTimeInterval(-90), now: now) == "1m")
        #expect(Slack.age(now.addingTimeInterval(-3 * 86400), now: now) == "3d")
    }

    @Test func slackSkipsHistoryUnlessSomethingIsNewerThanLastRead() {
        #expect(Slack.shouldFetchHistory(lastRead: "10", latest: "11", unreadDisplay: nil))
        #expect(!Slack.shouldFetchHistory(lastRead: "10", latest: "10", unreadDisplay: nil))
        #expect(!Slack.shouldFetchHistory(lastRead: "10", latest: nil, unreadDisplay: nil))
        #expect(Slack.shouldFetchHistory(lastRead: "10", latest: nil, unreadDisplay: nil, probeWithoutLatest: true))
        #expect(Slack.shouldFetchHistory(lastRead: "10", latest: nil, unreadDisplay: 3))
        #expect(!Slack.shouldFetchHistory(lastRead: nil, latest: "11", unreadDisplay: 3))
        #expect(!Slack.shouldFetchHistory(lastRead: "10", latest: "11", unreadDisplay: 0))
    }

    @Test func slackCountsNamesOnlyTheUnreadConversations() {
        let json = """
        {"channels":[
          {"id":"C1","last_read":"10","latest":{"ts":"12"},"has_unreads":true},
          {"id":"C2","last_read":"10","latest":"10","has_unreads":false},
          {"id":"C3","last_read":"10","latest":"10","has_unreads":true,"history_invalid":true},
          {"id":"C4","last_read":"8","latest":"8","has_unreads":true}
        ],"ims":[
          {"id":"D1","last_read":"5","latest":"9","has_unreads":true}
        ],"mpims":[
          {"id":"G1","has_unreads":false}
        ]}
        """.data(using: .utf8)!
        let targets = Slack.unreadTargets(counts: json)
        #expect(targets?.map(\.id) == ["C1", "C3", "D1"])
        #expect(targets?.map(\.lastRead) == ["10", nil, "5"])
        #expect(targets?.map(\.kind) == [.channel, .channel, .im])
        #expect(Slack.unreadTargets(counts: Data("{\"ok\":true}".utf8)) == nil)
        #expect(Slack.unreadTargets(counts: Data("{\"channels\":[]}".utf8)) == nil)
    }

    @Test func githubWordsNameTheOpenRepoPage() {
        #expect(GitHub.words(for: "https://github.com/acme/tofu") == "github tofu")
        #expect(GitHub.words(for: "https://github.com/acme/tofu/tree/main/src") == "github tofu")
        #expect(GitHub.words(for: "https://github.com/acme/Tofu/blob/main/README.md") == "github tofu")
        #expect(GitHub.words(for: "https://github.com/acme/tofu/actions?query=branch%3Amain") == "github tofu actions")
        #expect(GitHub.words(for: "https://github.com/acme/tofu/pulls") == "github tofu pulls")
        #expect(GitHub.words(for: "https://github.com/acme/tofu/pull/647/files") == "github tofu pulls")
        #expect(GitHub.words(for: "https://github.com/acme/tofu/issues") == "github tofu issues")
        #expect(GitHub.words(for: "https://github.com/acme/tofu/releases/tag/v1") == "github tofu releases")
        #expect(GitHub.words(for: "https://github.com/acme/bento/actions/runs/9") == "github bento actions")
        #expect(GitHub.words(for: "https://www.github.com/acme/tofu/settings") == "github tofu settings")
        #expect(GitHub.words(for: "https://github.com/notifications") == nil)
        #expect(GitHub.words(for: "https://example.com/acme/tofu/actions") == nil)
    }

    @Test func githubQueryFocusesTheOpenTab() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let actions = BrowserTab(
            browser: .brave, windowID: "w", tabID: "actions", title: "Upgrade the login",
            url: "https://github.com/acme/tofu/actions"
        )
        let pull = BrowserTab(
            browser: .brave, windowID: "w", tabID: "pull", title: "Fix login",
            url: "https://github.com/acme/tofu/pull/647"
        )
        let bento = BrowserTab(
            browser: .helium, windowID: "hw", tabID: "bento", title: "Actions",
            url: "https://github.com/acme/bento/actions"
        )
        let other = BrowserTab(
            browser: .brave, windowID: "w", tabID: "notes", title: "Notes", url: "https://example.com/notes"
        )
        _ = state.handle(.collected(.browser(.brave), generation: 1, .tabs(.success([actions, pull, other]))))
        _ = state.handle(.collected(.browser(.helium), generation: 1, .tabs(.success([bento]))))

        #expect(state.rows.map(\.subtitle) == [
            "github tofu actions", "github tofu pulls", "example.com", "github bento actions",
        ])

        _ = state.handle(.query("github tofu actions"))
        #expect(state.rows.map(\.title) == ["Upgrade the login"])
        #expect(state.rows.map(\.subtitle) == ["github tofu actions"])

        _ = state.handle(.query("github tofu pulls"))
        #expect(state.rows.map(\.title) == ["Fix login"])

        _ = state.handle(.query("github tofu"))
        #expect(state.rows.map(\.title) == ["Upgrade the login", "Fix login"])

        _ = state.handle(.query("Upgrade the login"))
        #expect(state.rows.map(\.title) == ["Upgrade the login"])

        _ = state.handle(.query("github tofu actions"))
        #expect(
            state.handle(.submit) == [
                .dismiss(restoreFocus: false),
                .perform(.browser(.brave, windowID: "w", tabID: "actions"), generation: 1),
            ]
        )
    }

    @Test func termsMatchAcrossFieldsAndLightUpWhereTheyLanded() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let pane = HerdrPane(
            pane: PaneID(raw: "p"), tab: TabID(raw: "t"), title: "Fix search", subtitle: "bento",
            agent: true, status: "blocked", terms: ["claude", "/tmp/bento"]
        )
        let app = AppEntry(url: URL(fileURLWithPath: "/Applications/Hello.app"), name: "Hello", running: true)
        _ = state.handle(.collected(.herdr, generation: 1, .panes(.success([pane]))))
        _ = state.handle(.collected(.apps, generation: 1, .apps([app])))

        _ = state.handle(.query("bento claude"))
        #expect(state.rows.map(\.title) == ["Fix search"])
        #expect(state.rows.first?.subtitleMarks == [Mark(start: 0, length: 5)])

        _ = state.handle(.query("bento nope"))
        #expect(state.rows.isEmpty)

        _ = state.handle(.query("\"fix search\""))
        #expect(state.rows.map(\.title) == ["Fix search"])
        #expect(state.rows.first?.titleMarks == [Mark(start: 0, length: 10)])

        _ = state.handle(.query("hel"))
        #expect(state.rows.map(\.title) == ["Hello"])
        #expect(state.rows.first?.titleMarks == [Mark(start: 0, length: 3)])
    }

    @Test func recentsLeadAndTheCurrentRowIsNotFirst() {
        let here = HerdrPane(
            pane: PaneID(raw: "here"), tab: TabID(raw: "t1"), title: "Here", subtitle: "",
            agent: true, status: "blocked", focused: true
        )
        let other = HerdrPane(
            pane: PaneID(raw: "other"), tab: TabID(raw: "t2"), title: "Other", subtitle: "", agent: true
        )
        let alpha = AppEntry(url: URL(fileURLWithPath: "/Applications/Alpha.app"), name: "Alpha", running: true)
        let beta = AppEntry(url: URL(fileURLWithPath: "/Applications/Beta.app"), name: "Beta", running: true)

        var plain = LauncherState()
        _ = plain.handle(.toggle)
        _ = plain.handle(.collected(.herdr, generation: 1, .panes(.success([here, other]))))
        _ = plain.handle(.collected(.apps, generation: 1, .apps([alpha])))
        #expect(plain.rows.map(\.title) == ["Other", "Here", "Alpha"])

        var recents = Recents()
        recents.touch(key: Item.app(beta).recentKey, title: "Beta")
        var state = LauncherState(recents: recents)
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.herdr, generation: 1, .panes(.success([here, other]))))
        _ = state.handle(.collected(.apps, generation: 1, .apps([alpha, beta])))
        #expect(state.rows.map(\.title) == ["Beta", "Here", "Other", "Alpha"])

        _ = state.handle(.frontmost(alpha.url))
        #expect(state.rows.map(\.title) == ["Beta", "Here", "Alpha", "Other"])

        var only = LauncherState()
        _ = only.handle(.toggle)
        _ = only.handle(.collected(.herdr, generation: 1, .panes(.success([here]))))
        #expect(only.rows.map(\.title) == ["Here"])
    }

    @Test func recentsRoundTripAndIgnoreACorruptFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("recent.json")
        var recents = Recents()
        recents.touch(key: "pane:a", title: "Alpha")
        recents.touch(key: "pane:b", title: "Beta")
        recents.save(to: url)
        let loaded = Recents.load(from: url)
        #expect(loaded.rank(key: "pane:b", title: "") == 0)
        #expect(loaded.rank(key: "missing", title: "Alpha") == 1)

        // Frecency: five uses outrank one newer use.
        var frecency = Recents()
        for _ in 0..<5 { frecency.touch(key: "daily", title: "") }
        frecency.touch(key: "scratch", title: "")
        #expect(frecency.rank(key: "daily", title: "") == 0)
        #expect(frecency.rank(key: "scratch", title: "") == 1)

        // Aging: over the budget every score decays by 0.9; a single old visit falls off.
        var aged = Recents()
        aged.touch(key: "once", title: "")
        for _ in 0..<3_500 { aged.touch(key: "pump", title: "") }
        #expect(aged.rank(key: "once", title: "") == nil)
        #expect(aged.rank(key: "pump", title: "") == 0)

        // A version-1 file (key and title only) keeps its order as the seed ranking.
        let legacy = """
        {"version":1,"entries":[{"key":"pane:a","title":"Alpha"},{"key":"pane:b","title":"Beta"}]}
        """
        try Data(legacy.utf8).write(to: url)
        let migrated = Recents.load(from: url)
        #expect(migrated.rank(key: "pane:a", title: "") == 0)
        #expect(migrated.rank(key: "pane:b", title: "") == 1)

        try Data("{not json".utf8).write(to: url)
        #expect(Recents.load(from: url).rank(key: "pane:b", title: "Beta") == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func rexRowsFocusAndCloseTheirBlock() throws {
        let json = """
        {
          "revision": 7,
          "session_id": "session:s1",
          "label": "arid-oasis",
          "active_window_id": "window:w1",
          "windows": [
            {
              "window_id": "window:w1",
              "label": "Window One",
              "focused_block_id": "block:b1",
              "layers": [
                { "layer_id": "layer:l1", "kind": "tiled",
                  "blocks": [
                    { "block_id": "block:b1", "label": "editor" },
                    { "block_id": "block:b2" }
                  ] },
                { "layer_id": "layer:l2", "kind": "floating",
                  "blocks": [ { "block_id": "block:b1", "label": "editor" } ] }
              ]
            }
          ]
        }
        """
        let blocks = try Rex.rows(from: Data(json.utf8))
        // A block in two layers lists once; a block with no label is a shell.
        #expect(blocks.map(\.label) == ["editor", "shell"])
        #expect(blocks.map(\.focused) == [true, false])
        #expect(blocks.first?.sessionLabel == "arid-oasis")
        #expect(Item.rex(blocks[0]).subtitle == "Window One · arid-oasis")
        #expect(Item.rex(blocks[0]).primary == .rexBlock(blockID: "block:b1", sessionID: "session:s1", windowID: "window:w1"))
        #expect(Item.rex(blocks[0]).close == .closeRex(blockID: "block:b1"))
        #expect(Item.rex(blocks[0]).icon == .application(Rex.bundleID))
        #expect(Item.rex(blocks[0]).recentKey == "rex:block:b1")
        #expect(Item.rex(blocks[0]).searchFields.map(\.text).contains("rex"))
    }

    @Test func rexBlocksSitAfterHerdrAndStayClosed() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let pane = HerdrPane(pane: PaneID(raw: "p"), tab: TabID(raw: "t"), title: "Pane", subtitle: "", agent: true)
        let block = RexBlock(
            blockID: "block:b1", windowID: "window:w1", sessionID: "session:s1",
            label: "editor", windowLabel: "Window One", sessionLabel: "arid-oasis"
        )
        let tab = BrowserTab(browser: .yab, windowID: "yw", tabID: "yt", title: "YabTab", url: "https://yab.example")
        _ = state.handle(.collected(.rex, generation: 1, .blocks(.success(RexListing(sessions: [], blocks: [block])))))
        _ = state.handle(.collected(.herdr, generation: 1, .panes(.success([pane]))))
        _ = state.handle(.collected(.browser(.yab), generation: 1, .tabs(.success([tab]))))
        #expect(state.rows.map(\.title) == ["Pane", "editor", "YabTab"])
        #expect(state.rows.map(\.icon) == [
            .application(Terminal.bundleID),
            .application(Rex.bundleID),
            .application(Browser.yab.bundleID),
        ])
        #expect(state.handle(.submit) == [.dismiss(restoreFocus: false), .perform(.herdrAgent(PaneID(raw: "p")), generation: 1)])

        var closing = LauncherState()
        _ = closing.handle(.toggle)
        _ = closing.handle(.collected(.rex, generation: 1, .blocks(.success(RexListing(sessions: [], blocks: [block])))))
        #expect(closing.handle(.close) == [.perform(.closeRex(blockID: "block:b1"), generation: 1)])
        #expect(closing.rows.isEmpty)
        // A collect that was already in flight must not put the closed block back.
        _ = closing.handle(.collected(.rex, generation: 1, .blocks(.success(RexListing(sessions: [], blocks: [block])))))
        #expect(closing.rows.isEmpty)
    }

    @Test func focusedRexBlockIsNotFirst() {
        let focused = RexBlock(
            blockID: "block:b1", windowID: "window:w1", sessionID: "session:s1",
            label: "here", windowLabel: "", sessionLabel: "", focused: true
        )
        let other = RexBlock(
            blockID: "block:b2", windowID: "window:w1", sessionID: "session:s1",
            label: "other", windowLabel: "", sessionLabel: ""
        )
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.rex, generation: 1, .blocks(.success(RexListing(sessions: [], blocks: [focused, other])))))
        #expect(state.rows.map(\.title) == ["other", "here"])
        #expect(state.handle(.submit) == [.dismiss(restoreFocus: false), .perform(.rexBlock(blockID: "block:b2", sessionID: "session:s1", windowID: "window:w1"), generation: 1)])
    }

    @Test func rexSessionsListAndDetachedBlocksSaySo() {
        let session = RexSession(sessionID: "session:s1", label: "arid-oasis", windowCount: 2)
        let detached = RexBlock(
            blockID: "block:b9", windowID: "", sessionID: "session:s1",
            label: "shell", windowLabel: "", sessionLabel: "arid-oasis", detached: true
        )
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(
            .rex, generation: 1,
            .blocks(.success(RexListing(sessions: [session], blocks: [detached])))
        ))
        #expect(state.rows.map(\.title) == ["shell", "arid-oasis"])
        #expect(Item.rex(detached).subtitle == "detached · arid-oasis")
        #expect(Item.rexSession(session).subtitle == "session · 2 tabs")
        #expect(Item.rexSession(session).primary == .rexSession(sessionID: "session:s1"))
        #expect(Item.rexSession(session).close == nil)
        #expect(Item.rexSession(session).searchFields.map(\.text).contains("rex"))
        #expect(state.handle(.submit) == [.dismiss(restoreFocus: false), .perform(.rexBlock(blockID: "block:b9", sessionID: "session:s1", windowID: ""), generation: 1)])
    }

    @Test func rexDesktopNotificationParsesIntoANotice() {
        let osc777 = #"{"type":"session_event","payload":{"session_id":"session:s1","event":{"type":"block_event","payload":{"block_id":"block:b1","creator_name":"com.superlogical.terminal","name":"desktop_notification","payload":{"title":"Build","body":"finished ok"}}}}}"#
        let now = Date(timeIntervalSince1970: 1000)
        let notice = RexEvents.notice(line: osc777, labels: ["session:s1": "arid-oasis"], now: now)
        #expect(notice?.title == "Build")
        #expect(notice?.body == "finished ok")
        #expect(notice?.blockID == "block:b1")
        #expect(notice?.sessionID == "session:s1")
        #expect(notice?.sessionLabel == "arid-oasis")
        #expect(notice?.date == now)

        // OSC 9 carries only a body; it becomes the title. An unknown session has no label.
        let osc9 = #"{"type":"session_event","payload":{"session_id":"session:s2","event":{"type":"block_event","payload":{"block_id":"block:b2","creator_name":"com.superlogical.terminal","name":"desktop_notification","payload":{"title":"","body":"needs attention"}}}}}"#
        let bare = RexEvents.notice(line: osc9, labels: [:])
        #expect(bare?.title == "needs attention")
        #expect(bare?.body == "")
        #expect(bare?.sessionLabel == "")

        // Other events, however noisy, are not notices.
        let process = #"{"type":"session_event","payload":{"session_id":"session:s1","event":{"type":"block_event","payload":{"block_id":"block:b1","creator_name":"com.superlogical.terminal","name":"process_changed","payload":{"generation":2}}}}}"#
        #expect(RexEvents.notice(line: process, labels: [:]) == nil)
        #expect(RexEvents.notice(line: #"{"type":"client_left","payload":{"client_id":"client:c1"}}"#, labels: [:]) == nil)

        let created = #"{"type":"session_created","payload":{"session":{"session_id":"session:s3","label":"flaneur-probe"}}}"#
        #expect(RexEvents.sessionCreated(line: created)?.0 == "session:s3")
        #expect(RexEvents.sessionCreated(line: created)?.1 == "flaneur-probe")
        #expect(RexEvents.sessionCreated(line: osc9) == nil)
    }

    @Test func noticeDedupeDropsOnlyRepeatsInsideTheWindow() {
        var dedupe = RexEvents.NoticeDedupe()
        let t0 = Date(timeIntervalSince1970: 1000)
        func notice(_ title: String, at seconds: TimeInterval) -> RexNotice {
            RexNotice(
                id: UUID().uuidString, blockID: "block:b1", sessionID: "session:s1", sessionLabel: "",
                title: title, body: "exit 0", date: t0.addingTimeInterval(seconds)
            )
        }
        // A double-emit (OSC 9 then OSC 777 for one alert) lands once.
        let first = dedupe.isDuplicate(notice("Build finished", at: 0))
        let repeated = dedupe.isDuplicate(notice("Build finished", at: 0.4))
        // A different alert from the same block right away is not a repeat.
        let different = dedupe.isDuplicate(notice("Tests failed", at: 0.6))
        // The same text again after the window is a fresh notification.
        let afterWindow = dedupe.isDuplicate(notice("Build finished", at: 4))
        #expect(!first)
        #expect(repeated)
        #expect(!different)
        #expect(!afterWindow)
    }

    @Test func noticeLeadsTheIdleListAndSubmitForgetsIt() {
        let notice = RexNotice(
            id: "n1", blockID: "block:b1", sessionID: "session:s1", sessionLabel: "arid-oasis",
            title: "Build finished", body: "exit 0", date: Date()
        )
        let block = RexBlock(
            blockID: "block:b2", windowID: "window:w1", sessionID: "session:s1",
            label: "editor", windowLabel: "Window One", sessionLabel: "arid-oasis"
        )
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.rex, generation: 1, .blocks(.success(RexListing(sessions: [], blocks: [block])))))
        _ = state.handle(.noticed(notice))
        #expect(state.rows.map(\.title) == ["Build finished", "editor"])
        #expect(state.rows.first?.subtitle == "exit 0")
        #expect(state.rows.first?.badge == "now")
        #expect(state.rows.first?.icon == .application(Rex.bundleID))
        #expect(Item.notice(notice).searchFields.map(\.text).contains("notification"))

        #expect(
            state.handle(.submit) == [
                .dismiss(restoreFocus: false),
                .perform(.rexBlock(blockID: "block:b1", sessionID: "session:s1", windowID: ""), generation: 1),
            ]
        )
        // Read once: the notice is gone, the block it came from stays.
        #expect(state.rows.map(\.title) == ["editor"])
    }

    @Test func commandWDismissesANoticeAndKeepsTheBlock() {
        let notice = RexNotice(
            id: "n1", blockID: "block:b1", sessionID: "session:s1", sessionLabel: "",
            title: "Done", body: "", date: Date()
        )
        let block = RexBlock(
            blockID: "block:b1", windowID: "window:w1", sessionID: "session:s1",
            label: "editor", windowLabel: "", sessionLabel: ""
        )
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.rex, generation: 1, .blocks(.success(RexListing(sessions: [], blocks: [block])))))
        _ = state.handle(.noticed(notice))
        #expect(state.rows.map(\.title) == ["Done", "editor"])
        #expect(state.handle(.close) == [])
        #expect(state.rows.map(\.title) == ["editor"])
    }

    @Test func notificationScopeListsOnlyNotices() {
        let notice = RexNotice(
            id: "n1", blockID: "block:b1", sessionID: "session:s1", sessionLabel: "",
            title: "Build finished", body: "exit 0", date: Date()
        )
        let block = RexBlock(
            blockID: "block:b2", windowID: "window:w1", sessionID: "session:s1",
            label: "editor", windowLabel: "", sessionLabel: ""
        )
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.rex, generation: 1, .blocks(.success(RexListing(sessions: [], blocks: [block])))))
        _ = state.handle(.noticed(notice))
        // Bare letter is the picker: notices only, never the rex blocks they came from.
        _ = state.handle(.query("n"))
        #expect(state.rows.map(\.title) == ["Build finished"])
        // Sticky variant searches within notices.
        _ = state.handle(.query(",n build"))
        #expect(state.rows.map(\.title) == ["Build finished"])
        _ = state.handle(.query(",n nope"))
        #expect(state.rows.isEmpty)
        // Back to global: one letter past the scope is an ordinary search.
        _ = state.handle(.query("no"))
        #expect(state.rows.map(\.title) == ["Build finished"])
    }

    @Test func noticeOpenedFocusesItsBlockWhileHidden() {
        let notice = RexNotice(
            id: "n1", blockID: "block:b1", sessionID: "session:s1", sessionLabel: "",
            title: "Done", body: "", date: Date()
        )
        var state = LauncherState()
        _ = state.handle(.noticed(notice))
        #expect(
            state.handle(.noticeOpened("n1")) == [
                .perform(.rexBlock(blockID: "block:b1", sessionID: "session:s1", windowID: ""), generation: 0)
            ]
        )
        // A second click on the same banner finds nothing to open.
        #expect(state.handle(.noticeOpened("n1")) == [])
    }

    @Test func yabTabsListWithTheAppIconFallback() {
        #expect(Browser.yab.bundleID == "dev.serafim.fast")
        #expect(Browser.yab.displayName == "Yab")
        let tab = BrowserTab(browser: .yab, windowID: "w", tabID: "t", title: "KB", url: "https://dashboard.example")
        #expect(Item.tab(tab).icon == .application(Browser.yab.bundleID))
        #expect(Item.tab(tab).recentKey == "tab:yab:w:t")
        #expect(Item.tab(tab).primary == .browser(.yab, windowID: "w", tabID: "t"))
    }

    @Test func tabSubtitleKeepsThePort() {
        let dev = BrowserTab(browser: .yab, windowID: "w", tabID: "t1", title: "App", url: "http://localhost:5173/dashboard")
        #expect(Item.tab(dev).subtitle == "localhost:5173")
        let plain = BrowserTab(browser: .yab, windowID: "w", tabID: "t2", title: "App", url: "https://example.com/x")
        #expect(Item.tab(plain).subtitle == "example.com")
        let defaultPort = BrowserTab(browser: .yab, windowID: "w", tabID: "t3", title: "App", url: "https://example.com:443/x")
        #expect(Item.tab(defaultPort).subtitle == "example.com")
    }

    @Test func frecencyKeepsTheDailyDriverOnTop() {
        var recents = Recents()
        for _ in 0..<5 { recents.touch(key: "app:/Applications/Work.app", title: "Work") }
        recents.touch(key: "app:/Applications/Once.app", title: "Once")
        var state = LauncherState(recents: recents)
        _ = state.handle(.toggle)
        let work = AppEntry(url: URL(fileURLWithPath: "/Applications/Work.app"), name: "Work", running: true)
        let once = AppEntry(url: URL(fileURLWithPath: "/Applications/Once.app"), name: "Once", running: true)
        _ = state.handle(.collected(.apps, generation: 1, .apps([once, work])))
        #expect(state.rows.map(\.title) == ["Work", "Once"])
    }

    @Test func hotkeyReadsTheTopLevelLineOnly() {
        #expect(Theme.hotkey(in: "hotkey = \"cmd+space\" # mine\n\n[theme.dark]\naccent = \"#112233\"\n") == "cmd+space")
        #expect(Theme.hotkey(in: "[theme.dark]\nhotkey = \"cmd+space\"\n") == nil)
        #expect(Theme.hotkey(in: "# hotkey = \"cmd+space\"\n") == nil)
        #expect(Theme.hotkey(in: "") == nil)
    }

    @Test func hotkeySpecParsesModifiersAndKeys() {
        #expect(HotKey.reading("cmd+space")?.keyCode == UInt32(kVK_Space))
        #expect(HotKey.reading("cmd+space")?.modifiers == UInt32(cmdKey))
        #expect(HotKey.reading("alt+space")?.modifiers == UInt32(optionKey))
        #expect(HotKey.reading("ctrl+shift+p")?.keyCode == UInt32(kVK_ANSI_P))
        #expect(HotKey.reading("ctrl+shift+p")?.modifiers == UInt32(controlKey | shiftKey))
        #expect(HotKey.reading("cmd+alt+1")?.keyCode == UInt32(kVK_ANSI_1))
        #expect(HotKey.reading("space") == nil)
        #expect(HotKey.reading("cmd+wat") == nil)
        #expect(HotKey.reading("") == nil)
    }

    @Test func clipsStayOutOfGlobalSearchAndCopyFromClipboardScope() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let clip = Clip(text: "https://example.com/token", source: "com.brave.Browser")
        _ = state.handle(.collected(.clipboard, generation: 1, .clips([clip])))
        #expect(state.rows.isEmpty)

        // Global content search never mixes copied text into object results.
        _ = state.handle(.query("token"))
        #expect(state.rows.isEmpty)

        // The handoff is consumed: the scope owns the context, the input owns only the query.
        _ = state.handle(.query("c "))
        #expect(state.query == "")
        #expect(state.prompt == "Search clipboard")
        #expect(state.rows.map(\.title) == ["https://example.com/token"])
        _ = state.handle(.query("token"))
        #expect(state.rows.map(\.title) == ["https://example.com/token"])
        // A clip's icon is always the clipboard glyph, never the source app.
        #expect(state.rows.map(\.icon) == [.symbol("doc.on.clipboard")])
        #expect(!state.rows.map(\.badge).isEmpty)

        // Enter copies and hands focus back: the next thing after copying is pasting.
        #expect(state.handle(.submit) == [.copy("https://example.com/token"), .dismiss(restoreFocus: true)])
        #expect(state.phase == .hidden)
    }

    @Test func clipsListByTheirHiddenWordAndMultilineCollapses() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let clip = Clip(text: "first line\n\n  second line  ")
        _ = state.handle(.collected(.clipboard, generation: 1, .clips([clip])))

        // "clip" names every clip inside the clipboard scope, not in global search.
        _ = state.handle(.query("clip"))
        #expect(state.rows.isEmpty)
        _ = state.handle(.query("c "))
        _ = state.handle(.query("clip"))
        #expect(state.rows.map(\.title) == ["first line second line"])
        #expect(state.rows.map(\.icon) == [.symbol("doc.on.clipboard")])

        // Opening a clip never reorders the history: no frecency boost, time ranks.
        _ = state.handle(.submit)
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.clipboard, generation: 2, .clips([
            Clip(text: "fresher copy"),
            Clip(text: "first line\n\n  second line  "),
        ])))
        _ = state.handle(.query("c "))
        _ = state.handle(.query("clip"))
        #expect(state.rows.map(\.title) == ["fresher copy", "first line second line"])

        // The source app is a search word, not an icon.
        var sourced = LauncherState()
        _ = sourced.handle(.toggle)
        _ = sourced.handle(.collected(.clipboard, generation: 1, .clips([
            Clip(text: "channel link", sourceName: "Slack"),
            Clip(text: "release notes", sourceName: "Yab"),
        ])))
        _ = sourced.handle(.query("c "))
        _ = sourced.handle(.query("slack"))
        #expect(sourced.rows.map(\.title) == ["channel link"])
    }

    @Test func clipsDedupeBumpCapAndRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clips.json")

        var clips = Clips()
        clips.capture(text: "alpha", source: nil)
        clips.capture(text: "beta", source: "com.example.Beta")
        #expect(clips.entries.map(\.text) == ["beta", "alpha"])

        // A re-copy bumps to the front and keeps its id, like one register yanked twice.
        let alphaID = clips.entries[1].id
        clips.capture(text: "alpha", source: nil)
        #expect(clips.entries.map(\.text) == ["alpha", "beta"])
        #expect(clips.entries[0].id == alphaID)
        // A new copy of the same text keeps the source it was first attributed to.
        #expect(clips.entries[0].source == nil)

        for index in 0..<150 { clips.capture(text: "filler \(index)", source: nil) }
        #expect(clips.entries.count == Clips.limit)
        #expect(clips.entries.first?.text == "filler 149")

        clips.save(to: url)
        let loaded = Clips.load(from: url)
        #expect(loaded == clips)

        try Data("{not json".utf8).write(to: url)
        #expect(Clips.load(from: url).entries.isEmpty)
    }

    @MainActor
    @Test func monitorSkipsSecretsBlanksAndRepeats() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("flaneur-test-\(UUID().uuidString)"))
        let monitor = ClipboardMonitor(clips: Clips(), persist: { _ in })

        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        monitor.poll(pasteboard)
        #expect(monitor.entries.map(\.text) == ["hello"])

        // The same change count is the same copy.
        monitor.poll(pasteboard)
        #expect(monitor.entries.count == 1)

        // Password managers tag their copies: those are never recorded.
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pasteboard.setString("hunter2", forType: .string)
        monitor.poll(pasteboard)
        #expect(monitor.entries.map(\.text) == ["hello"])

        // Whitespace alone is not a clip.
        pasteboard.clearContents()
        pasteboard.setString("  \n ", forType: .string)
        monitor.poll(pasteboard)
        #expect(monitor.entries.map(\.text) == ["hello"])
    }

    @Test func riftListingDecodesTheRealQueryShape() throws {
        let json = """
        [
          {"display_uuid":"D","id":"VirtualWorkspaceId(2v1)","index":1,"is_active":true,
           "is_focused":true,"layout_mode":"traditional","name":"2","window_count":0,"windows":[]},
          {"display_uuid":"D","id":"VirtualWorkspaceId(3v1)","index":2,"is_active":false,
           "is_focused":false,"layout_mode":"traditional","name":"3","window_count":2,
           "windows":[
             {"app_name":"Slack","bundle_id":"com.tinyspeck.slackmacgap",
              "frame":{"origin":{"x":6.0,"y":40.0},"size":{"height":936.0,"width":1500.0}},
              "id":{"idx":550,"pid":16324},"is_floating":false,"is_focused":false,
              "layout_position":null,"title":"Atul (DM) - Slack","window_server_id":550},
             {"app_name":"Yab","bundle_id":"dev.serafim.fast",
              "frame":{"origin":{"x":6.0,"y":40.0},"size":{"height":468.0,"width":750.0}},
              "id":{"idx":12,"pid":800},"is_floating":false,"is_focused":true,
              "layout_position":null,"title":"yajanarao/flaneur","window_server_id":612}
           ]}
        ]
        """
        let listing = try Rift.listing(from: Data(json.utf8))
        #expect(listing.workspaces.count == 2)
        #expect(listing.workspaces[1].name == "3")
        #expect(listing.workspaces[1].apps == ["Slack", "Yab"])
        #expect(listing.workspaces[1].icon == "com.tinyspeck.slackmacgap")
        #expect(listing.workspaces[0].focused)
        #expect(listing.windows.map(\.id) == [550, 612])
        #expect(listing.windows[1].workspace == 2)
        #expect(listing.windows[1].workspaceName == "3")
        #expect(listing.windows[1].focused)
    }

    private func riftState() -> LauncherState {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let listing = RiftListing(
            workspaces: [
                RiftWorkspace(index: 1, name: "2", focused: true, icon: nil, apps: [], titles: []),
                RiftWorkspace(
                    index: 2, name: "3", focused: false, icon: "com.tinyspeck.slackmacgap",
                    apps: ["Slack"], titles: ["Atul (DM) - Slack"]
                ),
            ],
            windows: [
                RiftWindow(
                    id: 550, app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                    title: "Atul (DM) - Slack", focused: false, workspace: 2, workspaceName: "3"
                ),
                RiftWindow(
                    id: 612, app: "Yab", bundleID: "dev.serafim.fast",
                    title: "yajanarao/flaneur", focused: true, workspace: 2, workspaceName: "3"
                ),
            ]
        )
        _ = state.handle(.collected(.rift, generation: 1, .riftLayout(.success(listing), restartable: true)))
        return state
    }

    @Test func riftRestingSkipsEmptyWorkspacesAndTheCurrentRowIsNotFirst() {
        var state = riftState()
        // The focused workspace is empty: it drops out entirely. The focused window
        // (Yab) is the row you are on, so it never leads — it sits just below.
        #expect(state.rows.map(\.title) == ["3 · Slack", "yajanarao/flaneur", "Atul (DM) - Slack"])
        #expect(state.rows.map(\.subtitle) == ["Atul (DM) - Slack", "Yab · workspace 3", "Slack · workspace 3"])
        #expect(state.rows.map(\.badge) == ["1 window", "current", ""])

        // Typing a workspace number finds even an empty one, for a clean jump.
        _ = state.handle(.query("workspace 2"))
        #expect(state.rows.map(\.title) == ["2"])
        #expect(state.handle(.submit) == [.dismiss(restoreFocus: false), .perform(.riftWorkspace(index: 1), generation: 1)])
    }

    @Test func riftSearchFindsAWorkspaceByItsContents() {
        var state = riftState()
        _ = state.handle(.query("atul"))
        #expect(state.rows.map(\.title) == ["Atul (DM) - Slack", "3 · Slack"])

        state = riftState()
        _ = state.handle(.query("flaneur"))
        #expect(state.rows.map(\.title) == ["yajanarao/flaneur"])
        // Enter focuses the exact window, workspace follows.
        let window = RiftWindow(
            id: 612, app: "Yab", bundleID: "dev.serafim.fast",
            title: "yajanarao/flaneur", focused: true, workspace: 2, workspaceName: "3"
        )
        #expect(state.handle(.submit) == [.dismiss(restoreFocus: false), .perform(.riftWindow(window), generation: 1)])
    }

    @Test func riftMoveAndFullscreenOnlyFireOnWindowRows() {
        var state = riftState()
        // Top row is the workspace: not a window, nothing happens.
        #expect(state.handle(.moveWindow(0)) == [])
        #expect(state.handle(.fullscreen) == [])

        // First move lands on the focused window (Yab), second on the Slack window.
        _ = state.handle(.move(.down))
        #expect(state.handle(.moveWindow(1)) == [
            .perform(.riftMove(windowID: 612, workspace: 1), generation: 1),
            .dismiss(restoreFocus: true),
        ])

        state = riftState()
        _ = state.handle(.move(.down))
        _ = state.handle(.move(.down))
        let window = RiftWindow(
            id: 550, app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
            title: "Atul (DM) - Slack", focused: false, workspace: 2, workspaceName: "3"
        )
        #expect(state.handle(.fullscreen) == [
            .dismiss(restoreFocus: false),
            .perform(.riftFullscreen(window), generation: 1),
        ])
    }

    @Test func riftCloseKeepsThePanelAndDropsTheRow() {
        var state = riftState()
        _ = state.handle(.move(.down))
        #expect(state.handle(.close) == [.perform(.riftClose(windowID: 612), generation: 1)])
        #expect(state.phase == .visible(.holding))
        #expect(state.rows.map(\.title) == ["3 · Slack", "Atul (DM) - Slack"])
    }

    @Test func riftFailureLeavesOtherSources() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let app = AppEntry(url: URL(fileURLWithPath: "/Applications/Alpha.app"), name: "Alpha", running: true)
        _ = state.handle(.collected(.apps, generation: 1, .apps([app])))
        _ = state.handle(.collected(.rift, generation: 1, .riftLayout(.failure(.timedOut), restartable: true)))
        #expect(state.rows.map(\.title) == ["Alpha"])
        #expect(state.failures == ["rift timed out"])

        // The fix is a row away even while the query is down.
        _ = state.handle(.query("restart"))
        #expect(state.rows.map(\.title) == ["Restart Rift"])
        #expect(state.rows.map(\.icon) == [.symbol("arrow.clockwise")])
        #expect(state.handle(.submit) == [
            .perform(.riftRestart, generation: 1),
            .dismiss(restoreFocus: true),
        ])
    }

    @Test func workspaceDigitsAndControlFNeedTheirModifiers() {
        // ⌘2 / ⇧⌥2 both move to workspace index 1, matching the comb1+N binding.
        #expect(Key(event: keyEvent(19, .command)) == .moveWindow(1))
        #expect(Key(event: keyEvent(19, [.option, .shift])) == .moveWindow(1))
        #expect(Key(event: keyEvent(29, .command)) == .moveWindow(9))
        #expect(Key(event: keyEvent(3, .control)) == .fullscreen)
        // A bare digit is typing, and ⌘ with a non-digit is not a move.
        #expect(Key(event: keyEvent(19, [])) == nil)
        #expect(Key(event: keyEvent(17, .command)) == nil)
    }

    @Test func actionsAreTheRowsTruth() {
        // A clip: copy, nothing else.
        let clip = Item.clip(Clip(text: "hello"))
        #expect(clip.actions.map(\.chord) == [.enter])
        #expect(clip.actions.first?.run == .copy("hello"))

        // A rift window: focus, ten moves, fullscreen, close.
        let riftWindow = RiftWindow(
            id: 7, app: "Yab", bundleID: "dev.serafim.fast",
            title: "Page", focused: false, workspace: 1, workspaceName: "2"
        )
        let window = Item.riftWindow(riftWindow)
        #expect(window.actions.map(\.chord) == [.enter] + (0..<10).map { .moveWindow($0) } + [.fullscreen, .close])
        #expect(window.actions.first?.run == .perform(.riftWindow(riftWindow)))

        // A notice is dismissed, not closed; a non-running app cannot be quit.
        let notice = Item.notice(RexNotice(
            id: "n", blockID: "b", sessionID: "s", sessionLabel: "", title: "t", body: "", date: Date()
        ))
        #expect(notice.actions.last?.title == "Dismiss")
        let installed = Item.app(AppEntry(url: URL(fileURLWithPath: "/Applications/X.app"), name: "X", running: false))
        #expect(installed.actions.map(\.chord) == [.enter])
    }

    @Test func quitAndRestartNeedTheirModifiers() {
        #expect(Key(event: keyEvent(12, [.control, .shift])) == .quit)
        #expect(Key(event: keyEvent(15, .command)) == .restart)
        #expect(Key(event: keyEvent(12, .control)) == nil)
        #expect(Key(event: keyEvent(15, [])) == nil)
    }

    @Test func scopePrefixNarrowsToOneSource() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.apps, generation: 1, .apps([
            AppEntry(url: URL(fileURLWithPath: "/Applications/Alpha.app"), name: "Alpha", running: true)
        ])))
        _ = state.handle(.collected(.clipboard, generation: 1, .clips([
            Clip(text: "fresh clip"), Clip(text: "older clip"),
        ])))

        // ,c lists every clip in capture order; apps stay out, resting exclusion bypassed.
        _ = state.handle(.query(",c"))
        #expect(state.rows.map(\.title) == ["fresh clip", "older clip"])

        // Text after the prefix searches within the source.
        _ = state.handle(.query(",c fresh"))
        #expect(state.rows.map(\.title) == ["fresh clip"])

        // An unknown letter is just a query.
        _ = state.handle(.query(",z"))
        #expect(state.rows.isEmpty)
    }

    @Test func bareLetterScopesAndTheNextLetterReturnsToGlobal() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.apps, generation: 1, .apps([
            AppEntry(url: URL(fileURLWithPath: "/Applications/Clippy.app"), name: "Clippy", running: false)
        ])))
        _ = state.handle(.collected(.clipboard, generation: 1, .clips([Clip(text: "hello world")])))

        // One letter is the picker; a one-letter global search finds nothing anyway.
        _ = state.handle(.query("c"))
        #expect(state.rows.map(\.title) == ["hello world"])

        // The next letter is just typing: global filtering resumes without copied text.
        _ = state.handle(.query("cl"))
        #expect(state.rows.map(\.title) == ["Clippy"])

        // Backspace returns to the picker.
        _ = state.handle(.query("c"))
        #expect(state.rows.map(\.title) == ["hello world"])
    }

    @Test func clipboardScopeBackspaceAndEscapeLeaveOnlyTheScope() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.apps, generation: 1, .apps([
            AppEntry(url: URL(fileURLWithPath: "/Applications/Alpha.app"), name: "Alpha", running: true),
        ])))
        _ = state.handle(.collected(.clipboard, generation: 1, .clips([
            Clip(text: "fresh clip"), Clip(text: "older clip"),
        ])))
        _ = state.handle(.query("c "))
        _ = state.handle(.query("fresh"))
        #expect(state.rows.map(\.title) == ["fresh clip"])

        // Clearing keeps the clipboard context and restores its MRU listing.
        _ = state.handle(.clearLine)
        #expect(state.prompt == "Search clipboard")
        #expect(state.rows.map(\.title) == ["fresh clip", "older clip"])
        #expect(state.canPopPickerOnBackspace)
        _ = state.handle(.backspace)
        #expect(state.prompt == "Search")
        #expect(state.rows.map(\.title) == ["Alpha"])

        _ = state.handle(.query("c "))
        #expect(state.prompt == "Search clipboard")
        _ = state.handle(.escape)
        #expect(state.prompt == "Search")
        #expect(state.rows.map(\.title) == ["Alpha"])
        #expect(Key(event: keyEvent(51, [])) == .backspace)
    }

    @Test func browserScopesSplitByBrowser() {
        var state = LauncherState()
        _ = state.handle(.toggle)
        let brave = BrowserTab(browser: .brave, windowID: "bw", tabID: "bt", title: "BraveTab", url: "https://brave.example")
        let yab = BrowserTab(browser: .yab, windowID: "yw", tabID: "yt", title: "YabTab", url: "https://yab.example")
        _ = state.handle(.collected(.browser(.brave), generation: 1, .tabs(.success([brave]))))
        _ = state.handle(.collected(.browser(.yab), generation: 1, .tabs(.success([yab]))))

        _ = state.handle(.query("t"))
        #expect(state.rows.map(\.title) == ["BraveTab", "YabTab"])
        _ = state.handle(.query("b"))
        #expect(state.rows.map(\.title) == ["BraveTab"])
        _ = state.handle(.query("y"))
        #expect(state.rows.map(\.title) == ["YabTab"])
        // Sticky narrowing inside one browser.
        _ = state.handle(.query(",b brave"))
        #expect(state.rows.map(\.title) == ["BraveTab"])
    }

    @Test func workspaceScopeListsEvenEmptyOnes() {
        var state = riftState()
        // Resting hides the empty focused workspace and the service row; w shows all of rift.
        #expect(state.rows.map(\.title) == ["3 · Slack", "yajanarao/flaneur", "Atul (DM) - Slack"])
        _ = state.handle(.query("w"))
        #expect(state.rows.map(\.title) == [
            "2", "3 · Slack", "Atul (DM) - Slack", "yajanarao/flaneur", "Restart Rift",
        ])
        // The sticky variant narrows inside the source.
        _ = state.handle(.query(",w slack"))
        #expect(state.rows.isEmpty == false)
        #expect(state.rows.allSatisfy { $0.title.contains("Slack") || $0.subtitle.contains("Slack") })
    }
}

private func keyEvent(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: flags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: code
    )!
}

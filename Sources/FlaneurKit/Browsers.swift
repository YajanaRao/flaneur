import AppKit
import Foundation

enum Browsers {
    private static let timeout: Duration = .seconds(20)

    static func collect(_ browser: Browser) async throws -> [BrowserTab] {
        guard await isRunning(browser) else { return [] }
        let data = try await Shell.run(
            "/usr/bin/osascript",
            ["-l", "JavaScript", "-e", listScript(browser)],
            timeout: timeout
        )
        do {
            let windows = try JSONDecoder().decode([WindowWire].self, from: data)
            let tabs = windows.flatMap { window in
                window.tabs.map { tab in
                    BrowserTab(
                        browser: browser,
                        windowID: window.id,
                        tabID: tab.id,
                        title: tab.title,
                        url: tab.url
                    )
                }
            }
            return Favicons.applying(tabs, browser: browser)
        } catch {
            throw CollectFailure.malformed(error.localizedDescription)
        }
    }

    static func select(_ browser: Browser, windowID: String, tabID: String) async throws {
        guard await isRunning(browser) else { throw ActivationError.notRunning }
        _ = try await Shell.run(
            "/usr/bin/osascript",
            ["-l", "JavaScript", "-e", selectScript(browser, windowID: windowID, tabID: tabID)],
            timeout: timeout
        )
        try await Apps.activate(bundleID: browser.bundleID)
    }

    /// Closes the tab and leaves the browser where it is. The panel stays in front.
    static func close(_ browser: Browser, windowID: String, tabID: String) async throws {
        guard await isRunning(browser) else { throw ActivationError.notRunning }
        _ = try await Shell.run(
            "/usr/bin/osascript",
            ["-l", "JavaScript", "-e", closeScript(browser, windowID: windowID, tabID: tabID)],
            timeout: timeout
        )
    }

    private static func isRunning(_ browser: Browser) async -> Bool {
        await MainActor.run {
            !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty
        }
    }

    private static func listScript(_ browser: Browser) -> String {
        let bundle = javascriptString(browser.bundleID)
        return """
        function run() {
          const app = Application(\(bundle));
          const windows = app.windows();
          const out = [];
          for (let i = 0; i < windows.length; i++) {
            const w = windows[i];
            if (String(w.mode()) === "incognito") continue;
            const tabs = w.tabs();
            const row = { id: String(w.id()), tabs: [] };
            for (let j = 0; j < tabs.length; j++) {
              const t = tabs[j];
              const title = t.title();
              const url = t.url();
              row.tabs.push({
                id: String(t.id()),
                title: title == null ? "" : String(title),
                url: url == null ? "" : String(url)
              });
            }
            out.push(row);
          }
          return JSON.stringify(out);
        }
        """
    }

    private static func selectScript(_ browser: Browser, windowID: String, tabID: String) -> String {
        let bundle = javascriptString(browser.bundleID)
        let window = javascriptString(windowID)
        let tab = javascriptString(tabID)
        return """
        function run() {
          const app = Application(\(bundle));
          const windows = app.windows();
          const windowID = \(window);
          const tabID = \(tab);
          let target = null;
          for (let i = 0; i < windows.length; i++) {
            if (String(windows[i].id()) === windowID) { target = windows[i]; break; }
          }
          if (!target) throw new Error("missing window");
          const tabs = target.tabs();
          // AppleScript tab indexes are 1-based; this loop's i is not.
          let index = -1;
          for (let i = 0; i < tabs.length; i++) {
            if (String(tabs[i].id()) === tabID) { index = i + 1; break; }
          }
          if (index < 0) throw new Error("missing tab");
          target.activeTabIndex = index;
          target.index = 1;
          return "ok";
        }
        """
    }

    private static func closeScript(_ browser: Browser, windowID: String, tabID: String) -> String {
        let bundle = javascriptString(browser.bundleID)
        let window = javascriptString(windowID)
        let tab = javascriptString(tabID)
        return """
        function run() {
          const app = Application(\(bundle));
          const windows = app.windows();
          const windowID = \(window);
          const tabID = \(tab);
          for (let i = 0; i < windows.length; i++) {
            if (String(windows[i].id()) !== windowID) continue;
            const tabs = windows[i].tabs();
            for (let j = 0; j < tabs.length; j++) {
              if (String(tabs[j].id()) === tabID) { tabs[j].close(); return "ok"; }
            }
          }
          throw new Error("missing tab");
        }
        """
    }

    private static func javascriptString(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    private struct WindowWire: Decodable {
        let id: String
        let tabs: [TabWire]
    }

    private struct TabWire: Decodable {
        let id: String
        let title: String
        let url: String
    }
}

import AppKit
import FlaneurKit
import ServiceManagement
import UserNotifications

extension Notification.Name {
    static let flaneurToggle = Notification.Name("com.yajanarao.flaneur.toggle")
}

if otherFlaneurIsRunning() {
    Log.info("second instance exiting; args=\(CommandLine.arguments.dropFirst().joined(separator: " "))")
    if CommandLine.arguments.contains("--toggle") {
        DistributedNotificationCenter.default().postNotificationName(
            .flaneurToggle,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        // Exiting in the same turn drops the notification before the running app receives it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }
    Log.flush()
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let launcher = Launcher(theme: Theme.load())
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launched; path=\(Bundle.main.executablePath ?? "?") args=\(CommandLine.arguments.dropFirst().joined(separator: " ")) log=\(Log.url.path)")
        watchSignals()
        enableLoginItem()
        startNotices()
        ClipboardMonitor.shared.start()
        Task { await Projects.warm() }
        do {
            let spec = Theme.hotkeySpec() ?? "alt+space"
            hotKey = try HotKey.parsing(spec) { [launcher] in
                Log.info("hotkey pressed")
                launcher.send(.toggle)
            }
            Log.info("hotkey registered: \(spec)")
        } catch {
            Log.error("hotkey \(error); alt+space instead")
            hotKey = try? HotKey.altSpace { [launcher] in
                Log.info("hotkey pressed")
                launcher.send(.toggle)
            }
            Log.info(hotKey == nil ? "alt+space fallback failed; no hotkey is active" : "hotkey registered: alt+space (fallback)")
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .flaneurToggle,
            object: nil,
            queue: .main
        ) { [launcher] _ in
            MainActor.assumeIsolated {
                Log.info("toggle requested by another flaneur process")
                launcher.send(.toggle)
            }
        }
        if CommandLine.arguments.contains("--toggle") {
            launcher.send(.toggle)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Log.info("terminating: \(quitReason())")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("exiting")
        Log.flush()
    }

    func applicationDidResignActive(_ notification: Notification) {
        launcher.send(.resigned)
    }

    /// Why a quit happened: the panel's ⌃Q, a signal, or an Apple event (Quit menu, `osascript`, logout) with its sender.
    private func quitReason() -> String {
        if let reason = Log.pendingQuitReason { return reason }
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return "unknown (no Apple event or signal)" }
        let senderPID = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
        let sender = NSRunningApplication(processIdentifier: senderPID)
        let name = sender?.localizedName ?? sender?.bundleIdentifier ?? "unknown"
        return "Apple event quit from pid \(senderPID) (\(name))"
    }

    private var signalSources: [DispatchSourceSignal] = []

    /// SIGTERM/SIGHUP/SIGINT (`killall flaneur`, scripts/dev.sh, a closing terminal) quit through the same path, with a log line.
    private func watchSignals() {
        for (number, name) in [(SIGTERM, "SIGTERM"), (SIGHUP, "SIGHUP"), (SIGINT, "SIGINT")] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                Log.pendingQuitReason = "received \(name)"
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func startNotices() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.error("notification auth: \(error.localizedDescription)")
            } else if !granted {
                Log.info("notifications denied; rows only")
            }
        }
        Task {
            await RexEvents.notices { [launcher] notice in
                Task { @MainActor in
                    launcher.send(.noticed(notice))
                    Notices.post(notice)
                    Log.info("noticed \"\(notice.title)\"")
                }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = response.notification.request.content.userInfo["notice"] as? String
        else { return }
        await launcher.send(.noticeOpened(id))
    }

    /// Banners show even while the panel is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

private enum Notices {
    static func post(_ notice: RexNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        if !notice.body.isEmpty { content.body = notice.body }
        if !notice.sessionLabel.isEmpty { content.subtitle = notice.sessionLabel }
        content.sound = .default
        content.threadIdentifier = notice.sessionID
        content.userInfo = ["notice": notice.id]
        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.error("notification: \(error.localizedDescription)")
            }
        }
    }
}

private func enableLoginItem() {
    let service = SMAppService.mainApp
    if service.status == .notRegistered || service.status == .notFound {
        do {
            try service.register()
        } catch {
            Log.error("login item: \(error)")
            return
        }
    }
    if service.status == .requiresApproval {
        Log.info("login item needs approval in System Settings")
    }
}

private func otherFlaneurIsRunning() -> Bool {
    let pid = ProcessInfo.processInfo.processIdentifier
    let bundleID = Bundle.main.bundleIdentifier ?? "com.yajanarao.flaneur"
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .contains { $0.processIdentifier != pid }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

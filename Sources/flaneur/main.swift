import AppKit
import FlaneurKit
import ServiceManagement
import UserNotifications

extension Notification.Name {
    static let flaneurToggle = Notification.Name("com.yajanarao.flaneur.toggle")
}

if otherFlaneurIsRunning() {
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
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let launcher = Launcher(theme: Theme.load())
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        enableLoginItem()
        startNotices()
        // The pasteboard only holds the latest copy, so history must be captured
        // while the panel is closed, not collected on show.
        ClipboardMonitor.shared.start()
        Task { await Projects.warm() }
        do {
            hotKey = try HotKey.parsing(Theme.hotkeySpec() ?? "alt+space") { [launcher] in
                launcher.send(.toggle)
            }
        } catch {
            FileHandle.standardError.write(Data("flaneur: hotkey \(error); alt+space instead\n".utf8))
            hotKey = try? HotKey.altSpace { [launcher] in
                launcher.send(.toggle)
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .flaneurToggle,
            object: nil,
            queue: .main
        ) { [launcher] _ in
            MainActor.assumeIsolated {
                launcher.send(.toggle)
            }
        }
        if CommandLine.arguments.contains("--toggle") {
            launcher.send(.toggle)
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        launcher.send(.resigned)
    }

    /// Rex desktop notifications: an unread row in the panel, plus a banner that
    /// focuses the block when clicked. Denied permission only costs the banner.
    private func startNotices() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                FileHandle.standardError.write(Data("flaneur: notification auth: \(error.localizedDescription)\n".utf8))
            } else if !granted {
                FileHandle.standardError.write(Data("flaneur: notifications denied; rows only\n".utf8))
            }
        }
        Task {
            await RexEvents.notices { [launcher] notice in
                Task { @MainActor in
                    launcher.send(.noticed(notice))
                    Notices.post(notice)
                    FileHandle.standardError.write(Data("flaneur: noticed \"\(notice.title)\"\n".utf8))
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
                FileHandle.standardError.write(Data("flaneur: notification: \(error.localizedDescription)\n".utf8))
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
            FileHandle.standardError.write(Data("flaneur: login item: \(error)\n".utf8))
            return
        }
    }
    if service.status == .requiresApproval {
        FileHandle.standardError.write(Data("flaneur: login item needs approval in System Settings\n".utf8))
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

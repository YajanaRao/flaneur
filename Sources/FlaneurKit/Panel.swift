import AppKit
import SwiftUI

enum Key: Sendable, Equatable {
    case up, down, enter, escape, backspace
    /// ⌃O: open the selected row's link in the browser. ⌃Y: yank it to the clipboard.
    case open, yank
    /// ⌘W: close the selected browser or Herdr tab. The panel stays open.
    case close
    /// ⌘1…⌘0 or ⇧⌥1…⇧⌥0: move the selected rift window to that workspace (carries
    /// the 0-based index). ⇧⌥ mirrors the comb1+N binding outside the panel.
    case moveWindow(Int)
    /// ⌃F: focus the selected rift window and toggle true fullscreen.
    case fullscreen
    /// ⌃⇧Q: quit the selected app. ⌘R: restart it.
    case quit, restart
    /// ⌃R: run a workflow for the selected GitHub repository.
    case runWorkflow
    /// ⌃U: clear the search line. Vim insert-mode kill-to-start.
    case clear

    /// Number-row key codes in order: 1 2 3 4 5 6 7 8 9 0 → workspace index 0…9.
    private static let workspaceKeyCodes: [UInt16: Int] = [
        18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8, 29: 9,
    ]

    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        switch event.keyCode {
        case 126: self = .up
        case 125: self = .down
        case 38 where mods == .control: self = .down
        case 40 where mods == .control: self = .up
        case 31 where mods == .control: self = .open
        case 16 where mods == .control: self = .yank
        case 13 where mods == .command: self = .close
        case 3 where mods == .control: self = .fullscreen
        case 12 where mods == [.control, .shift]: self = .quit
        case 15 where mods == .command: self = .restart
        case 15 where mods == .control: self = .runWorkflow
        case 32 where mods == .control: self = .clear
        case 36, 76: self = .enter
        case 53: self = .escape
        case 51 where mods.isEmpty: self = .backspace
        case let code where mods == .command || mods == [.option, .shift]:
            guard let index = Self.workspaceKeyCodes[code] else { return nil }
            self = .moveWindow(index)
        default: return nil
        }
    }
}

final class LauncherPanel: NSPanel {
    static let panelSize = NSSize(width: 750, height: 480)

    private let onKey: (Key) -> Bool

    init(content: some View, onKey: @escaping (Key) -> Bool) {
        self.onKey = onKey
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        let hosting = NSHostingView(rootView: content)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let key = Key(event: event), onKey(key) {
            return
        }
        super.sendEvent(event)
    }

    func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let screen {
            let visible = screen.visibleFrame
            let size = Self.panelSize
            let x = min(max(visible.midX - size.width / 2, visible.minX), visible.maxX - size.width)
            let y = min(max(visible.midY - size.height / 2, visible.minY), visible.maxY - size.height)
            setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func dismiss(restoreFocus: Bool) {
        orderOut(nil)
        if restoreFocus {
            NSApp.hide(nil)
        }
    }
}

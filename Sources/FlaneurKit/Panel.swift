import AppKit
import SwiftUI

enum Key: Sendable, Equatable {
    case up, down, enter, escape, backspace
    case open, yank
    case close
    /// ⌘1…⌘0 or ⇧⌥1…⇧⌥0: move the selected rift window to that workspace (carries
    /// the 0-based index). ⇧⌥ mirrors the comb1+N binding outside the panel.
    case moveWindow(Int)
    case fullscreen
    case quit, restart
    case quitFlaneur
    case runWorkflow
    case clear

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
        case 12 where mods == .control: self = .quitFlaneur
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
    static let shadowInset: CGFloat = 36

    private let onKey: (Key) -> Bool

    init(content: some View, onKey: @escaping (Key) -> Bool) {
        self.onKey = onKey
        let inset = Self.shadowInset
        let windowSize = NSSize(width: Self.panelSize.width + 2 * inset, height: Self.panelSize.height + 2 * inset)
        super.init(
            contentRect: NSRect(origin: .zero, size: windowSize),
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
        hasShadow = false
        animationBehavior = .none
        let container = NSView(frame: NSRect(origin: .zero, size: windowSize))
        let panelFrame = container.bounds.insetBy(dx: inset, dy: inset)
        let shadow = NSView(frame: panelFrame)
        shadow.wantsLayer = true
        shadow.layer?.shadowColor = NSColor.black.cgColor
        shadow.layer?.shadowOpacity = 0.32
        shadow.layer?.shadowRadius = 14
        shadow.layer?.shadowOffset = CGSize(width: 0, height: -6)
        shadow.layer?.shadowPath = CGPath(roundedRect: shadow.bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
        container.addSubview(shadow)
        let hosting = NSHostingView(rootView: content)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: panelFrame)
            glass.cornerRadius = 14
            glass.contentView = hosting
            container.addSubview(glass)
        } else {
            hosting.frame = panelFrame
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
        }
        contentView = container
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
            let inset = Self.shadowInset
            let windowSize = NSSize(width: size.width + 2 * inset, height: size.height + 2 * inset)
            setFrame(NSRect(origin: NSPoint(x: x - inset, y: y - inset), size: windowSize), display: true)
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

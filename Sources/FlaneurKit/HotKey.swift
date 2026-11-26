import Carbon.HIToolbox
import Foundation

@MainActor
public final class HotKey {
    private var hotKey: EventHotKeyRef?
    private let identifier: UInt32

    public static func altSpace(_ handler: @escaping @MainActor () -> Void) throws -> HotKey {
        try HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), handler: handler)
    }

    /// A `hotkey = "cmd+space"` line: modifiers joined with `+`, then the key.
    /// Unknown words fail the whole spec so the app can fall back and complain.
    public static func parsing(_ spec: String, handler: @escaping @MainActor () -> Void) throws -> HotKey {
        guard let read = reading(spec) else { throw Failure.malformed(spec) }
        return try HotKey(keyCode: read.keyCode, modifiers: read.modifiers, handler: handler)
    }

    nonisolated static func reading(_ spec: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let words = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = words.last, !words.isEmpty else { return nil }
        var modifiers: UInt32 = 0
        for word in words.dropLast() {
            switch word {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "alt", "opt", "option": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: return nil
            }
        }
        guard modifiers != 0, let keyCode = keyCodes[key] else { return nil }
        return (keyCode, modifiers)
    }

    nonisolated private static let keyCodes: [String: UInt32] = [
        "space": UInt32(kVK_Space), "tab": UInt32(kVK_Tab), "return": UInt32(kVK_Return),
        "enter": UInt32(kVK_Return), "escape": UInt32(kVK_Escape), "delete": UInt32(kVK_Delete),
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
        "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
        "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
        "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
        "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
        "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
        "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
        "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
        "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9),
    ]

    private init(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) throws {
        installHandlerIfNeeded()
        identifier = HotKeyRegistry.shared.nextIdentifier()
        HotKeyRegistry.shared.set(identifier, handler)
        let hotKeyID = EventHotKeyID(signature: fourChar("flnr"), id: identifier)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            HotKeyRegistry.shared.remove(identifier)
            throw Failure.registration(status)
        }
        hotKey = ref
    }

    deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        HotKeyRegistry.shared.remove(identifier)
    }

    public enum Failure: Error {
        case registration(OSStatus)
        case malformed(String)
    }
}

private func fourChar(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
}

private final class HotKeyRegistry: @unchecked Sendable {
    static let shared = HotKeyRegistry()
    private let lock = NSLock()
    private var next: UInt32 = 1
    private var handlers: [UInt32: @MainActor () -> Void] = [:]

    func nextIdentifier() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let identifier = next
        next += 1
        return identifier
    }

    func set(_ identifier: UInt32, _ handler: @escaping @MainActor () -> Void) {
        lock.lock()
        handlers[identifier] = handler
        lock.unlock()
    }

    func remove(_ identifier: UInt32) {
        lock.lock()
        handlers[identifier] = nil
        lock.unlock()
    }

    func handler(for identifier: UInt32) -> (@MainActor () -> Void)? {
        lock.lock()
        let handler = handlers[identifier]
        lock.unlock()
        return handler
    }
}

private var handlerInstalled = false

private func installHandlerIfNeeded() {
    guard !handlerInstalled else { return }
    var spec = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
    )
    InstallEventHandler(GetApplicationEventTarget(), carbonHotKeyHandler, 1, &spec, nil, nil)
    handlerInstalled = true
}

private let carbonHotKeyHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let identifier = hotKeyID.id
    // Hop to the main queue. assumeIsolated crashes the process if Carbon delivers this off the main thread, and then the hotkey is gone until the next login.
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            HotKeyRegistry.shared.handler(for: identifier)?()
        }
    }
    return noErr
}

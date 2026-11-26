import AppKit

public struct Clip: Hashable, Sendable, Codable {
    public let id: UUID
    public let text: String
    public let source: String?
    public let sourceName: String?
    public let at: Date

    public init(id: UUID = UUID(), text: String, source: String? = nil, sourceName: String? = nil, at: Date = Date()) {
        self.id = id
        self.text = text
        self.source = source
        self.sourceName = sourceName
        self.at = at
    }
}

struct Clips: Equatable, Sendable {
    static let limit = 100

    private(set) var entries: [Clip] = []

    mutating func capture(text: String, source: String?, sourceName: String? = nil, at: Date = Date()) {
        if let existing = entries.firstIndex(where: { $0.text == text }) {
            let clip = Clip(
                id: entries[existing].id, text: text,
                source: source ?? entries[existing].source,
                sourceName: sourceName ?? entries[existing].sourceName, at: at
            )
            entries.remove(at: existing)
            entries.insert(clip, at: 0)
        } else {
            entries.insert(Clip(text: text, source: source, sourceName: sourceName, at: at), at: 0)
        }
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    static func load() -> Clips {
        load(from: fileURL)
    }

    static func load(from url: URL) -> Clips {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return Clips() }
        return Clips(entries: stored.entries.filter { !$0.text.isEmpty })
    }

    func save() {
        save(to: Self.fileURL)
    }

    func save(to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Stored(version: 1, entries: entries)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/flaneur/clips.json")
    }

    private struct Stored: Codable {
        var version: Int
        var entries: [Clip]
    }
}

@MainActor
public final class ClipboardMonitor {
    public static let shared = ClipboardMonitor(clips: .load())

    private static let sensitiveTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("com.apple.is-sensitive"),
    ]

    static let maxTextLength = 32_000

    private var clips: Clips
    private let persist: (Clips) -> Void
    private var lastChangeCount = 0
    private var timer: Timer?

    init(clips: Clips = Clips(), persist: @escaping (Clips) -> Void = { $0.save() }) {
        self.clips = clips
        self.persist = persist
    }

    var entries: [Clip] { clips.entries }

    public func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Common modes: a scroll or a key event in the panel must not pause capture.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func poll(_ pasteboard: NSPasteboard = .general, now: Date = Date()) {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let types = pasteboard.types, Set(types).isDisjoint(with: Self.sensitiveTypes),
              let text = pasteboard.string(forType: .string), text.count <= Self.maxTextLength
        else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // The pasteboard carries no source, so attribute the clip to the frontmost app.
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let sourceName = bundleID.flatMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?
                .deletingPathExtension().lastPathComponent
        }
        clips.capture(text: text, source: bundleID, sourceName: sourceName, at: now)
        persist(clips)
    }
}

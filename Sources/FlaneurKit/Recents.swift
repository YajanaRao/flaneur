import Foundation

/// Tabs and apps opened from the panel, ranked zoxide-style: every open adds 10 to
/// an entry's score, and when the scores total over the budget they all age by 0.9
/// and the faint ones (under 1) fall off. Often-used rows stay on top; one-offs fade.
/// A missing or unreadable file is an empty list: the launcher still opens.
struct Recents: Equatable, Sendable {
    struct Entry: Equatable, Sendable, Codable {
        var key: String
        var title: String
        var score: Double
        /// Last use, seconds since 1970. Breaks score ties in favor of the newer row.
        var at: Double

        init(key: String, title: String, score: Double, at: Double) {
            self.key = key
            self.title = title
            self.score = score
            self.at = at
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            score = try container.decodeIfPresent(Double.self, forKey: .score) ?? 0
            at = try container.decodeIfPresent(Double.self, forKey: .at) ?? 0
        }

        private enum CodingKeys: String, CodingKey { case key, title, score, at }
    }

    private static let budget = 10_000.0

    /// Sorted by score, then by recency: rank 0 is the row to offer first.
    private(set) var entries: [Entry] = []

    /// 0 is the highest scored. A changed Herdr id still matches a row with the same title.
    func rank(key: String, title: String) -> Int? {
        if let index = entries.firstIndex(where: { $0.key == key }) { return index }
        guard !title.isEmpty else { return nil }
        return entries.firstIndex { $0.title == title }
    }

    mutating func touch(key: String, title: String) {
        guard !key.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].score += 10
            entries[index].at = now
            entries[index].title = title
        } else {
            entries.append(Entry(key: key, title: title, score: 10, at: now))
        }
        ageIfNeeded()
        entries.sort { left, right in
            left.score != right.score ? left.score > right.score : left.at > right.at
        }
    }

    /// Past the budget, every score decays by 0.9 and entries under 1 fall off.
    private mutating func ageIfNeeded() {
        guard entries.reduce(0, { $0 + $1.score }) > Self.budget else { return }
        entries = entries.map { entry in
            var entry = entry
            entry.score *= 0.9
            return entry
        }.filter { $0.score >= 1 }
    }

    static func load() -> Recents {
        load(from: fileURL)
    }

    static func load(from url: URL) -> Recents {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return Recents() }
        var recents = Recents()
        for entry in stored.entries where !entry.key.isEmpty {
            recents.entries.append(entry)
        }
        // A version-1 file has no scores: its order was the ranking, so seed scores from it.
        if recents.entries.allSatisfy({ $0.score == 0 }) {
            for (index, _) in recents.entries.enumerated() {
                recents.entries[index].score = Double(recents.entries.count - index)
            }
        }
        recents.entries.sort { left, right in
            left.score != right.score ? left.score > right.score : left.at > right.at
        }
        return recents
    }

    func save() {
        save(to: Self.fileURL)
    }

    func save(to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Stored(version: 2, entries: entries)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/flaneur/recent.json")
    }

    private struct Stored: Codable {
        var version: Int
        var entries: [Entry]
    }
}

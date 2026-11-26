import Foundation

struct Mark: Hashable, Sendable {
    var start: Int
    var length: Int
}

struct Ranking: Sendable {
    var item: Item
    var title: [Mark] = []
    var subtitle: [Mark] = []
    var badge: [Mark] = []
}

enum Match {
    static let limit = 100
    private static let titleBonus = 32

    /// Unseen (nil) sorts after every seen time.
    private static func olderFirst(_ lhs: Int?, _ rhs: Int?) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?): return left < right
        case (_?, nil): return true
        default: return false
        }
    }

    static func rank(_ query: String, _ items: [Item], recent: (Item) -> Int? = { _ in nil }) -> [Ranking] {
        let terms = split(query).map { Prepared($0) }
        if terms.isEmpty {
            return items.prefix(limit).map { Ranking(item: $0) }
        }
        var scored: [(score: Int, recent: Int?, index: Int, ranking: Ranking)] = []
        scored.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            guard let ranking = score(terms, item) else { continue }
            scored.append((ranking.score, recent(item), index, ranking.ranking))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.recent != rhs.recent { return olderFirst(lhs.recent, rhs.recent) }
            if lhs.ranking.item.attention != rhs.ranking.item.attention {
                return lhs.ranking.item.attention < rhs.ranking.item.attention
            }
            return lhs.index < rhs.index
        }
        return scored.prefix(limit).map(\.ranking)
    }

    private struct Scored {
        var score: Int
        var ranking: Ranking
    }

    private static func score(_ terms: [Prepared], _ item: Item) -> Scored? {
        let fields = item.searchFields.map { field in
            (role: field.role, prepared: Prepared(field.text))
        }
        var total = 0
        var title: [Int] = []
        var subtitle: [Int] = []
        var badge: [Int] = []
        for term in terms {
            var best: (score: Int, role: SearchField.Role, positions: [Int])?
            for field in fields {
                guard let found = score(term, field.prepared) else { continue }
                let weight = found.score + (field.role == .title ? titleBonus : 0)
                if best == nil || weight > best!.score {
                    best = (weight, field.role, found.positions)
                }
            }
            guard let best else { return nil }
            total += best.score
            switch best.role {
            case .title: title.append(contentsOf: best.positions)
            case .subtitle: subtitle.append(contentsOf: best.positions)
            case .badge: badge.append(contentsOf: best.positions)
            case .extra: break
            }
        }
        return Scored(
            score: total,
            ranking: Ranking(item: item, title: marks(title), subtitle: marks(subtitle), badge: marks(badge))
        )
    }

    private static func score(_ needle: Prepared, _ field: Prepared) -> (score: Int, positions: [Int])? {
        if needle.folded.isEmpty { return nil }
        if field.folded.isEmpty { return nil }
        var queryIndex = 0
        var total = 0
        var previous = -2
        var first: Int?
        var positions: [Int] = []
        for index in field.folded.indices where field.folded[index] == needle.folded[queryIndex] {
            var weight = 1
            if index == previous + 1 { weight += 5 }
            if field.boundary[index] { weight += 8 }
            total += weight
            if first == nil { first = index }
            previous = index
            positions.append(index)
            queryIndex += 1
            if queryIndex == needle.folded.count {
                let span = index - (first ?? index)
                return (total - span / 4, positions)
            }
        }
        return nil
    }

    private struct Prepared {
        var folded: [Character]
        var boundary: [Bool]

        init(_ text: String) {
            let chars = Array(text)
            folded = chars.map(Match.fold)
            boundary = Array(repeating: false, count: chars.count)
            guard !chars.isEmpty else { return }
            boundary[0] = true
            for index in chars.indices.dropFirst() {
                let previous = chars[index - 1]
                if isSeparator(previous) || isCamelBoundary(previous, chars[index]) {
                    boundary[index] = true
                }
            }
        }
    }

    private static func split(_ query: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var quote: Character?
        for character in query {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    terms.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { terms.append(current) }
        return terms
    }

    private static func marks(_ positions: [Int]) -> [Mark] {
        var marks: [Mark] = []
        for index in positions.sorted() {
            if let last = marks.last, last.start + last.length == index {
                marks[marks.count - 1].length += 1
            } else {
                marks.append(Mark(start: index, length: 1))
            }
        }
        return marks
    }

    private static func fold(_ character: Character) -> Character {
        let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.first ?? character
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == " " || character == "-" || character == "_" || character == "."
            || character == "/" || character == "·" || character == "|" || character == ":"
            || character == "#" || character == "@"
    }

    private static func isCamelBoundary(_ previous: Character, _ current: Character) -> Bool {
        previous.isLowercase && current.isLetter && current.isUppercase
    }
}

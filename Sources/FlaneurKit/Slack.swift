import Foundation
import Security

enum Keychain {
    static func password(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }
}

/// Unread Slack messages through the Web API with a user token.
///
/// `client.counts` names the conversations that actually have unreads, so history is fetched only
/// for those. Slack does not document that method; if it refuses, each conversation is checked
/// with `conversations.info` and, for channels, `conversations.history`. Those are Tier 3, so a
/// refresh is paced and capped by a time budget. Whatever is already known is shown at once, and
/// each conversation updates the list as soon as Slack answers it.
enum Slack {
    static let bundleID = "com.tinyspeck.slackmacgap"
    static let keychainService = "flaneur-slack"
    static let directoryFreshFor: Duration = .seconds(600)
    static let budget: Duration = .seconds(20)
    static let perConversation = 5
    static let concurrency = 4

    static func collect(onUpdate: @escaping @Sendable ([SlackMessage]) -> Void = { _ in }) async throws -> [SlackMessage] {
        try await Cache.shared.messages(onUpdate: onUpdate)
    }

    static func contacts() async throws -> [SlackContact] {
        try await Cache.shared.contacts()
    }

    static func groups() async throws -> [SlackGroup] {
        try await Cache.shared.groups()
    }

    static func open(team: String, channel: String, ts: String) async throws {
        var components = URLComponents()
        components.scheme = "slack"
        components.host = "channel"
        components.queryItems = [
            URLQueryItem(name: "team", value: team),
            URLQueryItem(name: "id", value: channel),
            URLQueryItem(name: "message", value: ts),
        ]
        guard let url = components.url else { throw ActivationError.refused }
        try await Links.open(url)
    }

    static func open(team: String, user: String) async throws {
        var components = URLComponents()
        components.scheme = "slack"
        components.host = "user"
        components.queryItems = [
            URLQueryItem(name: "team", value: team),
            URLQueryItem(name: "id", value: user),
        ]
        guard let url = components.url else { throw ActivationError.refused }
        try await Links.open(url)
    }

    static func open(team: String, channel: String) async throws {
        var components = URLComponents()
        components.scheme = "slack"
        components.host = "channel"
        components.queryItems = [
            URLQueryItem(name: "team", value: team),
            URLQueryItem(name: "id", value: channel),
        ]
        guard let url = components.url else { throw ActivationError.refused }
        try await Links.open(url)
    }

    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    /// Slack mrkdwn → one plain line, plus the first http(s) URL it mentions.
    /// `<@U1>` → @name, `<#C1|eng>` → #eng, `<!here>` → @here, `<https://x|label>` → label.
    static func render(_ raw: String, names: [String: String]) -> (text: String, link: URL?) {
        var out = ""
        var link: URL?
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            guard character == "<", let close = raw[index...].firstIndex(of: ">") else {
                out.append(character)
                index = raw.index(after: index)
                continue
            }
            let body = raw[raw.index(after: index)..<close]
            let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = parts.first.map(String.init) ?? ""
            let label = parts.count > 1 ? String(parts[1]) : nil
            if target.hasPrefix("@") {
                let id = String(target.dropFirst())
                out += "@" + (names[id] ?? label ?? id)
            } else if target.hasPrefix("#") {
                out += "#" + (label ?? String(target.dropFirst()))
            } else if target.hasPrefix("!") {
                out += label ?? "@" + String(target.dropFirst())
            } else {
                out += label.flatMap { $0.isEmpty ? nil : $0 } ?? target
                if link == nil, let url = URL(string: target), let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https"
                {
                    link = url
                }
            }
            index = raw.index(after: close)
        }
        let unescaped = out
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        let text = unescaped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (text, link)
    }

    static func permalink(base: URL, channel: String, ts: String) -> URL {
        base.appendingPathComponent("archives/\(channel)/p\(ts.replacingOccurrences(of: ".", with: ""))")
    }

    /// Group DMs are named `mpdm-alice--bob--carol-1` on the wire.
    static func groupName(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("mpdm-") { name.removeFirst(5) }
        if let dash = name.lastIndex(of: "-"), name[name.index(after: dash)...].allSatisfy(\.isNumber) {
            name = String(name[..<dash])
        }
        return name.components(separatedBy: "--").filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func people(list json: Data, team: String, selfID: String) throws -> [SlackContact] {
        let wire: DirectoryWire
        do {
            wire = try JSONDecoder().decode(DirectoryWire.self, from: json)
        } catch {
            throw CollectFailure.malformed(error.localizedDescription)
        }
        return people(wire.members, team: team, selfID: selfID)
    }

    static func groups(list json: Data, team: String) throws -> [SlackGroup] {
        let wire: ConversationsWire
        do {
            wire = try JSONDecoder().decode(ConversationsWire.self, from: json)
        } catch {
            throw CollectFailure.malformed(error.localizedDescription)
        }
        return groups(wire.channels, team: team)
    }

    private static func groups(_ conversations: [ConversationWire], team: String) -> [SlackGroup] {
        conversations.compactMap { conversation in
            guard conversation.is_im != true else { return nil }
            if conversation.is_mpim == true {
                return SlackGroup(
                    team: team,
                    channel: conversation.id,
                    name: groupName(conversation.name ?? "group"),
                    kind: "group DM"
                )
            }
            let name = conversation.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }
            return SlackGroup(
                team: team,
                channel: conversation.id,
                name: "#\(name)",
                kind: conversation.is_private == true ? "private channel" : "channel"
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func people(_ members: [DirectoryMember], team: String, selfID: String) -> [SlackContact] {
        members.compactMap { member in
            if member.id == selfID || member.id == "USLACKBOT" { return nil }
            if member.deleted == true || member.is_bot == true { return nil }
            let handle = member.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let real = member.real_name?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? member.profile?.real_name?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            let display = member.profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = !display.isEmpty ? display : (!real.isEmpty ? real : handle)
            guard !name.isEmpty else { return nil }
            let title = member.profile?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return SlackContact(
                team: team,
                user: member.id,
                name: name,
                handle: handle,
                title: title,
                realName: real,
                image: picture(member.profile?.image_72)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private actor Cache {
        static let shared = Cache()

        private var cached: [SlackMessage] = []
        private var hold: ContinuousClock.Instant?
        private var refresh: Task<([SlackMessage], Bool), Error>?
        private var names: [String: String] = [:]
        private var images: [String: String] = [:]
        private var directory: [SlackContact] = []
        private var directoryFetched: ContinuousClock.Instant?
        private var groups: [SlackGroup] = []
        private var groupsFetched: ContinuousClock.Instant?

        func messages(onUpdate: @escaping @Sendable ([SlackMessage]) -> Void) async throws -> [SlackMessage] {
            guard let token = Keychain.password(service: Slack.keychainService) else {
                cached = []
                return []
            }
            if let hold, ContinuousClock.now < hold { return cached }
            if !cached.isEmpty { onUpdate(cached) }
            if let refresh { return try await refresh.value.0 }
            let task = Task { [onUpdate] in try await fetch(token, onUpdate: onUpdate) }
            refresh = task
            defer { refresh = nil }
            do {
                let (messages, complete) = try await task.value
                cached = messages
                hold = complete ? nil : .now + .seconds(5)
                return messages
            } catch CollectFailure.timedOut where !cached.isEmpty {
                return cached
            } catch CollectFailure.denied {
                cached = []
                throw CollectFailure.denied
            }
        }

        func contacts() async throws -> [SlackContact] {
            guard let token = Keychain.password(service: Slack.keychainService) else {
                directory = []
                directoryFetched = nil
                return []
            }
            if let directoryFetched, directoryFetched.duration(to: .now) < Slack.directoryFreshFor {
                return directory
            }
            let client = Client(token: token, deadline: .now + Slack.budget)
            let auth = try await client.get("auth.test", [:], as: AuthWire.self)
            var members: [DirectoryMember] = []
            var cursor: String?
            for _ in 0..<20 {
                var query = ["limit": "200"]
                if let cursor { query["cursor"] = cursor }
                let page = try await client.get("users.list", query, as: DirectoryWire.self)
                members += page.members
                cursor = page.response_metadata?.next_cursor
                if cursor?.isEmpty != false { break }
            }
            let people = Slack.people(members, team: auth.team_id, selfID: auth.user_id)
            directory = people
            directoryFetched = .now
            return people
        }

        func groups() async throws -> [SlackGroup] {
            guard let token = Keychain.password(service: Slack.keychainService) else {
                groups = []
                groupsFetched = nil
                return []
            }
            if let groupsFetched, groupsFetched.duration(to: .now) < Slack.directoryFreshFor {
                return groups
            }
            let client = Client(token: token, deadline: .now + Slack.budget)
            let auth = try await client.get("auth.test", [:], as: AuthWire.self)
            let conversations = try await Slack.conversations(client)
            let found = Slack.groups(conversations, team: auth.team_id)
            groups = found
            groupsFetched = .now
            return found
        }

        private func fetch(
            _ token: String,
            onUpdate: @escaping @Sendable ([SlackMessage]) -> Void
        ) async throws -> ([SlackMessage], Bool) {
            let client = Client(token: token, deadline: .now + Slack.budget)
            let auth = try await client.get("auth.test", [:], as: AuthWire.self)
            guard let base = URL(string: auth.url) else { throw CollectFailure.malformed("auth.test url") }
            let conversations = try await Slack.conversations(client)
            if let counts = await Slack.counts(client) {
                let byID = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
                let targets = Slack.unreadTargets(counts).filter { byID[$0.id] != nil }
                let ids = Set(targets.map(\.id))
                let starting = cached.filter { ids.contains($0.channel) }
                if Slack.signature(starting) != Slack.signature(cached) {
                    onUpdate(starting)
                }
                var direct: [String: String] = [:]
                for target in targets {
                    if let lastRead = target.lastRead, !lastRead.isEmpty {
                        direct[target.id] = lastRead
                    }
                }
                let rows = targets.map { byID[$0.id]! }
                return try await drain(
                    rows, directHistory: direct, shown: starting, client: client, auth: auth, base: base, onUpdate: onUpdate
                )
            }
            return try await drain(
                conversations, directHistory: [:], shown: cached, client: client, auth: auth, base: base, onUpdate: onUpdate
            )
        }

        private func drain(
            _ conversations: [ConversationWire],
            directHistory: [String: String],
            shown starting: [SlackMessage],
            client: Client,
            auth: AuthWire,
            base: URL,
            onUpdate: @escaping @Sendable ([SlackMessage]) -> Void
        ) async throws -> ([SlackMessage], Bool) {
            var shown = starting
            var published = Slack.signature(shown)
            var complete = true
            var scanned = 0
            while scanned < conversations.count {
                let end = min(scanned + Slack.concurrency, conversations.count)
                let slice = Array(conversations[scanned..<end])
                let batch = try await mapLimited(slice, limit: Slack.concurrency) { conversation in
                    if let oldest = directHistory[conversation.id] {
                        return try await Slack.history(
                            channel: conversation.id, oldest: oldest, client: client, selfID: auth.user_id
                        )
                    }
                    return try await Slack.unread(in: conversation, client: client, selfID: auth.user_id)
                }
                let skipped = batch.allSatisfy { if case .skipped = $0 { return true }; return false }
                if batch.contains(where: { if case .skipped = $0 { return true }; return false }) {
                    complete = false
                }
                try await rememberNames(in: zip(slice, batch), client: client)
                shown = incorporating(shown, conversations: slice, unread: batch, auth: auth, base: base)
                let signature = Slack.signature(shown)
                if signature != published {
                    published = signature
                    onUpdate(shown)
                }
                scanned = end
                if skipped { break }
            }
            return (shown, complete && scanned == conversations.count)
        }

        private func rememberNames(
            in pairs: Zip2Sequence<[ConversationWire], [Unread]>,
            client: Client
        ) async throws {
            var wanted = Set<String>()
            for (conversation, read) in pairs {
                guard case .messages(let messages) = read, !messages.isEmpty else { continue }
                if conversation.is_im == true, let user = conversation.user { wanted.insert(user) }
                for message in messages {
                    if let user = message.user { wanted.insert(user) }
                    wanted.formUnion(Slack.mentions(in: message.text ?? ""))
                }
            }
            let missing = Array(wanted.subtracting(names.keys).prefix(30))
            guard !missing.isEmpty else { return }
            let resolved = try await mapLimited(missing, limit: Slack.concurrency) { id in
                (id, try? await Slack.identity(of: id, client: client))
            }
            for (id, identity) in resolved {
                guard let identity else { continue }
                names[id] = identity.name
                if let image = identity.image { images[id] = image }
            }
        }

        private func incorporating(
            _ base: [SlackMessage],
            conversations: [ConversationWire],
            unread: [Unread],
            auth: AuthWire,
            base url: URL
        ) -> [SlackMessage] {
            var kept = base
            for (conversation, read) in zip(conversations, unread) {
                guard case .messages(let messages) = read else { continue }
                kept.removeAll { $0.channel == conversation.id }
                let place = Slack.place(conversation, names: names)
                for wire in messages {
                    let (text, link) = Slack.render(wire.text ?? "", names: names)
                    let author = wire.user.flatMap { names[$0] }
                        ?? wire.username
                        ?? (wire.bot_id != nil ? "bot" : wire.user ?? "unknown")
                    let who = conversation.user ?? wire.user
                    let image = conversation.is_im == true ? who.flatMap { images[$0] } : nil
                    kept.append(
                        SlackMessage(
                            team: auth.team_id,
                            channel: conversation.id,
                            ts: wire.ts,
                            place: place,
                            author: author,
                            text: text.isEmpty ? "sent an attachment" : text,
                            link: link,
                            permalink: Slack.permalink(base: url, channel: conversation.id, ts: wire.ts),
                            date: Date(timeIntervalSince1970: Double(wire.ts) ?? 0),
                            image: image
                        )
                    )
                }
            }
            kept.sort { $0.date > $1.date }
            return kept
        }
    }

    private static func signature(_ messages: [SlackMessage]) -> [String] {
        messages.map { "\($0.channel):\($0.ts)" }
    }

    private static func conversations(_ client: Client) async throws -> [ConversationWire] {
        var all: [ConversationWire] = []
        var cursor: String?
        for _ in 0..<5 {
            var query = [
                "types": "public_channel,private_channel,mpim,im",
                "exclude_archived": "true",
                "exclude_muted": "true",
                "limit": "999",
            ]
            if let cursor { query["cursor"] = cursor }
            let page = try await client.get("users.conversations", query, as: ConversationsWire.self)
            all += page.channels
            cursor = page.response_metadata?.next_cursor
            if cursor?.isEmpty != false { break }
        }
        return all.sorted { Slack.scanRank($0) < Slack.scanRank($1) }
    }

    /// `nil` means Slack did not answer. The caller falls back to checking every conversation.
    /// Token-level failures are refusal here, not fatal: xoxp tokens get not_allowed_token_type
    /// on this undocumented method. A genuinely revoked token still surfaces as .denied from
    /// the fallback's first conversations.info.
    private static func counts(_ client: Client) async -> CountsWire? {
        do {
            let wire = try await client.post("client.counts", ["thread_counts_by_channel": "true"], as: CountsWire.self)
            guard wire.channels != nil, wire.ims != nil, wire.mpims != nil else { return nil }
            return wire
        } catch {
            return nil
        }
    }

    private static func scanRank(_ conversation: ConversationWire) -> Int {
        if conversation.is_im == true { return 1 }
        if conversation.is_mpim == true { return 2 }
        return 0
    }

    private enum Unread: Sendable {
        case messages([MessageWire])
        case skipped
    }

    private static func unread(in conversation: ConversationWire, client: Client, selfID: String) async throws -> Unread {
        let info: InfoWire
        do {
            info = try await client.get("conversations.info", ["channel": conversation.id], as: InfoWire.self)
        } catch let failure as CollectFailure {
            if failure == .denied { throw failure }
            if failure == .timedOut || failure == .unavailable { return .skipped }
            return .messages([])
        }
        guard shouldFetchHistory(
            lastRead: info.channel.last_read,
            latest: info.channel.latest?.ts,
            unreadDisplay: info.channel.unread_count_display,
            probeWithoutLatest: conversation.is_im != true && conversation.is_mpim != true
        ) else { return .messages([]) }
        return try await history(
            channel: conversation.id, oldest: info.channel.last_read ?? "", client: client, selfID: selfID
        )
    }

    private static func history(channel: String, oldest: String, client: Client, selfID: String) async throws -> Unread {
        let history: HistoryWire
        do {
            history = try await client.get(
                "conversations.history",
                ["channel": channel, "oldest": oldest, "limit": "\(perConversation * 2)"],
                as: HistoryWire.self
            )
        } catch let failure as CollectFailure {
            if failure == .denied { throw failure }
            if failure == .timedOut || failure == .unavailable { return .skipped }
            return .messages([])
        }
        return .messages(
            Array(
                history.messages
                    .filter { $0.user != selfID && isConversational($0) }
                    .prefix(perConversation)
            )
        )
    }

    private struct Identity {
        var name: String
        var image: String?
    }

    private static func identity(of user: String, client: Client) async throws -> Identity {
        let wire = try await client.get("users.info", ["user": user], as: UserWire.self)
        let candidates = [wire.user.profile?.display_name, wire.user.profile?.real_name, wire.user.real_name, wire.user.name]
        let name = candidates.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? user
        return Identity(name: name, image: picture(wire.user.profile?.image_72))
    }

    static func picture(_ raw: String?) -> String? {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return text
    }

    private static func place(_ conversation: ConversationWire, names: [String: String]) -> String {
        if conversation.is_im == true { return "DM" }
        if conversation.is_mpim == true { return groupName(conversation.name ?? "group") }
        return "#" + (conversation.name ?? conversation.id)
    }

    private static func mentions(in text: String) -> Set<String> {
        var ids = Set<String>()
        var rest = text[...]
        while let open = rest.range(of: "<@") {
            rest = rest[open.upperBound...]
            let id = rest.prefix { $0.isLetter || $0.isNumber }
            if !id.isEmpty { ids.insert(String(id)) }
        }
        return ids
    }

    private static func isConversational(_ message: MessageWire) -> Bool {
        guard let subtype = message.subtype else { return true }
        return ["bot_message", "file_share", "thread_broadcast", "me_message"].contains(subtype)
    }

    /// History is the expensive call. DMs carry `latest` and `unread_count_display`, so a missing
    /// timestamp there is a quiet conversation. Channels omit both; `probeWithoutLatest` spends one
    /// history call, and an empty page means the read cursor is already caught up.
    static func shouldFetchHistory(
        lastRead: String?,
        latest: String?,
        unreadDisplay: Int?,
        probeWithoutLatest: Bool = false
    ) -> Bool {
        guard let lastRead, !lastRead.isEmpty else { return false }
        if unreadDisplay == 0 { return false }
        if let latest { return later(latest, than: lastRead) }
        if let unreadDisplay, unreadDisplay > 0 { return true }
        return probeWithoutLatest
    }

    static func unreadTargets(counts json: Data) -> [UnreadTarget]? {
        guard let wire = try? JSONDecoder().decode(CountsWire.self, from: json),
              wire.channels != nil, wire.ims != nil, wire.mpims != nil
        else { return nil }
        return unreadTargets(wire)
    }

    private static func unreadTargets(_ counts: CountsWire) -> [UnreadTarget] {
        let tagged = (counts.channels ?? []).map { ($0, UnreadTarget.Kind.channel) }
            + (counts.ims ?? []).map { ($0, UnreadTarget.Kind.im) }
            + (counts.mpims ?? []).map { ($0, UnreadTarget.Kind.mpim) }
        return tagged.compactMap { count, kind -> UnreadTarget? in
            guard needsHistory(count) else { return nil }
            let lastRead = count.historyInvalid == true ? nil : count.lastRead
            return UnreadTarget(
                id: count.id,
                lastRead: lastRead.flatMap { $0.isEmpty ? nil : $0 },
                latest: count.latest ?? "",
                kind: kind
            )
        }
        .sorted { later($0.latest, than: $1.latest) }
    }

    /// A read flag of false is caught up. Equal timestamps are caught up too, even when the flag is stale.
    /// `history_invalid` still needs the info probe.
    private static func needsHistory(_ count: CountWire) -> Bool {
        if count.historyInvalid == true { return true }
        if count.hasUnreads == false { return false }
        if let lastRead = count.lastRead, let latest = count.latest, !lastRead.isEmpty, !latest.isEmpty {
            return later(latest, than: lastRead)
        }
        return count.hasUnreads == true
    }

    private static func later(_ lhs: String, than rhs: String) -> Bool {
        (Double(lhs) ?? 0) > (Double(rhs) ?? 0)
    }

    /// Token-level failures are `.denied` and abort the refresh. A missing scope is per method, so a
    /// private channel without `groups:history` must only drop that channel, not the DMs beside it.
    private static func failure(_ code: String) -> CollectFailure {
        switch code {
        case "invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive",
            "not_allowed_token_type":
            return .denied
        default:
            return .malformed(code)
        }
    }

    private struct Client: @unchecked Sendable {
        let token: String
        let deadline: ContinuousClock.Instant
        private let session = URLSession(configuration: .ephemeral)

        init(token: String, deadline: ContinuousClock.Instant) {
            self.token = token
            self.deadline = deadline
        }

        func get<Wire: Decodable>(_ method: String, _ query: [String: String], as type: Wire.Type) async throws -> Wire {
            try await call(method, query: query, httpMethod: "GET", body: nil, as: type)
        }

        func post<Wire: Decodable>(_ method: String, _ form: [String: String], as type: Wire.Type) async throws -> Wire {
            var components = URLComponents()
            components.queryItems = form.keys.sorted().map { URLQueryItem(name: $0, value: form[$0]) }
            let body = Data((components.percentEncodedQuery ?? "").utf8)
            return try await call(
                method, query: [:], httpMethod: "POST", body: body, as: type
            )
        }

        private func call<Wire: Decodable>(
            _ method: String,
            query: [String: String],
            httpMethod: String,
            body: Data?,
            as _: Wire.Type
        ) async throws -> Wire {
            var retried = false
            while true {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { throw CollectFailure.timedOut }
                guard var components = URLComponents(string: "https://slack.com/api/\(method)") else {
                    throw CollectFailure.malformed(method)
                }
                if !query.isEmpty {
                    components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
                }
                guard let url = components.url else { throw CollectFailure.malformed(method) }
                var request = URLRequest(url: url)
                request.httpMethod = httpMethod
                request.httpBody = body
                if body != nil {
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                }
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = max(1, seconds(remaining))
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: request)
                } catch let error as URLError where error.code == .timedOut {
                    throw CollectFailure.timedOut
                } catch {
                    throw CollectFailure.unavailable
                }
                if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                    let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
                    let wait = Duration.seconds(retryAfter)
                    guard !retried, wait < remaining else { throw CollectFailure.timedOut }
                    retried = true
                    try await Task.sleep(for: wait)
                    continue
                }
                let envelope: Envelope
                do {
                    envelope = try JSONDecoder().decode(Envelope.self, from: data)
                } catch {
                    throw CollectFailure.malformed("\(method): \(error.localizedDescription)")
                }
                guard envelope.ok else { throw Slack.failure(envelope.error ?? "unknown") }
                do {
                    return try JSONDecoder().decode(Wire.self, from: data)
                } catch {
                    throw CollectFailure.malformed("\(method): \(error.localizedDescription)")
                }
            }
        }

        private func seconds(_ duration: Duration) -> TimeInterval {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
    }

    private struct Envelope: Decodable {
        let ok: Bool
        let error: String?
    }

    private struct AuthWire: Decodable {
        let url: String
        let team_id: String
        let user_id: String
    }

    private struct ConversationsWire: Decodable {
        let channels: [ConversationWire]
        let response_metadata: Metadata?
    }

    private struct Metadata: Decodable {
        let next_cursor: String?
    }

    private struct ConversationWire: Decodable, Sendable {
        let id: String
        let name: String?
        let is_im: Bool?
        let is_mpim: Bool?
        let is_private: Bool?
        let user: String?
    }

    private struct InfoWire: Decodable {
        let channel: InfoChannel
    }

    private struct InfoChannel: Decodable {
        let last_read: String?
        let unread_count_display: Int?
        let latest: Latest?
    }

    private struct Latest: Decodable {
        let ts: String?
    }

    private struct HistoryWire: Decodable {
        let messages: [MessageWire]
    }

    private struct MessageWire: Decodable, Sendable {
        let ts: String
        let user: String?
        let text: String?
        let subtype: String?
        let username: String?
        let bot_id: String?
    }

    private struct UserWire: Decodable {
        let user: UserInfo
    }

    private struct UserInfo: Decodable {
        let name: String?
        let real_name: String?
        let profile: Profile?
    }

    private struct Profile: Decodable {
        let display_name: String?
        let real_name: String?
        let title: String?
        let image_72: String?
    }

    private struct DirectoryMember: Decodable, Sendable {
        let id: String
        let name: String?
        let deleted: Bool?
        let is_bot: Bool?
        let real_name: String?
        let profile: Profile?
    }

    private struct DirectoryWire: Decodable {
        let members: [DirectoryMember]
        let response_metadata: Metadata?
    }

    private struct CountsWire: Decodable {
        let channels: [CountWire]?
        let ims: [CountWire]?
        let mpims: [CountWire]?
    }

    private struct CountWire: Decodable {
        let id: String
        let lastRead: String?
        let latest: String?
        let hasUnreads: Bool?
        let historyInvalid: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case lastRead = "last_read"
            case latest
            case hasUnreads = "has_unreads"
            case historyInvalid = "history_invalid"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            lastRead = try container.decodeIfPresent(String.self, forKey: .lastRead)
            hasUnreads = try container.decodeIfPresent(Bool.self, forKey: .hasUnreads)
            historyInvalid = try container.decodeIfPresent(Bool.self, forKey: .historyInvalid)
            if let stamp = try? container.decode(String.self, forKey: .latest) {
                latest = stamp
            } else if let object = try? container.decode(Latest.self, forKey: .latest) {
                latest = object.ts
            } else {
                latest = nil
            }
        }
    }
}

struct UnreadTarget: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case channel, im, mpim
    }

    let id: String
    let lastRead: String?
    let latest: String
    let kind: Kind
}

private func mapLimited<T: Sendable, R: Sendable>(
    _ items: [T],
    limit: Int,
    _ transform: @escaping @Sendable (T) async throws -> R
) async throws -> [R] {
    try await withThrowingTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        while next < min(limit, items.count) {
            let index = next
            group.addTask { (index, try await transform(items[index])) }
            next += 1
        }
        while let (index, value) = try await group.next() {
            results[index] = value
            if next < items.count {
                let pending = next
                group.addTask { (pending, try await transform(items[pending])) }
                next += 1
            }
        }
        return results.compactMap { $0 }
    }
}

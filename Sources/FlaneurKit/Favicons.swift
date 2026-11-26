import Foundation
import SQLite3

enum Favicons {
    static func lookupKeys(_ urlString: String) -> [String] {
        guard var parts = URLComponents(string: urlString),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return [] }
        parts.scheme = scheme
        parts.host = host
        var keys: [String] = []
        func add(_ key: String?) {
            guard let key, !key.isEmpty, !keys.contains(key) else { return }
            keys.append(key)
        }
        add(parts.string)
        parts.fragment = nil
        parts.query = nil
        add(parts.string)
        add("\(scheme)://\(host)/")
        add("\(scheme)://\(host)")
        return keys
    }

    static func applying(_ tabs: [BrowserTab], browser: Browser) -> [BrowserTab] {
        guard let path = databasePath(browser),
              FileManager.default.isReadableFile(atPath: path) else { return tabs }
        guard let database = open(path) else { return tabs }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = """
        SELECT b.image_data, b.width
        FROM icon_mapping AS m
        JOIN favicon_bitmaps AS b ON b.icon_id = m.icon_id
        WHERE m.page_url = ?1
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return tabs
        }
        defer { sqlite3_finalize(statement) }
        var found: [String: Data] = [:]
        var missing = Set<String>()
        return tabs.map { tab in
            guard let favicon = image(forPage: tab.url, statement: statement, found: &found, missing: &missing) else {
                return tab
            }
            return BrowserTab(
                browser: tab.browser, windowID: tab.windowID, tabID: tab.tabID, title: tab.title, url: tab.url,
                favicon: favicon
            )
        }
    }

    static func image(forPage urlString: String, database path: String) -> Data? {
        guard let database = open(path) else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = """
        SELECT b.image_data, b.width
        FROM icon_mapping AS m
        JOIN favicon_bitmaps AS b ON b.icon_id = m.icon_id
        WHERE m.page_url = ?1
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var found: [String: Data] = [:]
        var missing = Set<String>()
        return image(forPage: urlString, statement: statement, found: &found, missing: &missing)
    }

    static func makeTestDatabase(at path: String, pages: [String: Data]) throws {
        var database: OpaquePointer?
        if sqlite3_open(path, &database) != SQLITE_OK {
            sqlite3_close(database)
            throw CollectFailure.malformed("favicon database")
        }
        defer { sqlite3_close(database) }
        guard let database else { throw CollectFailure.malformed("favicon database") }
        let schema = """
        CREATE TABLE icon_mapping (page_url TEXT, icon_id INTEGER);
        CREATE TABLE favicon_bitmaps (icon_id INTEGER, image_data BLOB, width INTEGER);
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw CollectFailure.malformed("favicon database")
        }
        var insert: OpaquePointer?
        let sql = "INSERT INTO icon_mapping (page_url, icon_id) VALUES (?1, ?2)"
        guard sqlite3_prepare_v2(database, sql, -1, &insert, nil) == SQLITE_OK, let insert else {
            throw CollectFailure.malformed("favicon database")
        }
        defer { sqlite3_finalize(insert) }
        var bitmap: OpaquePointer?
        let blob = "INSERT INTO favicon_bitmaps (icon_id, image_data, width) VALUES (?1, ?2, 32)"
        guard sqlite3_prepare_v2(database, blob, -1, &bitmap, nil) == SQLITE_OK, let bitmap else {
            throw CollectFailure.malformed("favicon database")
        }
        defer { sqlite3_finalize(bitmap) }
        for (index, pair) in pages.enumerated() {
            let id = Int32(index + 1)
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            sqlite3_bind_text(insert, 1, pair.key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(insert, 2, id)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw CollectFailure.malformed("favicon database") }
            sqlite3_reset(bitmap)
            sqlite3_clear_bindings(bitmap)
            sqlite3_bind_int(bitmap, 1, id)
            _ = pair.value.withUnsafeBytes { raw in
                sqlite3_bind_blob(bitmap, 2, raw.baseAddress, Int32(pair.value.count), SQLITE_TRANSIENT)
            }
            guard sqlite3_step(bitmap) == SQLITE_DONE else { throw CollectFailure.malformed("favicon database") }
        }
    }

    private static func image(
        forPage urlString: String,
        statement: OpaquePointer,
        found: inout [String: Data],
        missing: inout Set<String>
    ) -> Data? {
        for key in lookupKeys(urlString) {
            if let hit = found[key] { return hit }
            if missing.contains(key) { continue }
            if let data = query(statement, key) {
                found[key] = data
                return data
            }
            missing.insert(key)
        }
        return nil
    }

    private static func query(_ statement: OpaquePointer, _ page: String) -> Data? {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, page, -1, SQLITE_TRANSIENT)
        var best: (distance: Int, data: Data)?
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 8, count < 256_000, let blob = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: blob, count: count)
            let width = Int(sqlite3_column_int(statement, 1))
            let distance = abs(width - 32)
            if best == nil || distance < best!.distance {
                best = (distance, data)
            }
        }
        return best?.data
    }

    private static func open(_ path: String) -> OpaquePointer? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri(path), &database, flags, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        return database
    }

    private static func databasePath(_ browser: Browser) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch browser {
        case .brave:
            return home.appendingPathComponent(
                "Library/Application Support/BraveSoftware/Brave-Browser/Default/Favicons"
            ).path
        case .helium:
            return home.appendingPathComponent(
                "Library/Application Support/net.imput.helium/Default/Favicons"
            ).path
        case .yab:
            // WebKit: no Chromium favicon store. Rows fall back to the app icon.
            return nil
        }
    }

    private static func uri(_ path: String) -> String {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "file:\(escaped)?mode=ro&immutable=1"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

import Foundation
import SwiftUI

public struct Palette: Sendable {
    public let background: Color
    public let text: Color
    public let muted: Color
    public let placeholder: Color
    public let rule: Color
    public let row: Color
    public let accent: Color
    public let onAccent: Color

    let codes: Codes

    struct Codes: Equatable, Sendable {
        var background: UInt32
        var text: UInt32
        var muted: UInt32
        var placeholder: UInt32
        var rule: UInt32
        var row: UInt32
        var accent: UInt32
        var onAccent: UInt32
    }

    init(
        background: UInt32, text: UInt32, muted: UInt32, placeholder: UInt32, rule: UInt32,
        row: UInt32, accent: UInt32, onAccent: UInt32
    ) {
        codes = Codes(
            background: background, text: text, muted: muted, placeholder: placeholder, rule: rule,
            row: row, accent: accent, onAccent: onAccent
        )
        self.background = Self.color(background)
        self.text = Self.color(text)
        self.muted = Self.color(muted)
        self.placeholder = Self.color(placeholder)
        self.rule = Self.color(rule)
        self.row = Self.color(row)
        self.accent = Self.color(accent)
        self.onAccent = Self.color(onAccent)
    }

    private static func color(_ code: UInt32) -> Color {
        let red = Double((code >> 16) & 0xFF) / 255
        let green = Double((code >> 8) & 0xFF) / 255
        let blue = Double(code & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}

public struct Theme: Sendable {
    public let dark: Palette
    public let light: Palette

    public init(dark: Palette, light: Palette) {
        self.dark = dark
        self.light = light
    }

    public func palette(for scheme: ColorScheme) -> Palette {
        scheme == .dark ? dark : light
    }

    /// Defaults mirror the Rex terminal's themes, so the panel looks native next to it:
    /// misty-forest (dark) and orchard-breeze (light). accent = its cursor, row = its selection.
    public static let defaults = Theme(
        dark: Palette(
            background: 0x131A16, text: 0xC4D2C5, muted: 0x8F9988, placeholder: 0x55665A, rule: 0x1F2C24,
            row: 0x2C3F33, accent: 0x9DC2A0, onAccent: 0x131A16
        ),
        light: Palette(
            background: 0xF4F9EF, text: 0x3A4A35, muted: 0x75856B, placeholder: 0xA5AE9D, rule: 0xE4F2D9,
            row: 0xD4ECC4, accent: 0x5DA24F, onAccent: 0xF4F9EF
        )
    )

    public static func load() -> Theme {
        load(from: configURL)
    }

    public static func load(from url: URL) -> Theme {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return defaults }
        return parsing(text)
    }

    static func parsing(_ text: String) -> Theme {
        let tables = tables(text)
        return Theme(
            dark: merge(defaults.dark, tables["theme.dark"]),
            light: merge(defaults.light, tables["theme.light"])
        )
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/flaneur/config.toml")
    }

    /// `hotkey = "…"` from the config file, nil when unset or unreadable.
    public static func hotkeySpec() -> String? {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        return hotkey(in: text)
    }

    /// The top-level `hotkey = "…"` line. It must sit before the first [table], as TOML says.
    static func hotkey(in text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = stripComment(String(raw))
            if line.isEmpty { continue }
            if line.hasPrefix("[") { return nil }
            guard let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == "hotkey" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func merge(_ base: Palette, _ table: [String: String]?) -> Palette {
        guard let table else { return base }
        func code(_ key: String, _ fallback: UInt32) -> UInt32 {
            guard let raw = table[key], let parsed = hex(raw) else { return fallback }
            return parsed
        }
        return Palette(
            background: code("background", base.codes.background),
            text: code("text", base.codes.text),
            muted: code("muted", base.codes.muted),
            placeholder: code("placeholder", base.codes.placeholder),
            rule: code("rule", base.codes.rule),
            row: code("row", base.codes.row),
            accent: code("accent", base.codes.accent),
            onAccent: code("on_accent", base.codes.onAccent)
        )
    }

    /// Flat TOML subset shared by every config consumer: comments, blanks, `[table]`, `key = "value"`.
    static func tables(_ text: String) -> [String: [String: String]] {
        var tables: [String: [String: String]] = [:]
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = stripComment(String(raw))
            if line.isEmpty { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                current = name
                if tables[name] == nil { tables[name] = [:] }
                continue
            }
            guard let section = current, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if key == "hotkey" { continue }
            tables[section, default: [:]][key] = value
        }
        return tables
    }

    private static func stripComment(_ line: String) -> String {
        var quoted = false
        var kept = ""
        for character in line {
            if character == "\"" { quoted.toggle() }
            if character == "#", !quoted { break }
            kept.append(character)
        }
        return kept.trimmingCharacters(in: .whitespaces)
    }

    private static func hex(_ raw: String) -> UInt32? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 else { return nil }
        return UInt32(text, radix: 16)
    }
}

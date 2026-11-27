import Foundation
import Testing
@testable import FlaneurKit

struct LogTests {
    private func temporaryLog() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("flaneur.log")
    }

    @Test func linesAreTimestampedAndAppended() throws {
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = LogFile(url: url)
        log.write("INFO", "first")
        log.write("ERROR", "second")
        log.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("INFO first"))
        #expect(lines[1].hasSuffix("ERROR second"))
        #expect(lines[0].contains("[\(ProcessInfo.processInfo.processIdentifier)]"))
    }

    @Test func oversizedLogRotatesToOnePreviousFile() throws {
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = LogFile(url: url, maxBytes: 100)
        first.write("INFO", String(repeating: "x", count: 200))
        first.flush()
        let second = LogFile(url: url, maxBytes: 100)
        second.write("INFO", "fresh")
        second.flush()
        let previous = url.appendingPathExtension("1")
        #expect(try String(contentsOf: previous, encoding: .utf8).contains("xxx"))
        #expect(try String(contentsOf: url, encoding: .utf8).hasSuffix("INFO fresh\n"))
    }
}

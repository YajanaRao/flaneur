import Darwin
import Foundation

enum ShellError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case exit(Int32, stderr: String)
}

enum Shell {
    /// Absolute executable. Readers start before the wait so a full pipe cannot stall the child.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> Data {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw ShellError.launchFailed
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? "/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/bin:\(path)"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process)
        return try await withTaskCancellationHandler {
            async let stdoutRead = readToEnd(stdout.fileHandleForReading)
            async let stderrRead = readToEnd(stderr.fileHandleForReading)
            do {
                try process.run()
            } catch {
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                _ = await stdoutRead
                _ = await stderrRead
                throw ShellError.launchFailed
            }

            if Task.isCancelled {
                await stop(process)
                _ = await stdoutRead
                _ = await stderrRead
                throw CancellationError()
            }

            let waited = await wait(process, timeout: timeout)
            if Task.isCancelled {
                await stop(process)
                _ = await stdoutRead
                _ = await stderrRead
                throw CancellationError()
            }
            if waited == .timedOut {
                await stop(process)
                _ = await stdoutRead
                _ = await stderrRead
                throw ShellError.timedOut
            }

            let output = await stdoutRead
            let errorOutput = await stderrRead
            let status = process.terminationStatus
            if status != 0 {
                throw ShellError.exit(status, stderr: String(data: errorOutput, encoding: .utf8) ?? "")
            }
            return output
        } onCancel: {
            box.terminate()
        }
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.readDataToEndOfFile()
                continuation.resume(returning: data)
            }
        }
    }

    private static func stop(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        if await wait(process, timeout: .milliseconds(200)) == .exited { return }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        _ = await wait(process, timeout: .seconds(1))
    }

    fileprivate enum Wait { case exited, timedOut }

    private static func wait(_ process: Process, timeout: Duration) async -> Wait {
        await withCheckedContinuation { continuation in
            let gate = ResumeGate(continuation)
            process.terminationHandler = { _ in gate.resume(.exited) }
            if !process.isRunning {
                gate.resume(.exited)
                return
            }
            let seconds = Double(timeout.components.seconds)
                + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                gate.resume(.timedOut)
            }
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    init(_ process: Process) { self.process = process }
    func terminate() {
        lock.lock()
        let process = process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Shell.Wait, Never>?
    init(_ continuation: CheckedContinuation<Shell.Wait, Never>) {
        self.continuation = continuation
    }
    func resume(_ value: Shell.Wait) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

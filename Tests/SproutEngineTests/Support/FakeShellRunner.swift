import Foundation
@testable import SproutEngine

/// Records every call; returns scripted results matched by command substring.
final class FakeShellRunner: ShellRunner, @unchecked Sendable {
    struct Call: Equatable { let command: String; let cwd: String; let env: [String: String] }

    private(set) var calls: [Call] = []
    /// command-substring -> result. First match wins; falls back to exit 0 empty.
    var runResults: [(match: String, result: ProcessResult)] = []
    /// command-substring -> handle factory.
    var handles: [(match: String, make: () -> FakeProcessHandle)] = []

    func run(_ command: String, cwd: URL, env: [String: String]) async throws -> ProcessResult {
        calls.append(Call(command: command, cwd: cwd.path, env: env))
        for r in runResults where command.contains(r.match) { return r.result }
        return ProcessResult(stdout: "", stderr: "", exitCode: 0)
    }

    func launch(_ command: String, cwd: URL, env: [String: String]) throws -> ProcessHandle {
        calls.append(Call(command: command, cwd: cwd.path, env: env))
        for h in handles where command.contains(h.match) { return h.make() }
        return FakeProcessHandle(pid: 4242, exitCode: 0, lines: [])
    }
}

final class FakeProcessHandle: ProcessHandle, @unchecked Sendable {
    let pid: Int32
    private let exit: Int32
    private let lines: [LogLine]
    private(set) var terminated = false

    init(pid: Int32, exitCode: Int32, lines: [LogLine]) {
        self.pid = pid; self.exit = exitCode; self.lines = lines
    }

    var logs: AsyncStream<LogLine> {
        let lines = self.lines
        return AsyncStream { cont in
            for l in lines { cont.yield(l) }
            cont.finish()
        }
    }
    func terminate(graceSeconds: Double) async { terminated = true }
    func waitForExit() async -> Int32 { exit }
}

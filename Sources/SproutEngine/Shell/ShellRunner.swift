import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
    public var succeeded: Bool { exitCode == 0 }
}

public struct LogLine: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case stdout, stderr }
    public let source: Source
    public let text: String
    public init(source: Source, text: String) { self.source = source; self.text = text }
}

/// Handle on a launched, possibly long-running process.
public protocol ProcessHandle: Sendable {
    var pid: Int32 { get }
    var logs: AsyncStream<LogLine> { get }
    /// SIGTERM the process group, then SIGKILL after `graceSeconds`.
    func terminate(graceSeconds: Double) async
    /// Awaits exit, returns exit code.
    func waitForExit() async -> Int32
}

public protocol ShellRunner: Sendable {
    /// One-shot: run, wait, collect output.
    func run(_ command: String, cwd: URL, env: [String: String]) async throws -> ProcessResult
    /// Launch a process, return a handle (PID + live logs + lifecycle control).
    func launch(_ command: String, cwd: URL, env: [String: String]) throws -> ProcessHandle
}

import Foundation

public struct LoginShellRunner: ShellRunner {
    private let shellPath: String

    public init(shellPath: String? = nil) {
        self.shellPath = shellPath ?? Self.resolveLoginShell()
    }

    /// $SHELL, else the passwd entry, else /bin/zsh.
    static func resolveLoginShell() -> String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    public func run(_ command: String, cwd: URL, env: [String: String]) async throws
        -> ProcessResult
    {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shellPath)
        proc.arguments = ["-l", "-c", command]
        proc.currentDirectoryURL = cwd
        proc.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }

        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return ProcessResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: proc.terminationStatus)
    }

    public func launch(_ command: String, cwd: URL, env: [String: String]) throws -> ProcessHandle {
        let merged = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        return try PosixSpawnedProcess(
            shellPath: shellPath, command: command, cwd: cwd.path, env: merged)
    }
}

/// A child launched in its own session (setsid) so signaling -pid hits the whole group.
final class PosixSpawnedProcess: ProcessHandle, @unchecked Sendable {
    let pid: Int32
    let logs: AsyncStream<LogLine>
    /// Write end of the child's stdin. We never write to it, but holding it open
    /// keeps the child's stdin from hitting EOF. Watch-mode dev servers (esbuild,
    /// vite) self-terminate when stdin closes; a GUI app's inherited fd 0 is already
    /// closed, so without this the watcher dies on spawn.
    private let stdinWriteFD: Int32

    init(shellPath: String, command: String, cwd: String, env: [String: String]) throws {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        var inPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0, pipe(&inPipe) == 0 else {
            throw ShellSpawnError.pipeFailed
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addclose(&actions, inPipe[0])
        posix_spawn_file_actions_addclose(&actions, inPipe[1])
        posix_spawn_file_actions_addclose(&actions, outPipe[0])
        posix_spawn_file_actions_addclose(&actions, errPipe[0])

        // chdir via a wrapper command (posix_spawn has no cwd before 10.15 API everywhere).
        let full = "cd \(cwd.shellQuoted) && \(command)"
        let argv: [String] = [shellPath, "-l", "-c", full]
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] =
            env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }

        var childPid: pid_t = 0
        let rc = posix_spawn(&childPid, shellPath, &actions, &attr, cArgs, cEnv)
        close(outPipe[1]); close(errPipe[1]); close(inPipe[0])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0]); close(inPipe[1])
            throw ShellSpawnError.spawnFailed(rc)
        }
        self.pid = childPid
        self.stdinWriteFD = inPipe[1]

        let oFD = outPipe[0], eFD = errPipe[0]
        self.logs = AsyncStream { cont in
            let group = DispatchGroup()
            Self.pump(fd: oFD, source: .stdout, group: group, cont: cont)
            Self.pump(fd: eFD, source: .stderr, group: group, cont: cont)
            group.notify(queue: .global()) { cont.finish() }
        }
    }

    private static func pump(
        fd: Int32, source: LogLine.Source,
        group: DispatchGroup, cont: AsyncStream<LogLine>.Continuation
    ) {
        group.enter()
        DispatchQueue.global().async {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            while case let data = handle.availableData, !data.isEmpty {
                let text = String(decoding: data, as: UTF8.self)
                for line in text.split(separator: "\n", omittingEmptySubsequences: false)
                where !line.isEmpty {
                    cont.yield(LogLine(source: source, text: String(line)))
                }
            }
            group.leave()
        }
    }

    func terminate(graceSeconds: Double) async {
        close(stdinWriteFD)
        kill(-pid, SIGTERM)
        try? await Task.sleep(nanoseconds: UInt64(graceSeconds * 1_000_000_000))
        if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global().async {
                var status: Int32 = 0
                waitpid(self.pid, &status, 0)
                let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                c.resume(returning: Int32(code))
            }
        }
    }
}

enum ShellSpawnError: Error { case pipeFailed, spawnFailed(Int32) }

extension String {
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

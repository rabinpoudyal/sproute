import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum PTYError: Error, Equatable {
    case forkFailed(Int32)
}

/// Handle on an interactive process running under a pseudo-terminal. Output is the raw
/// byte stream from the pty master (ANSI escape codes intact — a terminal emulator
/// renders it). Input is written back to the same master.
public protocol PTYHandle: Sendable {
    var pid: Int32 { get }
    var output: AsyncStream<Data> { get }
    /// Write user input (keystrokes) to the pty master.
    func send(_ data: Data)
    /// Set the pty window size (TIOCSWINSZ) so the child reflows to the view.
    func resize(cols: Int, rows: Int)
    /// SIGTERM the process group, then SIGKILL after `graceSeconds`.
    func terminate(graceSeconds: Double) async
    func waitForExit() async -> Int32
}

public protocol PTYSpawner: Sendable {
    func spawn(command: String, cwd: URL, env: [String: String]) throws -> PTYHandle
    func spawnInteractive(cwd: URL, env: [String: String]) throws -> PTYHandle
}

/// Spawns the login shell under a real pty via `forkpty`, running `$SHELL -l -c <command>`.
/// The login shell (not interactive) matches `LoginShellRunner`'s environment, so the same
/// rbenv-exec gotcha applies: Ruby commands must be prefixed in `.sprout.toml`.
public struct ForkPTYSpawner: PTYSpawner {
    private let shellPath: String
    public init(shellPath: String? = nil) {
        self.shellPath = shellPath ?? LoginShellRunner.resolveLoginShell()
    }

    /// `$SHELL -l -c <command>`: login (non-interactive) — matches `LoginShellRunner`.
    static func loginArgs(_ shell: String, _ command: String) -> [String] {
        [shell, "-l", "-c", command]
    }
    /// `$SHELL -l -i`: login + interactive, so `.zshrc` (rbenv/nvm/aliases) loads.
    static func interactiveArgs(_ shell: String) -> [String] {
        [shell, "-l", "-i"]
    }

    public func spawn(command: String, cwd: URL, env: [String: String]) throws -> PTYHandle {
        let merged = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        return try ForkPTYProcess(
            shellPath: shellPath, argv: Self.loginArgs(shellPath, command),
            cwd: cwd.path, env: merged)
    }

    public func spawnInteractive(cwd: URL, env: [String: String]) throws -> PTYHandle {
        let merged = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        return try ForkPTYProcess(
            shellPath: shellPath, argv: Self.interactiveArgs(shellPath),
            cwd: cwd.path, env: merged)
    }
}

/// Idempotent, thread-safe close of the pty master fd. Shared between the output read
/// loop (which closes on natural exit / EOF) and `terminate`, so whichever finishes first
/// closes the fd exactly once.
private final class MasterFDCloser: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false
    init(fd: Int32) { self.fd = fd }
    func close() {
        lock.lock()
        defer { lock.unlock() }
        if closed { return }
        closed = true
        Darwin.close(fd)
    }
}

final class ForkPTYProcess: PTYHandle, @unchecked Sendable {
    let pid: Int32
    let output: AsyncStream<Data>
    private let masterFD: Int32
    private let masterCloser: MasterFDCloser

    init(shellPath: String, argv: [String], cwd: String, env: [String: String]) throws {
        // Build all C arrays BEFORE forking — only async-signal-safe calls (chdir, execve,
        // _exit) may run in the child between fork and exec.
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] =
            env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cCwd = strdup(cwd)
        let cShell = strdup(shellPath)
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            free(cCwd)
            free(cShell)
        }

        var master: Int32 = 0
        var ws = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        let childPid = forkpty(&master, nil, nil, &ws)
        if childPid < 0 { throw PTYError.forkFailed(errno) }
        if childPid == 0 {
            // Child: forkpty already called setsid + made the pty the controlling tty.
            _ = chdir(cCwd)
            _ = execve(cShell, cArgs, cEnv)
            _exit(127)
        }

        self.pid = childPid
        self.masterFD = master
        let closer = MasterFDCloser(fd: master)
        self.masterCloser = closer
        let fd = master
        self.output = AsyncStream { cont in
            DispatchQueue.global().async {
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n <= 0 { break }  // EOF or EIO once the child's tty closes
                    cont.yield(Data(buf[0..<n]))
                }
                cont.finish()
                closer.close()  // natural exit: the user typed `exit`/Ctrl-D or it crashed
            }
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            _ = write(masterFD, raw.baseAddress, raw.count)
        }
    }

    func resize(cols: Int, rows: Int) {
        var ws = winsize(
            ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, cols)),
            ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    func terminate(graceSeconds: Double) async {
        kill(-pid, SIGTERM)
        try? await Task.sleep(nanoseconds: UInt64(graceSeconds * 1_000_000_000))
        if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        masterCloser.close()
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

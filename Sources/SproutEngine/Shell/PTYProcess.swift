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
}

/// Spawns the login shell under a real pty via `forkpty`, running `$SHELL -l -c <command>`.
/// The login shell (not interactive) matches `LoginShellRunner`'s environment, so the same
/// rbenv-exec gotcha applies: Ruby commands must be prefixed in `.sprout.toml`.
public struct ForkPTYSpawner: PTYSpawner {
    private let shellPath: String
    public init(shellPath: String? = nil) {
        self.shellPath = shellPath ?? LoginShellRunner.resolveLoginShell()
    }
    public func spawn(command: String, cwd: URL, env: [String: String]) throws -> PTYHandle {
        let merged = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        return try ForkPTYProcess(
            shellPath: shellPath, command: command, cwd: cwd.path, env: merged)
    }
}

final class ForkPTYProcess: PTYHandle, @unchecked Sendable {
    let pid: Int32
    let output: AsyncStream<Data>
    private let masterFD: Int32

    init(shellPath: String, command: String, cwd: String, env: [String: String]) throws {
        // Build all C arrays BEFORE forking — only async-signal-safe calls (chdir, execve,
        // _exit) may run in the child between fork and exec.
        let argv = [shellPath, "-l", "-c", command]
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
        close(masterFD)
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

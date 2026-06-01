import Foundation

public actor ServerSupervisor {
    public enum Status: Sendable, Equatable { case starting, running, crashed, stopped }

    private let shell: ShellRunner
    private let renderer: TemplateRenderer
    private var handle: ProcessHandle?
    private var stopping = false
    public private(set) var status: Status = .stopped

    public init(shell: ShellRunner, renderer: TemplateRenderer) {
        self.shell = shell; self.renderer = renderer
    }

    public var pid: Int32? { handle?.pid }

    /// Starts the server. Returns its PID. Logs stream to `onLog`. Exit is watched in the
    /// background: `onExit(pid, code)` fires on every natural exit (clean or crash). It is
    /// reported with the child's pid so a caller can ignore stale exits from a process it
    /// already stopped or restarted. `onExit` fires independently of this actor's lifetime
    /// (the watch task retains the handle + closure, not `self`), so a crash is still
    /// reported even after a transient supervisor is released.
    @discardableResult
    public func start(
        command: String, ctx: TemplateContext, cwd: URL,
        env: [String: String],
        onLog: @escaping @Sendable (LogLine) -> Void,
        onExit: @escaping @Sendable (_ pid: Int32, _ code: Int32) -> Void = { _, _ in }
    ) async throws -> Int32 {
        status = .starting
        stopping = false
        let rendered = renderer.render(command, ctx)
        let h = try shell.launch(rendered, cwd: cwd, env: env)
        handle = h
        status = .running

        // Stream logs in the background.
        Task { for await line in h.logs { onLog(line) } }
        // Watch for exit. Update our own status best-effort (only while alive), then always
        // notify the caller with pid + code.
        Task { [weak self] in
            let code = await h.waitForExit()
            await self?.handleExit(code: code)
            onExit(h.pid, code)
        }
        return h.pid
    }

    public func stop(graceSeconds: Double) async {
        stopping = true
        await handle?.terminate(graceSeconds: graceSeconds)
        handle = nil
        status = .stopped
    }

    @discardableResult
    public func restart(
        command: String, ctx: TemplateContext, cwd: URL,
        env: [String: String],
        onLog: @escaping @Sendable (LogLine) -> Void
    ) async throws -> Int32 {
        await stop(graceSeconds: 5)
        return try await start(command: command, ctx: ctx, cwd: cwd, env: env, onLog: onLog)
    }

    private func handleExit(code: Int32) {
        guard !stopping else { return }  // expected shutdown already set .stopped
        status = (code == 0) ? .stopped : .crashed
        handle = nil
    }
}

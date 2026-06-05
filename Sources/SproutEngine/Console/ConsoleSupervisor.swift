import Foundation

public enum ConsoleStatus: Sendable, Equatable { case running, exited }

public enum SessionKind: Sendable, Equatable { case console, shell }

/// A live console session. `handle` is the bridge the UI uses for output/input/resize;
/// the supervisor retains it for lifecycle control (stop / killAll).
public struct ConsoleSession: Sendable {
    public let id: UUID
    public let branch: String
    public let name: String
    public let handle: PTYHandle
}

/// Display snapshot of a session (no PTY handle).
public struct ConsoleSessionInfo: Sendable, Equatable {
    public let id: UUID
    public let branch: String
    public let name: String
    public let pid: Int32
    public let status: ConsoleStatus
}

/// Owns interactive PTY console sessions, separate from `ServerSupervisor` (whose pipe/
/// log-only model does not fit bidirectional PTY I/O). Sessions are in-memory only and
/// never persisted: they do not survive an app restart by design.
public actor ConsoleSupervisor {
    private struct Entry {
        let branch: String
        let name: String
        let kind: SessionKind
        let handle: PTYHandle
        var status: ConsoleStatus
    }

    private let spawner: PTYSpawner
    private let renderer: TemplateRenderer
    private var entries: [UUID: Entry] = [:]

    public init(spawner: PTYSpawner, renderer: TemplateRenderer) {
        self.spawner = spawner
        self.renderer = renderer
    }

    /// Spawns a console. `onExit(id, code)` fires when it later exits naturally (the user
    /// typed `exit`, or it crashed); the session is removed before the callback runs.
    @discardableResult
    public func start(
        branch: String, name: String, command: String,
        ctx: TemplateContext, cwd: URL, env: [String: String],
        onExit: @escaping @Sendable (_ id: UUID, _ code: Int32) -> Void
    ) throws -> ConsoleSession {
        let rendered = renderer.render(command, ctx)
        let handle = try spawner.spawn(command: rendered, cwd: cwd, env: env)
        let id = UUID()
        entries[id] = Entry(
            branch: branch, name: name, kind: .console, handle: handle, status: .running)
        // Watch for natural exit. The task retains the handle + closure, not self via a
        // strong cycle: we hop back into the actor to drop the entry, then notify.
        Task { [weak self] in
            let code = await handle.waitForExit()
            await self?.markExited(id: id)
            onExit(id, code)
        }
        return ConsoleSession(id: id, branch: branch, name: name, handle: handle)
    }

    /// Spawns an interactive login shell session (`kind: .shell`) for `branch`. Unlike
    /// `start`, there is no command/template: the shell is interactive so `.zshrc` loads.
    /// Shell sessions are excluded from `list` (they are not consoles) but are killed by
    /// `killAll`. `onExit` fires on natural exit (user typed `exit`/Ctrl-D, or crash).
    @discardableResult
    public func startShell(
        branch: String, cwd: URL, env: [String: String],
        onExit: @escaping @Sendable (_ id: UUID, _ code: Int32) -> Void
    ) throws -> ConsoleSession {
        let handle = try spawner.spawnInteractive(cwd: cwd, env: env)
        let id = UUID()
        entries[id] = Entry(
            branch: branch, name: "shell", kind: .shell, handle: handle, status: .running)
        Task { [weak self] in
            let code = await handle.waitForExit()
            await self?.markExited(id: id)
            onExit(id, code)
        }
        return ConsoleSession(id: id, branch: branch, name: "shell", handle: handle)
    }

    public func stop(id: UUID) async {
        guard let entry = entries[id] else { return }
        entries[id] = nil
        await entry.handle.terminate(graceSeconds: 5)
    }

    public func killAll(branch: String) async {
        let toKill = entries.filter { $0.value.branch == branch }
        for (id, _) in toKill { entries[id] = nil }
        for (_, entry) in toKill { await entry.handle.terminate(graceSeconds: 5) }
    }

    public func list(branch: String) -> [ConsoleSessionInfo] {
        entries
            .filter { $0.value.branch == branch && $0.value.kind == .console }
            .map {
                ConsoleSessionInfo(
                    id: $0.key, branch: $0.value.branch, name: $0.value.name,
                    pid: $0.value.handle.pid, status: $0.value.status)
            }
    }

    /// The branch's interactive shell session, if one is running.
    public func shell(branch: String) -> ConsoleSessionInfo? {
        entries
            .filter { $0.value.branch == branch && $0.value.kind == .shell }
            .map {
                ConsoleSessionInfo(
                    id: $0.key, branch: $0.value.branch, name: $0.value.name,
                    pid: $0.value.handle.pid, status: $0.value.status)
            }
            .first
    }

    private func markExited(id: UUID) {
        entries[id] = nil
    }
}

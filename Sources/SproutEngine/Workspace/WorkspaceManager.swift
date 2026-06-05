import Foundation

public enum TeardownError: Error, Equatable {
    case workspaceNotFound(UUID)
    case dirtyWorktree
}

public protocol ProcessChecker: Sendable {
    func isAlive(pid: Int32) -> Bool
}

public struct PosixProcessChecker: ProcessChecker {
    public init() {}
    public func isAlive(pid: Int32) -> Bool { kill(pid, 0) == 0 }
}

/// Terminates a running process (by PID) and its process group.
public protocol ProcessTerminator: Sendable {
    func terminate(pid: Int32, graceSeconds: Double) async
}

/// Real impl: SIGTERM the process group (-pid), wait the grace period, then SIGKILL.
public struct PosixProcessTerminator: ProcessTerminator {
    public init() {}
    public func terminate(pid: Int32, graceSeconds: Double) async {
        kill(-pid, SIGTERM)
        try? await Task.sleep(nanoseconds: UInt64(graceSeconds * 1_000_000_000))
        if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
    }
}

public struct WorkspaceManager: Sendable {
    let git: GitService
    let database: DatabaseService
    let envLinker: EnvLinker
    let fs: FileSystem
    let setupRunner: SetupRunner
    let store: StateStore
    let checker: ProcessChecker
    let terminator: ProcessTerminator
    let renderer: TemplateRenderer
    let shell: ShellRunner

    public init(
        git: GitService, database: DatabaseService,
        envLinker: EnvLinker, fs: FileSystem, setupRunner: SetupRunner,
        store: StateStore, checker: ProcessChecker, terminator: ProcessTerminator,
        renderer: TemplateRenderer, shell: ShellRunner
    ) {
        self.git = git; self.database = database
        self.envLinker = envLinker; self.fs = fs; self.setupRunner = setupRunner
        self.store = store; self.checker = checker; self.terminator = terminator
        self.renderer = renderer; self.shell = shell
    }

    private func context(
        config: Config, branch: String, port: Int, ports: [String: Int],
        dbName: String, worktree: String
    ) -> TemplateContext {
        TemplateContext(
            project: config.project.name, branch: branch,
            port: port, dbName: dbName, worktree: worktree, ports: ports)
    }

    /// `log` routes output per stream so each process (and setup) can be shown in its
    /// own console. `stream` is `"setup"` during setup and the process name while a
    /// `[[run.process]]` runs.
    ///
    /// `onProcessExit(name, pid, code)` fires when a started process later exits — most
    /// importantly when it crashes on startup. The caller uses it to flip the persisted
    /// `ProcessState` to `.crashed`/`.stopped`; without it a process that dies right after
    /// launch keeps a stale `.running` status forever (the per-process console still holds
    /// the stderr, but nothing signals that it died).
    public func create(
        config: Config, repo: URL, base: String, branch: String,
        log: @escaping @Sendable (_ stream: String, LogLine) -> Void,
        onProcessExit: @escaping @Sendable (_ name: String, _ pid: Int32, _ code: Int32) -> Void = {
            _, _, _ in
        }
    ) async throws -> WorkspaceRecord {
        let slug = TemplateContext.slugify(branch)
        // Resolve the worktree path up front. A relative `base_dir` (e.g.
        // "../worktrees") must be resolved against the repo, not the process cwd:
        // git resolves it relative to the repo, but URL(fileURLWithPath:) would use
        // the cwd, so the two would disagree and EnvLinker would write into a path
        // that was never created. Anchoring to `repo` keeps every step consistent.
        let rawPath = "\(config.worktree.baseDir)/\(slug)"
        let worktreeURL =
            (rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath)
            : repo.appendingPathComponent(rawPath)).standardizedFileURL
        let worktreePath = worktreeURL.path
        let dbName = "\(config.project.name)_\(slug)"

        // Track what to roll back, in reverse order.
        var didWorktree = false, didDB = false
        var startedProcesses: [ProcessState] = []

        do {
            try await git.worktreeAdd(repo: repo, path: worktreePath, base: base, branch: branch)
            didWorktree = true

            let plan = portPlan(config.run.processes)
            let port = primaryPort(config.run.processes)
            let ctx = context(
                config: config, branch: branch, port: port, ports: plan,
                dbName: dbName, worktree: worktreePath)

            try await database.create(config.database, ctx: ctx, cwd: repo)
            didDB = true

            try envLinker.link(
                sources: config.env.symlinkSources,
                primaryRepo: repo, worktree: worktreeURL)
            let dbURL = database.databaseURL(config.database, ctx: ctx)
            try envLinker.writeLocal(
                file: config.env.localFile, worktree: worktreeURL,
                port: port, databaseURL: dbURL)

            var record = WorkspaceRecord(
                id: UUID(), branch: branch, base: base, worktreePath: worktreePath,
                port: port, dbName: dbName, status: .creating,
                createdAt: Date())
            try store.upsert(record)

            let childEnv = ["PORT": String(port), "DATABASE_URL": dbURL]
            try await setupRunner.run(
                config.setup, ctx: ctx, cwd: worktreeURL,
                env: childEnv, onLog: { log("setup", $0) })

            for proc in config.run.processes {
                let ownPort = proc.port ?? port
                let pctx = context(
                    config: config, branch: branch, port: ownPort, ports: plan,
                    dbName: dbName, worktree: worktreePath)
                let penv = ["PORT": String(ownPort), "DATABASE_URL": dbURL]
                let supervisor = ServerSupervisor(shell: shell, renderer: renderer)
                let name = proc.name
                let pid = try await supervisor.start(
                    command: proc.command, ctx: pctx,
                    cwd: worktreeURL, env: penv, onLog: { log(name, $0) },
                    onExit: { pid, code in onProcessExit(name, pid, code) })
                startedProcesses.append(ProcessState(name: proc.name, pid: pid, status: .running))
            }
            record.processes = startedProcesses
            record.status = aggregateStatus(startedProcesses)
            try store.upsert(record)
            return record
        } catch {
            for proc in startedProcesses {
                if let pid = proc.pid {
                    await terminator.terminate(pid: pid, graceSeconds: 5)
                }
            }
            await rollback(
                config: config, repo: repo, worktreePath: worktreePath,
                dbName: dbName, branch: branch,
                didWorktree: didWorktree, didDB: didDB)
            throw error
        }
    }

    private func rollback(
        config: Config, repo: URL, worktreePath: String, dbName: String,
        branch: String, didWorktree: Bool, didDB: Bool
    ) async {
        // remove any persisted record for this branch
        if let existing = try? store.load().first(where: { $0.branch == branch }) {
            try? store.remove(id: existing.id)
        }
        if didDB {
            let ctx = context(
                config: config, branch: branch, port: 0, ports: [:],
                dbName: dbName, worktree: worktreePath)
            try? await database.drop(config.database, ctx: ctx, cwd: repo)
        }
        // Clean up the worktree directory no matter how far creation got, so a retry
        // is not blocked by a leftover dir. `git worktree add` may have created the
        // directory even when a later step failed.
        let worktreeURL = URL(fileURLWithPath: worktreePath)
        try? await git.worktreeRemove(repo: repo, path: worktreePath)
        if fs.fileExists(worktreeURL) {
            try? fs.removeItem(worktreeURL)
        }
        try? await git.pruneWorktrees(repo: repo)
        // `worktree add -b` created the branch, so a successful add means we own it;
        // delete it so retrying the same branch name does not fail.
        if didWorktree {
            try? await git.deleteBranch(repo: repo, branch: branch)
        }
    }

    public func teardown(
        id: UUID, config: Config, repo: URL,
        push: Bool, force: Bool
    ) async throws {
        guard let record = try store.load().first(where: { $0.id == id }) else {
            throw TeardownError.workspaceNotFound(id)
        }
        let worktreeURL = URL(fileURLWithPath: record.worktreePath)
        let ctx = context(
            config: config, branch: record.branch, port: record.port,
            ports: portPlan(config.run.processes),
            dbName: record.dbName, worktree: record.worktreePath)

        // pre-hook
        if let pre = config.hooks.preTeardown {
            _ = try? await shell.run(renderer.render(pre, ctx), cwd: worktreeURL, env: [:])
        }

        if push {
            if try await git.isDirty(worktree: worktreeURL), !force {
                throw TeardownError.dirtyWorktree
            }
            try await git.push(worktree: worktreeURL, branch: record.branch)
        }

        // stop every process
        for proc in record.processes {
            if let pid = proc.pid {
                await terminator.terminate(pid: pid, graceSeconds: 5)
            }
        }
        // drop DB
        try await database.drop(config.database, ctx: ctx, cwd: repo)
        // remove worktree
        try await git.worktreeRemove(repo: repo, path: record.worktreePath)
        // delete branch
        try await git.deleteBranch(repo: repo, branch: record.branch)

        // post-hook
        if let post = config.hooks.postTeardown {
            _ = try? await shell.run(renderer.render(post, ctx), cwd: repo, env: [:])
        }

        try store.remove(id: id)
    }

    public func reconcile() throws -> [ReconciledWorkspace] {
        var out: [ReconciledWorkspace] = []
        for var record in try store.load() {
            var changed = false
            for i in record.processes.indices {
                guard let pid = record.processes[i].pid else { continue }
                if !checker.isAlive(pid: pid), record.processes[i].status == .running {
                    record.processes[i].status = .stopped
                    record.processes[i].pid = nil
                    changed = true
                }
            }
            // Normalize the workspace status to its processes, not just when one died.
            // Records with no processes (or a stale persisted `running` from an older
            // build) must settle to the aggregate, e.g. `[]` -> `.stopped`.
            if record.status != .creating, record.status != .tearingDown {
                let status = aggregateStatus(record.processes)
                if status != record.status {
                    record.status = status
                    changed = true
                }
            }
            if changed { try store.upsert(record) }
            let orphaned = !fs.fileExists(URL(fileURLWithPath: record.worktreePath))
            out.append(ReconciledWorkspace(record: record, orphaned: orphaned))
        }
        return out
    }
}

public struct ReconciledWorkspace: Sendable, Equatable {
    public var record: WorkspaceRecord
    public var orphaned: Bool  // worktree directory no longer exists
    public var status: WorkspaceStatus { record.status }
}

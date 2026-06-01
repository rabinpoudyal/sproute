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
    let portAllocator: PortAllocator
    let database: DatabaseService
    let envLinker: EnvLinker
    let fs: FileSystem
    let setupRunner: SetupRunner
    let store: StateStore
    let checker: ProcessChecker
    let terminator: ProcessTerminator
    let renderer: TemplateRenderer
    let shell: ShellRunner

    public init(git: GitService, portAllocator: PortAllocator, database: DatabaseService,
                envLinker: EnvLinker, fs: FileSystem, setupRunner: SetupRunner,
                store: StateStore, checker: ProcessChecker, terminator: ProcessTerminator,
                renderer: TemplateRenderer, shell: ShellRunner) {
        self.git = git; self.portAllocator = portAllocator; self.database = database
        self.envLinker = envLinker; self.fs = fs; self.setupRunner = setupRunner
        self.store = store; self.checker = checker; self.terminator = terminator
        self.renderer = renderer; self.shell = shell
    }

    private func context(config: Config, branch: String, port: Int,
                         dbName: String, worktree: String) -> TemplateContext {
        TemplateContext(project: config.project.name, branch: branch,
                        port: port, dbName: dbName, worktree: worktree)
    }

    public func create(config: Config, repo: URL, base: String, branch: String,
                       onLog: @escaping @Sendable (LogLine) -> Void) async throws -> WorkspaceRecord {
        let slug = TemplateContext.slugify(branch)
        let worktreePath = "\(config.worktree.baseDir)/\(slug)"
        let worktreeURL = URL(fileURLWithPath: worktreePath)
        let dbName = "\(config.project.name)_\(slug)"

        // Track what to roll back, in reverse order.
        var didWorktree = false, didDB = false

        do {
            try await git.worktreeAdd(repo: repo, path: worktreePath, base: base, branch: branch)
            didWorktree = true

            let port = try portAllocator.allocate()
            let ctx = context(config: config, branch: branch, port: port,
                              dbName: dbName, worktree: worktreePath)

            try await database.create(config.database, ctx: ctx, cwd: repo)
            didDB = true

            try envLinker.link(sources: config.env.symlinkSources,
                               primaryRepo: repo, worktree: worktreeURL)
            let dbURL = database.databaseURL(config.database, ctx: ctx)
            try envLinker.writeLocal(file: config.env.localFile, worktree: worktreeURL,
                                     port: port, databaseURL: dbURL)

            var record = WorkspaceRecord(
                id: UUID(), branch: branch, base: base, worktreePath: worktreePath,
                port: port, dbName: dbName, status: .creating,
                serverPID: nil, createdAt: Date())
            try store.upsert(record)

            let childEnv = ["PORT": String(port), "DATABASE_URL": dbURL]
            try await setupRunner.run(config.setup, ctx: ctx, cwd: worktreeURL,
                                      env: childEnv, onLog: onLog)

            let supervisor = ServerSupervisor(shell: shell, renderer: renderer)
            let pid = try await supervisor.start(command: config.run.serverCommand, ctx: ctx,
                                                 cwd: worktreeURL, env: childEnv, onLog: onLog)
            record.serverPID = pid
            record.status = .running
            try store.upsert(record)
            return record
        } catch {
            await rollback(config: config, repo: repo, worktreePath: worktreePath,
                           dbName: dbName, branch: branch,
                           didWorktree: didWorktree, didDB: didDB)
            throw error
        }
    }

    private func rollback(config: Config, repo: URL, worktreePath: String, dbName: String,
                          branch: String, didWorktree: Bool, didDB: Bool) async {
        // remove any persisted record for this branch
        if let existing = try? store.load().first(where: { $0.branch == branch }) {
            try? store.remove(id: existing.id)
        }
        if didDB {
            let ctx = context(config: config, branch: branch, port: 0,
                              dbName: dbName, worktree: worktreePath)
            try? await database.drop(config.database, ctx: ctx, cwd: repo)
        }
        if didWorktree {
            try? await git.worktreeRemove(repo: repo, path: worktreePath)
        }
    }

    public func teardown(id: UUID, config: Config, repo: URL,
                         push: Bool, force: Bool) async throws {
        guard let record = try store.load().first(where: { $0.id == id }) else {
            throw TeardownError.workspaceNotFound(id)
        }
        let worktreeURL = URL(fileURLWithPath: record.worktreePath)
        let ctx = context(config: config, branch: record.branch, port: record.port,
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

        // stop server
        if let pid = record.serverPID {
            await terminator.terminate(pid: pid, graceSeconds: 5)
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
            let alive = record.serverPID.map { checker.isAlive(pid: $0) } ?? false
            if !alive, record.status == .running {
                record.status = .stopped
                record.serverPID = nil
                try store.upsert(record)
            }
            let orphaned = !fs.fileExists(URL(fileURLWithPath: record.worktreePath))
            out.append(ReconciledWorkspace(record: record, orphaned: orphaned))
        }
        return out
    }
}

public struct ReconciledWorkspace: Sendable, Equatable {
    public var record: WorkspaceRecord
    public var orphaned: Bool   // worktree directory no longer exists
    public var status: WorkspaceStatus { record.status }
}

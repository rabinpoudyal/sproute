import Foundation
import ArgumentParser
import SproutEngine

// MARK: - Composition root

private func stateURL() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".sprout/state.json")
}

private func loadConfig() throws -> Config {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return try TOMLConfigLoader.load(path: cwd.appendingPathComponent(".sprout.toml"))
}

private func makeManager(config: Config, store: StateStore) -> WorkspaceManager {
    let shell = LoginShellRunner()
    let renderer = TemplateRenderer()
    return WorkspaceManager(
        git: GitService(shell: shell),
        portAllocator: PortAllocator(config: config.port, store: store, prober: BindPortProber()),
        database: DatabaseService(shell: shell, renderer: renderer),
        envLinker: EnvLinker(fs: RealFileSystem()),
        fs: RealFileSystem(),
        setupRunner: SetupRunner(shell: shell, renderer: renderer),
        store: store,
        checker: PosixProcessChecker(),
        terminator: PosixProcessTerminator(),
        renderer: renderer,
        shell: shell)
}

private func repoURL() -> URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }

@Sendable private func printLog(_ line: LogLine) {
    let prefix = line.source == .stderr ? "[err] " : ""
    print(prefix + line.text)
}

// MARK: - Commands

@main
struct Sprout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sprout",
        abstract: "Sprout isolated git-worktree workspaces.",
        subcommands: [Create.self, List.self, Server.self, Push.self,
                      Done.self, Discard.self, Doctor.self])
}

struct Create: AsyncParsableCommand {
    @Option(name: .long) var base: String
    @Option(name: .long) var branch: String
    func run() async throws {
        let config = try loadConfig()
        let store = JSONStateStore(fileURL: stateURL())
        let mgr = makeManager(config: config, store: store)
        let rec = try await mgr.create(config: config, repo: repoURL(),
                                       base: base, branch: branch, onLog: printLog)
        print("created \(rec.branch)  port=\(rec.port)  db=\(rec.dbName)  pid=\(rec.serverPID ?? -1)")
    }
}

struct List: AsyncParsableCommand {
    func run() async throws {
        let store = JSONStateStore(fileURL: stateURL())
        for r in try store.load() {
            print("\(r.id)  \(r.branch)  :\(r.port)  \(r.dbName)  \(r.status.rawValue)  pid=\(r.serverPID ?? -1)")
        }
    }
}

struct Server: AsyncParsableCommand {
    @Argument var id: String
    @Argument var action: String   // "stop" | "restart"
    func run() async throws {
        let config = try loadConfig()
        let store = JSONStateStore(fileURL: stateURL())
        guard let uuid = UUID(uuidString: id),
              var rec = try store.load().first(where: { $0.id == uuid }) else {
            throw ValidationError("workspace not found: \(id)")
        }
        let shell = LoginShellRunner()
        let sup = ServerSupervisor(shell: shell, renderer: TemplateRenderer())
        let ctx = TemplateContext(project: config.project.name, branch: rec.branch,
                                  port: rec.port, dbName: rec.dbName, worktree: rec.worktreePath)
        let wt = URL(fileURLWithPath: rec.worktreePath)
        let env = ["PORT": String(rec.port),
                   "DATABASE_URL": DatabaseService(shell: shell, renderer: TemplateRenderer())
                       .databaseURL(config.database, ctx: ctx)]
        // stop the old PID if any
        if let pid = rec.serverPID { await PosixProcessTerminator().terminate(pid: pid, graceSeconds: 5) }
        if action == "restart" {
            let pid = try await sup.start(command: config.run.serverCommand, ctx: ctx,
                                          cwd: wt, env: env, onLog: printLog)
            rec.serverPID = pid; rec.status = .running
        } else {
            rec.serverPID = nil; rec.status = .stopped
        }
        try store.upsert(rec)
        print("\(action) ok")
    }
}

struct Push: AsyncParsableCommand {
    @Argument var id: String
    func run() async throws {
        let store = JSONStateStore(fileURL: stateURL())
        guard let uuid = UUID(uuidString: id),
              let rec = try store.load().first(where: { $0.id == uuid }) else {
            throw ValidationError("workspace not found: \(id)")
        }
        try await GitService(shell: LoginShellRunner())
            .push(worktree: URL(fileURLWithPath: rec.worktreePath), branch: rec.branch)
        print("pushed \(rec.branch)")
    }
}

struct Done: AsyncParsableCommand {
    @Argument var id: String
    @Flag(name: .long) var force = false
    func run() async throws {
        try await teardown(id: id, push: true, force: force)
    }
}

struct Discard: AsyncParsableCommand {
    @Argument var id: String
    func run() async throws { try await teardown(id: id, push: false, force: true) }
}

private func teardown(id: String, push: Bool, force: Bool) async throws {
    guard let uuid = UUID(uuidString: id) else { throw ValidationError("bad id: \(id)") }
    let config = try loadConfig()
    let store = JSONStateStore(fileURL: stateURL())
    let mgr = makeManager(config: config, store: store)
    try await mgr.teardown(id: uuid, config: config, repo: repoURL(), push: push, force: force)
    print("torn down \(id)")
}

struct Doctor: AsyncParsableCommand {
    func run() async throws {
        let shell = LoginShellRunner()
        let checks = await DoctorService(shell: shell)
            .check(tools: ["git", "createdb", "dropdb", "node"], cwd: repoURL())
        for c in checks {
            print("\(c.found ? "ok " : "MISSING") \(c.tool)\(c.path.map { "  \($0)" } ?? "")")
        }
        // reconcile if a config + state exist
        if let config = try? loadConfig() {
            let store = JSONStateStore(fileURL: stateURL())
            let reconciled = try makeManager(config: config, store: store).reconcile()
            for r in reconciled {
                let flag = r.orphaned ? " (orphaned worktree)" : ""
                print("  \(r.record.branch)  \(r.record.status.rawValue)\(flag)")
            }
        }
    }
}

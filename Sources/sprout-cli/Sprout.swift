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
        subcommands: [
            Create.self, List.self, Server.self, Push.self,
            Done.self, Discard.self, Doctor.self,
        ])
}

struct Create: AsyncParsableCommand {
    @Option(name: .long) var base: String
    @Option(name: .long) var branch: String
    func run() async throws {
        let config = try loadConfig()
        let store = JSONStateStore(fileURL: stateURL())
        let mgr = makeManager(config: config, store: store)
        let rec = try await mgr.create(
            config: config, repo: repoURL(),
            base: base, branch: branch, log: { _, line in printLog(line) },
            onProcessExit: { name, _, code in
                if code != 0 { print("[\(name)] exited with code \(code)") }
            })
        let procs = rec.processes.map { "\($0.name):\($0.pid ?? -1)" }.joined(separator: ",")
        print("created \(rec.branch)  port=\(rec.port)  db=\(rec.dbName)  [\(procs)]")
    }
}

struct List: AsyncParsableCommand {
    func run() async throws {
        let store = JSONStateStore(fileURL: stateURL())
        for r in try store.load() {
            let procs = r.processes.map { "\($0.name):\($0.pid ?? -1)" }.joined(separator: ",")
            print("\(r.id)  \(r.branch)  :\(r.port)  \(r.dbName)  \(r.status.rawValue)  [\(procs)]")
        }
    }
}

struct Server: AsyncParsableCommand {
    @Argument var id: String
    @Argument var action: String  // "stop" | "restart"
    @Option(name: .long) var process: String?

    func run() async throws {
        guard action == "stop" || action == "restart" else {
            throw ValidationError("action must be 'stop' or 'restart', got: \(action)")
        }
        let config = try loadConfig()
        let store = JSONStateStore(fileURL: stateURL())
        guard let uuid = UUID(uuidString: id),
            var rec = try store.load().first(where: { $0.id == uuid })
        else {
            throw ValidationError("workspace not found: \(id)")
        }
        let shell = LoginShellRunner()
        let renderer = TemplateRenderer()
        let ctx = TemplateContext(
            project: config.project.name, branch: rec.branch,
            port: rec.port, dbName: rec.dbName, worktree: rec.worktreePath)
        let wt = URL(fileURLWithPath: rec.worktreePath)
        let env = [
            "PORT": String(rec.port),
            "DATABASE_URL": DatabaseService(shell: shell, renderer: renderer)
                .databaseURL(config.database, ctx: ctx),
        ]

        // Which configured processes to act on.
        let targets = config.run.processes.filter { process == nil || $0.name == process }
        if targets.isEmpty { throw ValidationError("no matching process: \(process ?? "*")") }

        for proc in targets {
            // stop the existing pid for this process, if any
            if let pid = rec.processes.first(where: { $0.name == proc.name })?.pid {
                await PosixProcessTerminator().terminate(pid: pid, graceSeconds: 5)
            }
            let new: ProcessState
            if action == "restart" {
                let sup = ServerSupervisor(shell: shell, renderer: renderer)
                let pid = try await sup.start(
                    command: proc.command, ctx: ctx, cwd: wt, env: env, onLog: printLog)
                new = ProcessState(name: proc.name, pid: pid, status: .running)
            } else {
                new = ProcessState(name: proc.name, pid: nil, status: .stopped)
            }
            if let i = rec.processes.firstIndex(where: { $0.name == proc.name }) {
                rec.processes[i] = new
            } else {
                rec.processes.append(new)
            }
        }
        rec.status = aggregateStatus(rec.processes)
        try store.upsert(rec)
        print("\(action) ok")
    }
}

struct Push: AsyncParsableCommand {
    @Argument var id: String
    func run() async throws {
        let store = JSONStateStore(fileURL: stateURL())
        guard let uuid = UUID(uuidString: id),
            let rec = try store.load().first(where: { $0.id == uuid })
        else {
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

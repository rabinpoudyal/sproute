import AppKit
import Foundation
import SproutEngine

/// A workspace record paired with reconcile-derived liveness info, for display.
struct WorkspaceItem: Identifiable, Equatable {
    var record: WorkspaceRecord
    var orphaned: Bool  // worktree directory missing on disk
    var id: UUID { record.id }
}

/// One row in the create-progress checklist shown by the new-workspace sheet.
struct CreateStep: Identifiable, Equatable {
    let id: String
    let label: String
    var state: CreateStepState
}

/// Thrown when a create sub-step exceeds its time budget (e.g. an unresponsive
/// loopback helper), so the create fails with a clear message instead of hanging.
struct CreateTimeout: LocalizedError {
    var errorDescription: String? {
        "Timed out waiting for the loopback helper. Enable it in Settings, or turn off "
            + "per-branch loopback, then try again."
    }
}

/// One running interactive console, for display in the detail view and process list.
struct ConsoleSessionItem: Identifiable, Equatable {
    let id: UUID
    let branch: String
    let name: String
    var status: ConsoleStatus
}

/// Identifies one supervised process within a workspace branch.
private struct ProcessKey: Hashable {
    let branch: String
    let name: String
}

/// View-model for a single registered project. Wraps the headless engine
/// (`WorkspaceManager` + friends) and exposes UI-friendly state and actions.
@MainActor
final class ProjectStore: ObservableObject, Identifiable {
    nonisolated let id: String  // normalized root path
    let rootURL: URL
    let config: Config

    @Published private(set) var workspaces: [WorkspaceItem] = []
    @Published private(set) var doctor: [ToolCheck] = []
    @Published var lastError: AppError?
    @Published private(set) var consoleSessions: [ConsoleSessionItem] = []
    /// Ordered create-step checklist, updated live while `create` runs.
    @Published private(set) var createProgress: [CreateStep] = []
    /// Live agents launched in this project's workspaces, keyed for the UI by id.
    @Published private(set) var agents: [AgentRuntime] = []

    private let shell = LoginShellRunner()
    private let renderer = TemplateRenderer()
    private let store: StateStore
    private let manager: WorkspaceManager
    private let loopbackEnabled: Bool
    private let allocator: IPAllocator
    private let loopback: LoopbackCoordinator

    private var buffers: [ProcessKey: LogBuffer] = [:]
    /// Tail of the most recent create's streamed output. A failed create rolls
    /// the workspace back (record + log buffers vanish from the UI), so this is
    /// the only place left to show what actually failed — surfaced in the error.
    private var createLogTail: [String] = []
    private var supervisors: [ProcessKey: ServerSupervisor] = [:]
    private lazy var consoleSupervisor = ConsoleSupervisor(
        spawner: ForkPTYSpawner(), renderer: renderer)
    private var consoleControllers: [UUID: ConsoleSessionController] = [:]
    private var shellControllers: [String: ConsoleSessionController] = [:]

    /// Loopback receiver for Claude Code hook callbacks. Lazily started on the
    /// first agent launch; `hookPort` is the bound port once running.
    private let hookReceiver: AgentHookReceiving
    private var hookPort: UInt16?
    private var hookConsumer: Task<Void, Never>?

    var name: String { config.project.name }

    init(
        rootURL: URL, config: Config,
        loopbackEnabled: Bool = false,
        allocator: IPAllocator? = nil,
        loopback: LoopbackCoordinator? = nil,
        hookReceiver: AgentHookReceiving = AgentHookReceiver()
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.id = self.rootURL.path
        self.config = config
        self.hookReceiver = hookReceiver
        let store = JSONStateStore(fileURL: SproutPaths.stateFile(projectName: config.project.name))
        self.store = store
        self.manager = ProjectStore.makeManager(
            config: config, store: store,
            shell: shell, renderer: renderer)
        self.loopbackEnabled = loopbackEnabled
        self.allocator = allocator ?? IPAllocator(fileURL: SproutPaths.loopbackFile)
        self.loopback = loopback ?? LoopbackCoordinator(provisioner: NoopLoopbackProvisioner())
    }

    private static func makeManager(
        config: Config, store: StateStore,
        shell: ShellRunner, renderer: TemplateRenderer
    ) -> WorkspaceManager {
        WorkspaceManager(
            git: GitService(shell: shell),
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

    // MARK: - Logs

    func logBuffer(branch: String, process: String) -> LogBuffer {
        let key = ProcessKey(branch: branch, name: process)
        if let b = buffers[key] { return b }
        let b = LogBuffer(id: "\(branch)#\(process)")
        buffers[key] = b
        return b
    }

    private func onLog(branch: String, process: String) -> @Sendable (LogLine) -> Void {
        let buffer = logBuffer(branch: branch, process: process)
        return { line in Task { @MainActor in buffer.append(line) } }
    }

    // MARK: - Reads

    func refresh() {
        do {
            let reconciled = try manager.reconcile()
            workspaces = reconciled.map { WorkspaceItem(record: $0.record, orphaned: $0.orphaned) }
        } catch {
            lastError = AppError(error)
        }
    }

    func runDoctor() async {
        doctor = await DoctorService(shell: shell)
            .check(tools: ["git", "createdb", "dropdb", "node"], cwd: rootURL)
    }

    func isDirty(_ item: WorkspaceItem) async -> Bool {
        (try? await GitService(shell: shell)
            .isDirty(worktree: URL(fileURLWithPath: item.record.worktreePath))) ?? false
    }

    private func context(_ rec: WorkspaceRecord, process name: String? = nil) -> TemplateContext {
        let plan = portPlan(config.run.processes)
        let own = name.flatMap { plan[$0] } ?? rec.port
        return TemplateContext(
            project: config.project.name, branch: rec.branch,
            port: own, dbName: rec.dbName, worktree: rec.worktreePath, ports: plan,
            host: rec.bindIP)
    }

    private func childEnv(_ rec: WorkspaceRecord, process name: String? = nil) -> [String: String] {
        let ctx = context(rec, process: name)
        let url = DatabaseService(shell: shell, renderer: renderer)
            .databaseURL(config.database, ctx: ctx)
        return [
            "PORT": String(ctx.port), "DATABASE_URL": url,
            "HOST": rec.bindIP, "BIND_IP": rec.bindIP,
        ]
    }

    // MARK: - Lifecycle actions

    /// Hostnames provisioned for a branch's port-binding processes.
    private func loopbackHosts(branch: String) -> [String] {
        loopbackHostnames(
            project: config.project.name, branch: branch, processes: config.run.processes)
    }

    /// URL the "Open in Browser" action opens for a workspace. With loopback on,
    /// the primary port-binding process's hostname (`<process>.<branch>.<project>.test`)
    /// at its port — the workspace binds that IP, not 127.0.0.1, so plain
    /// `localhost` would hit the wrong (or no) server. Falls back to
    /// `localhost:<port>` when the feature is off or no process binds a port.
    func browserURL(_ rec: WorkspaceRecord) -> URL? {
        guard loopbackEnabled,
            let primary = config.run.processes.first(where: { $0.port != nil })
        else {
            return URL(string: "http://localhost:\(rec.port)")
        }
        let hosts = loopbackHostnames(
            project: config.project.name, branch: rec.branch, processes: [primary])
        guard let host = hosts.first else {
            return URL(string: "http://localhost:\(rec.port)")
        }
        return URL(string: "http://\(host):\(primary.port ?? rec.port)")
    }

    // MARK: open actions

    func revealInFinder(_ item: WorkspaceItem) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: item.record.worktreePath)])
    }

    func openInEditor(_ item: WorkspaceItem) {
        let url = URL(fileURLWithPath: item.record.worktreePath)
        // Plain `open` on a directory hands it to the default folder handler (Finder).
        // Open it in VS Code when present, else fall back to the default handler.
        if let app = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.microsoft.VSCode")
        {
            NSWorkspace.shared.open(
                [url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openInBrowser(_ item: WorkspaceItem) {
        if let url = browserURL(item.record) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Refcounted provision of the branch's loopback alias + hosts (no-op when the
    /// feature is disabled). Throws if provisioning fails so the caller can abort the
    /// start before spawning a process that would bind an unconfigured IP.
    func activateLoopback(_ rec: WorkspaceRecord) async throws {
        try await activateLoopback(branch: rec.branch, ip: rec.bindIP)
    }

    /// Refcounted release of the branch's loopback alias + hosts (no-op when the
    /// feature is disabled). Never throws — stale state is reaped by the launch sweep.
    func deactivateLoopback(_ rec: WorkspaceRecord) async {
        await deactivateLoopback(branch: rec.branch, ip: rec.bindIP)
    }

    /// `create` provisions before it has a persisted record, so it works in
    /// branch/IP terms directly.
    private func activateLoopback(branch: String, ip: String) async throws {
        guard loopbackEnabled else { return }
        try await loopback.activate(branch: branch, ip: ip, hosts: loopbackHosts(branch: branch))
    }

    private func deactivateLoopback(branch: String, ip: String) async {
        guard loopbackEnabled else { return }
        await loopback.deactivate(branch: branch, ip: ip, hosts: loopbackHosts(branch: branch))
    }

    /// The bind IP for a new workspace: an allocated 127.0.10.N when the loopback
    /// feature is on, otherwise 127.0.0.1 (so disabled mode keeps today's behavior).
    func allocateBindIP(branch: String) async throws -> String {
        guard loopbackEnabled else { return "127.0.0.1" }
        return try await allocator.allocate(project: config.project.name, branch: branch)
    }

    /// Bind IPs of this project's workspaces that are actually running, for the
    /// launch sweep's "live" set. Empty when the feature is off or nothing runs.
    func runningBindIPs() -> [String] {
        guard loopbackEnabled else { return [] }
        return workspaces.filter { $0.record.status == .running }.map { $0.record.bindIP }
    }

    /// Return the branch's loopback IP slot to the allocator (no-op when disabled).
    /// Idempotent: releasing an unallocated branch is harmless.
    func releaseBindIP(branch: String) async {
        guard loopbackEnabled else { return }
        try? await allocator.release(project: config.project.name, branch: branch)
    }

    /// The planned, ordered create steps (all pending). Mirrors the phases
    /// `WorkspaceManager.create` reports, so the checklist shows every step up front.
    private func plannedCreateSteps() -> [CreateStep] {
        var steps: [CreateStep] = []
        if loopbackEnabled {
            steps.append(
                CreateStep(id: "loopback", label: "Provision loopback alias", state: .pending))
        }
        steps += [
            CreateStep(id: "worktree", label: "Create worktree", state: .pending),
            CreateStep(id: "database", label: "Provision database", state: .pending),
            CreateStep(id: "environment", label: "Link environment", state: .pending),
        ]
        steps += config.setup.map {
            CreateStep(id: "setup:\($0.name)", label: $0.name, state: .pending)
        }
        steps += config.run.processes.map {
            CreateStep(id: "process:\($0.name)", label: "Start \($0.name)", state: .pending)
        }
        return steps
    }

    private func phaseID(_ phase: CreatePhase) -> String {
        switch phase {
        case .loopback: return "loopback"
        case .worktree: return "worktree"
        case .database: return "database"
        case .environment: return "environment"
        case .setup(let name): return "setup:\(name)"
        case .process(let name): return "process:\(name)"
        }
    }

    private func updateCreateProgress(_ phase: CreatePhase, _ state: CreateStepState) {
        let id = phaseID(phase)
        if let i = createProgress.firstIndex(where: { $0.id == id }) {
            createProgress[i].state = state
        }
    }

    /// Runs `op`, throwing `CreateTimeout` if it doesn't finish within `seconds`.
    /// Guards the loopback XPC call so an unresponsive helper can't hang `create`
    /// indefinitely (it surfaces a clear error instead).
    private func withCreateTimeout<T: Sendable>(
        seconds: Double, _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CreateTimeout()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func create(base: String, branch: String) async {
        // Route each stream ("setup" + per-process) to its own buffer so the detail
        // view's per-process consoles show create-time output, not just an unseen
        // "create" buffer.
        createProgress = plannedCreateSteps()
        let onProgress: @Sendable (CreatePhase, CreateStepState) -> Void = {
            [weak self] phase, state in
            Task { @MainActor in self?.updateCreateProgress(phase, state) }
        }
        createLogTail = []
        let route: @Sendable (String, LogLine) -> Void = { [weak self] stream, line in
            Task { @MainActor in
                guard let self else { return }
                self.logBuffer(branch: branch, process: stream).append(line)
                self.createLogTail.append(line.text)
                let cap = 80
                if self.createLogTail.count > cap {
                    self.createLogTail.removeFirst(self.createLogTail.count - cap)
                }
            }
        }
        let onExit: @Sendable (String, Int32, Int32) -> Void = { [weak self] name, pid, code in
            Task { @MainActor in
                self?.handleProcessExit(branch: branch, name: name, pid: pid, code: code)
            }
        }
        do {
            let bindIP = try await allocateBindIP(branch: branch)
            // manager.create spawns the run processes bound to bindIP, so the
            // loopback alias must already be up — otherwise each binds an
            // unconfigured IP (EADDRNOTAVAIL). Provision once per process to
            // match the per-process release in handleProcessExit (alias drops on
            // the last process out). Abort the create if provisioning fails.
            let procCount = config.run.processes.count
            if loopbackEnabled {
                onProgress(.loopback, .running)
                route(
                    "setup",
                    LogLine(
                        source: .stdout,
                        text: "Provisioning loopback alias \(bindIP) via helper…"))
            }
            do {
                for _ in 0..<procCount {
                    try await withCreateTimeout(seconds: 15) { [self] in
                        try await activateLoopback(branch: branch, ip: bindIP)
                    }
                }
                if loopbackEnabled { onProgress(.loopback, .done) }
            } catch {
                if loopbackEnabled {
                    onProgress(.loopback, .failed)
                    route(
                        "setup",
                        LogLine(
                            source: .stderr,
                            text: "Loopback provisioning failed: \(error.localizedDescription)"))
                }
                await releaseBindIP(branch: branch)
                throw error
            }
            do {
                _ = try await manager.create(
                    config: config, repo: rootURL,
                    base: base, branch: branch, bindIP: bindIP, log: route,
                    onProcessExit: onExit, progress: onProgress)
            } catch {
                // manager.create rolls back and terminates any started processes
                // directly (no onProcessExit fires), so undo the activations here.
                for _ in 0..<procCount {
                    await deactivateLoopback(branch: branch, ip: bindIP)
                }
                throw error
            }
            refresh()
        } catch {
            // The workspace (and its reachable log buffers) just got rolled back,
            // so attach the captured output tail to the error — otherwise the
            // "check the logs" message points at logs the user can no longer open.
            let base = AppError(error)
            let tail = createLogTail.suffix(40).joined(separator: "\n")
            lastError =
                tail.isEmpty ? base : AppError(title: base.title, detail: tail)
        }
    }

    /// A started process exited. Flip its persisted state to `.crashed` (nonzero) or
    /// `.stopped` (clean) so the UI stops showing a dead process as running. Guarded by a
    /// pid match so a late exit from a process we already stopped or restarted is ignored.
    private func handleProcessExit(branch: String, name: String, pid: Int32, code: Int32) {
        guard var rec = try? store.load().first(where: { $0.branch == branch }),
            let i = rec.processes.firstIndex(where: { $0.name == name }),
            rec.processes[i].pid == pid
        else { return }
        rec.processes[i].status = (code == 0) ? .stopped : .crashed
        rec.processes[i].pid = nil
        rec.status = aggregateStatus(rec.processes)
        try? store.upsert(rec)
        // A genuine exit (pid matched) releases one refcount; the alias is torn down
        // on the last process out. Snapshot the record for the async release.
        let snapshot = rec
        Task { await self.deactivateLoopback(snapshot) }
        refresh()
    }

    /// Look up a process's command from config; nil if the name is unknown.
    private func command(for name: String) -> String? {
        config.run.processes.first(where: { $0.name == name })?.command
    }

    func startProcess(_ item: WorkspaceItem, name: String) async {
        guard let command = command(for: name) else { return }
        var rec = item.record
        let key = ProcessKey(branch: rec.branch, name: name)
        // terminate any existing pid for this process
        if let existing = rec.processes.first(where: { $0.name == name })?.pid {
            await PosixProcessTerminator().terminate(pid: existing, graceSeconds: 5)
        }
        // Provision the loopback alias on the first start (refcounted). Abort before
        // spawning if it fails — a process bound to an unconfigured IP would just error.
        do {
            try await activateLoopback(rec)
        } catch {
            lastError = AppError(error)
            return
        }
        let sup = ServerSupervisor(shell: shell, renderer: renderer)
        let branch = rec.branch
        let onExit: @Sendable (Int32, Int32) -> Void = { [weak self] pid, code in
            Task { @MainActor in
                self?.handleProcessExit(branch: branch, name: name, pid: pid, code: code)
            }
        }
        do {
            let pid = try await sup.start(
                command: command, ctx: context(rec, process: name),
                cwd: URL(fileURLWithPath: rec.worktreePath),
                env: childEnv(rec, process: name), onLog: onLog(branch: rec.branch, process: name),
                onExit: onExit)
            supervisors[key] = sup
            upsertProcess(&rec, ProcessState(name: name, pid: pid, status: .running))
            try store.upsert(rec)
            refresh()
        } catch {
            // Spawn failed, so no exit callback will fire to release the refcount —
            // undo the activate ourselves.
            await deactivateLoopback(rec)
            lastError = AppError(error)
        }
    }

    func stopProcess(_ item: WorkspaceItem, name: String) async {
        var rec = item.record
        let key = ProcessKey(branch: rec.branch, name: name)
        if let sup = supervisors[key] {
            await sup.stop(graceSeconds: 5)
        } else if let pid = rec.processes.first(where: { $0.name == name })?.pid {
            await PosixProcessTerminator().terminate(pid: pid, graceSeconds: 5)
        }
        supervisors[key] = nil
        upsertProcess(&rec, ProcessState(name: name, pid: nil, status: .stopped))
        try? store.upsert(rec)
        refresh()
    }

    func restartProcess(_ item: WorkspaceItem, name: String) async {
        await stopProcess(item, name: name)
        if let fresh = workspaces.first(where: { $0.id == item.id }) {
            await startProcess(fresh, name: name)
        }
    }

    func startAll(_ item: WorkspaceItem) async {
        for proc in config.run.processes {
            let current = workspaces.first(where: { $0.id == item.id }) ?? item
            await startProcess(current, name: proc.name)
        }
    }

    func stopAll(_ item: WorkspaceItem) async {
        for proc in config.run.processes {
            let current = workspaces.first(where: { $0.id == item.id }) ?? item
            await stopProcess(current, name: proc.name)
        }
    }

    // MARK: - Consoles

    /// The configured console command for a name, or nil if unknown.
    private func consoleCommand(for name: String) -> String? {
        config.run.consoles.first(where: { $0.name == name })?.command
    }

    /// The SwiftTerm-backed view controller for a running console, if any.
    func consoleController(id: UUID) -> ConsoleSessionController? {
        consoleControllers[id]
    }

    /// Start a new console session for `name` on the workspace's branch.
    func startConsole(_ item: WorkspaceItem, name: String) async {
        guard let command = consoleCommand(for: name) else { return }
        let rec = item.record
        let branch = rec.branch
        let onExit: @Sendable (UUID, Int32) -> Void = { [weak self] id, _ in
            Task { @MainActor in self?.handleConsoleExit(id: id) }
        }
        do {
            let session = try await consoleSupervisor.start(
                branch: branch, name: name, command: command,
                ctx: context(rec), cwd: URL(fileURLWithPath: rec.worktreePath),
                env: childEnv(rec), onExit: onExit)
            consoleControllers[session.id] = ConsoleSessionController(
                id: session.id, handle: session.handle)
            await refreshConsoles(branch: branch)
        } catch {
            lastError = AppError(error)
        }
    }

    // MARK: - Agents

    private func agentCommand(for name: String) -> String? {
        config.agents.first(where: { $0.name == name })?.command
    }

    /// The SwiftTerm controller for a running agent's PTY, if any.
    func agentController(id: UUID) -> ConsoleSessionController? {
        guard let consoleID = agents.first(where: { $0.id == id })?.consoleID else { return nil }
        return consoleControllers[consoleID]
    }

    /// Launch a CLI agent (`claude` by default) in the workspace's worktree. Writes
    /// the Sprout hook config into the worktree so the session reports its state
    /// back over loopback, then spawns it under a PTY (so it has a TTY and we can
    /// steer it via stdin later).
    func startAgent(_ item: WorkspaceItem, name: String) async {
        guard let command = agentCommand(for: name) else { return }
        let rec = item.record
        let branch = rec.branch
        do {
            let port = try await ensureHookReceiver()
            let token = UUID().uuidString
            try AgentHooksInstaller.install(
                worktree: URL(fileURLWithPath: rec.worktreePath), port: port, token: token)

            let onExit: @Sendable (UUID, Int32) -> Void = { [weak self] id, _ in
                Task { @MainActor in self?.handleAgentExit(consoleID: id) }
            }
            let session = try await consoleSupervisor.start(
                branch: branch, name: name, command: command,
                ctx: context(rec), cwd: URL(fileURLWithPath: rec.worktreePath),
                env: childEnv(rec), onExit: onExit)
            consoleControllers[session.id] = ConsoleSessionController(
                id: session.id, handle: session.handle)
            agents.append(
                AgentRuntime(
                    id: UUID(), branch: branch, name: name, token: token,
                    consoleID: session.id))
        } catch {
            lastError = AppError(error)
        }
    }

    /// Stop a running agent: terminate its PTY session and mark it ended. The
    /// runtime row is kept so its transition log stays readable.
    func stopAgent(id: UUID) async {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        if let consoleID = agents[i].consoleID {
            consoleControllers[consoleID]?.stop()
            consoleControllers[consoleID] = nil
            await consoleSupervisor.stop(id: consoleID)
        }
        agents[i].state = .ended
        agents[i].currentTool = nil
    }

    /// Start the loopback hook receiver once and begin consuming deliveries.
    /// Returns the bound port for building this launch's hook URL.
    private func ensureHookReceiver() async throws -> UInt16 {
        if let hookPort { return hookPort }
        let port = try await hookReceiver.start()
        hookPort = port
        // The Task inherits @MainActor from this store, so the stream and applyHook
        // are same-actor. Capture the stream weakly (no retain cycle), then re-guard
        // self each iteration.
        hookConsumer = Task { [weak self] in
            guard let stream = self?.hookReceiver.deliveries else { return }
            for await delivery in stream {
                guard let self else { return }
                self.applyHook(delivery)
            }
        }
        return port
    }

    /// Apply one hook delivery: match its token to an agent, record the transition,
    /// and advance the agent's state via the engine reducer.
    private func applyHook(_ delivery: HookDelivery) {
        guard let i = agents.firstIndex(where: { $0.token == delivery.token }) else { return }
        let event = delivery.event
        let next = AgentStateReducer.state(for: event, previous: agents[i].state)
        agents[i].sessionID = event.sessionID
        agents[i].state = next
        if event.kind == "PreToolUse" { agents[i].currentTool = event.tool }
        if event.kind == "PostToolUse" || event.kind == "PostToolUseFailure" {
            agents[i].currentTool = nil
        }
        agents[i].transitions.append(
            AgentTransition(at: Date(), kind: event.kind, tool: event.tool, state: next))
    }

    /// The agent's PTY exited (session quit or crashed): mark it ended, drop the
    /// controller. The runtime row stays so its final transition log is readable.
    private func handleAgentExit(consoleID: UUID) {
        consoleControllers[consoleID]?.stop()
        consoleControllers[consoleID] = nil
        guard let i = agents.firstIndex(where: { $0.consoleID == consoleID }) else { return }
        agents[i].state = .ended
        agents[i].currentTool = nil
    }

    /// The SwiftTerm controller for a branch's drawer shell, if a session is running.
    func shellController(branch: String) -> ConsoleSessionController? {
        shellControllers[branch]
    }

    /// Lazily start the branch's interactive drawer shell. No-op if one already runs.
    /// Runs in the worktree with the workspace's child env (PORT, DATABASE_URL).
    func openShell(_ item: WorkspaceItem) async {
        let rec = item.record
        let branch = rec.branch
        if shellControllers[branch] != nil { return }
        let onExit: @Sendable (UUID, Int32) -> Void = { [weak self] _, _ in
            Task { @MainActor in self?.handleShellExit(branch: branch) }
        }
        do {
            let session = try await consoleSupervisor.startShell(
                branch: branch, cwd: URL(fileURLWithPath: rec.worktreePath),
                env: childEnv(rec), onExit: onExit)
            shellControllers[branch] = ConsoleSessionController(
                id: session.id, handle: session.handle)
            objectWillChange.send()
        } catch {
            lastError = AppError(error)
        }
    }

    /// The shell exited (user typed `exit`/Ctrl-D, or it crashed). Drop the controller so
    /// the drawer shows its placeholder; the next `openShell` starts a fresh session.
    private func handleShellExit(branch: String) {
        shellControllers[branch]?.stop()
        shellControllers[branch] = nil
        objectWillChange.send()
    }

    func stopConsole(id: UUID) async {
        let branch = consoleSessions.first(where: { $0.id == id })?.branch
        consoleControllers[id]?.stop()
        consoleControllers[id] = nil
        await consoleSupervisor.stop(id: id)
        if let branch { await refreshConsoles(branch: branch) }
    }

    /// A console exited on its own (user typed `exit`, or it crashed). Drop its controller
    /// and refresh the list so the UI removes it.
    private func handleConsoleExit(id: UUID) {
        let branch = consoleSessions.first(where: { $0.id == id })?.branch
        consoleControllers[id]?.stop()
        consoleControllers[id] = nil
        Task { if let branch { await refreshConsoles(branch: branch) } }
    }

    /// Rebuild `consoleSessions` for one branch from the supervisor's truth, preserving
    /// sessions on other branches.
    private func refreshConsoles(branch: String) async {
        let infos = await consoleSupervisor.list(branch: branch)
        var others = consoleSessions.filter { $0.branch != branch }
        others.append(
            contentsOf: infos.map {
                ConsoleSessionItem(id: $0.id, branch: $0.branch, name: $0.name, status: $0.status)
            })
        consoleSessions = others
    }

    /// Replace (or insert) a process state by name and recompute the record's status.
    private func upsertProcess(_ rec: inout WorkspaceRecord, _ state: ProcessState) {
        if let i = rec.processes.firstIndex(where: { $0.name == state.name }) {
            rec.processes[i] = state
        } else {
            rec.processes.append(state)
        }
        rec.status = aggregateStatus(rec.processes)
    }

    func push(_ item: WorkspaceItem) async {
        do {
            try await GitService(shell: shell)
                .push(
                    worktree: URL(fileURLWithPath: item.record.worktreePath),
                    branch: item.record.branch)
        } catch {
            lastError = AppError(error)
        }
    }

    func teardown(_ item: WorkspaceItem, push: Bool, force: Bool) async {
        do {
            await consoleSupervisor.killAll(branch: item.record.branch)
            for (id, c) in consoleControllers
            where consoleSessions.contains(where: {
                $0.id == id && $0.branch == item.record.branch
            }) {
                c.stop()
                consoleControllers[id] = nil
            }
            consoleSessions = consoleSessions.filter { $0.branch != item.record.branch }
            agents.removeAll { $0.branch == item.record.branch }
            shellControllers[item.record.branch]?.stop()
            shellControllers[item.record.branch] = nil
            try await manager.teardown(
                id: item.record.id, config: config,
                repo: rootURL, push: push, force: force)
            await releaseBindIP(branch: item.record.branch)
            supervisors = supervisors.filter { $0.key.branch != item.record.branch }
            buffers = buffers.filter { $0.key.branch != item.record.branch }
            refresh()
        } catch {
            lastError = AppError(error)
        }
    }
}

# Explicit Per-Process Ports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `[port] lower/upper` range + dynamic `PortAllocator` with an explicit per-process fixed port (`port = NNNN` on each `[[run.process]]`), deleting all range/allocator machinery.

**Architecture:** `ProcessConfig` gains `port: Int?` (nil = binds no port), replacing the just-landed `bindsPort: Bool`. `PortConfig` and `Config.port` are deleted. Two free functions — `portPlan(_:)` (name→port map) and `primaryPort(_:)` (first binder or 0) — replace `PortAllocator`. Each process is launched with its own `PORT` env + `{{port}}` template value; siblings cross-reference via `{{port.<name>}}`. `WorkspaceRecord.port` keeps storing the primary port (browser-open + `.env.local`), so no on-disk migration.

**Tech Stack:** Swift 6 (strict concurrency), Swift Package (SproutEngine / sprout-cli / SproutApp), TOMLKit, Swift Testing.

**Prerequisite note (out of scope, flag to user):** Fixed ports are only collision-free if one workspace runs at a time. The single-active-workspace enforcement (Part 1 of `docs/superpowers/specs/2026-06-02-single-active-workspace-and-per-process-ports-design.md`) is a separate follow-up. This plan does the port-model cleanup only; the engine stays functional with deterministic ports.

---

## File Structure

**Engine (`Sources/SproutEngine/`)**
- `Config/Config.swift` — `ProcessConfig.port: Int?`; delete `PortConfig`; remove `Config.port`.
- `Port/PortPlan.swift` — **new**, holds `portPlan` + `primaryPort`. Replaces `PortAllocator.swift` (**deleted**).
- `Config/TOMLConfigLoader.swift` — stop reading `[port]`; read process `port` int; duplicate-port check; new `ConfigError.duplicatePort`.
- `Config/TOMLConfigWriter.swift` — stop writing `[port]`; write `port = NNNN` per process.
- `Config/TemplateRenderer.swift` — `TemplateContext.ports`; render `{{port.<name>}}`.
- `Workspace/WorkspaceManager.swift` — drop `portAllocator`; per-process port/env at launch.

**CLI (`Sources/sprout-cli/`)**
- `Sprout.swift` — drop `portAllocator`; per-process ctx/env in `server restart`.

**App (`Sources/SproutApp/`)**
- `Model/ProjectStore.swift` — drop `portAllocator`; `context`/`childEnv` take optional process name.
- `Model/ConfigDraft.swift` — drop `portLower`/`portUpper`; `ProcessRow.port`; new validation.
- `Views/ConfigFormView.swift` — remove "Port range" section; add per-process port field.
- `Views/CreateWorkspaceSheet.swift` — show planned ports instead of `auto (lower–upper)`.
- `Views/WorkspaceDetailView.swift` — inspector shows one port row per binder.

**Repo config**
- `.sprout.toml` — remove `[port]`; migrate stale `[run] server_command` to `[[run.process]]` with `port`.

**Tests (`Tests/SproutEngineTests/`)**
- `PortAllocatorTests.swift` — **deleted**.
- `PortPlanTests.swift` — **new**.
- `Support/Fixtures.swift`, `TOMLConfigLoaderTests.swift`, `TOMLConfigWriterTests.swift`, `WorkspaceManagerTests.swift`, `TemplateRendererTests.swift` — updated.

---

## Task 1: Engine core + engine tests

**Files:**
- Modify: `Sources/SproutEngine/Config/Config.swift:38-42,70-77` (delete `PortConfig`, edit `ProcessConfig`), `:3-22` (remove `port` from `Config`)
- Create: `Sources/SproutEngine/Port/PortPlan.swift`
- Delete: `Sources/SproutEngine/Port/PortAllocator.swift`
- Modify: `Sources/SproutEngine/Config/TOMLConfigLoader.swift`
- Modify: `Sources/SproutEngine/Config/TOMLConfigWriter.swift`
- Modify: `Sources/SproutEngine/Config/TemplateRenderer.swift`
- Modify: `Sources/SproutEngine/Workspace/WorkspaceManager.swift`
- Modify: `Tests/SproutEngineTests/Support/Fixtures.swift`
- Modify: `Tests/SproutEngineTests/TOMLConfigLoaderTests.swift`
- Modify: `Tests/SproutEngineTests/TOMLConfigWriterTests.swift`
- Modify: `Tests/SproutEngineTests/WorkspaceManagerTests.swift`
- Modify: `Tests/SproutEngineTests/TemplateRendererTests.swift`
- Create: `Tests/SproutEngineTests/PortPlanTests.swift`
- Delete: `Tests/SproutEngineTests/PortAllocatorTests.swift`

> This is a cross-cutting model change; the engine target only compiles once every file below is edited. Make all edits, then build + test, then commit.

- [ ] **Step 1: Edit `ProcessConfig` and delete `PortConfig` in `Config.swift`**

Replace the `PortConfig` struct (lines 38-42) — delete it entirely:

```swift
// DELETE these lines:
public struct PortConfig: Sendable {
    public var lower: Int
    public var upper: Int
    public init(lower: Int, upper: Int) { self.lower = lower; self.upper = upper }
}
```

Replace `ProcessConfig` (lines 70-77) with:

```swift
public struct ProcessConfig: Sendable, Equatable {
    public var name: String
    public var command: String  // template, long-running
    public var port: Int?  // fixed listen port; nil = process binds no port
    public init(name: String, command: String, port: Int? = nil) {
        self.name = name; self.command = command; self.port = port
    }
}
```

In the `Config` struct, remove the `port` stored property (line 6 `public var port: PortConfig`) and update the initializer (lines 13-21) to drop the `port` parameter and assignment:

```swift
public struct Config: Sendable {
    public var project: ProjectConfig
    public var worktree: WorktreeConfig
    public var env: EnvConfig
    public var database: DatabaseConfig
    public var setup: [SetupStep]
    public var run: RunConfig
    public var hooks: HooksConfig

    public init(
        project: ProjectConfig, worktree: WorktreeConfig,
        env: EnvConfig, database: DatabaseConfig, setup: [SetupStep],
        run: RunConfig, hooks: HooksConfig
    ) {
        self.project = project; self.worktree = worktree
        self.env = env; self.database = database; self.setup = setup
        self.run = run; self.hooks = hooks
    }
}
```

- [ ] **Step 2: Delete `PortAllocator.swift`, create `PortPlan.swift`**

Delete the file:

```bash
git rm Sources/SproutEngine/Port/PortAllocator.swift
```

Create `Sources/SproutEngine/Port/PortPlan.swift`:

```swift
import Foundation

/// Maps each port-binding process to its fixed listen port. Processes with a
/// nil `port` are omitted. Used to render `{{port.<name>}}` and to display the
/// per-process port assignment.
public func portPlan(_ processes: [ProcessConfig]) -> [String: Int] {
    var plan: [String: Int] = [:]
    for p in processes { if let port = p.port { plan[p.name] = port } }
    return plan
}

/// The workspace's primary port: the first process that declares one, else 0.
/// Stored on `WorkspaceRecord.port` and used for the browser-open action and the
/// single `PORT` written into `.env.local`.
public func primaryPort(_ processes: [ProcessConfig]) -> Int {
    processes.first(where: { $0.port != nil })?.port ?? 0
}
```

- [ ] **Step 3: Edit `TOMLConfigLoader.swift`**

Add a `duplicatePort` case to `ConfigError` (lines 4-7):

```swift
public enum ConfigError: Error, Equatable {
    case missingKey(String)
    case parseFailed(String)
    case duplicatePort(Int)
}
```

Remove the now-unused `int` helper (lines 32-35) and the `portT` binding (line 39 `let portT = try tbl("port")`).

In the process-parsing loop (lines 59-73), read an optional int `port` and detect duplicates:

```swift
        var processes: [ProcessConfig] = []
        var seenPorts: Set<Int> = []
        if let arr = runT?["process"]?.array {
            for entry in arr {
                guard let pt = entry.table,
                    let name = pt["name"]?.string,
                    let cmd = pt["command"]?.string
                else {
                    throw ConfigError.missingKey("run.process[].name/command")
                }
                let port = pt["port"]?.int
                if let port {
                    guard seenPorts.insert(port).inserted else {
                        throw ConfigError.duplicatePort(port)
                    }
                }
                processes.append(ProcessConfig(name: name, command: cmd, port: port))
            }
        }
```

In the final `Config(...)` return (lines 93-110), delete the `port:` argument (the two `PortConfig(...)` lines).

- [ ] **Step 4: Edit `TOMLConfigWriter.swift`**

Delete the `[port]` block (lines 18-21):

```swift
// DELETE:
        root["port"] = TOMLTable([
            "lower": config.port.lower,
            "upper": config.port.upper,
        ])
```

Update the process serialization (lines 41-47) to write an int port:

```swift
        let procs = TOMLArray()
        for p in config.run.processes {
            let t = TOMLTable(["name": p.name, "command": p.command] as [String: TOMLValueConvertible])
            if let port = p.port { t["port"] = port }
            procs.append(t)
        }
        run["process"] = procs
```

- [ ] **Step 5: Edit `TemplateRenderer.swift`**

Add `ports` to `TemplateContext` (the struct + init, lines 3-13):

```swift
public struct TemplateContext: Sendable {
    public var project: String
    public var branch: String
    public var port: Int
    public var dbName: String
    public var worktree: String
    public var ports: [String: Int]

    public init(
        project: String, branch: String, port: Int, dbName: String,
        worktree: String, ports: [String: Int] = [:]
    ) {
        self.project = project; self.branch = branch; self.port = port
        self.dbName = dbName; self.worktree = worktree; self.ports = ports
    }
```

In `render` (lines 37-49), after the existing `map` loop add sibling-port substitution:

```swift
    public func render(_ template: String, _ ctx: TemplateContext) -> String {
        var out = template
        let map: [String: String] = [
            "{{project}}": ctx.project,
            "{{branch}}": ctx.branch,
            "{{branch_slug}}": ctx.branchSlug,
            "{{port}}": String(ctx.port),
            "{{db_name}}": ctx.dbName,
            "{{worktree}}": ctx.worktree,
        ]
        for (name, p) in ctx.ports {
            out = out.replacingOccurrences(of: "{{port.\(name)}}", with: String(p))
        }
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
```

(Sibling tokens like `{{port.vite}}` are replaced before the bare `{{port}}`; the bare token never matches inside a `{{port.<name>}}` substring, but doing named-first is unambiguous.)

- [ ] **Step 6: Edit `WorkspaceManager.swift`**

Remove the `portAllocator` stored property (line 34) and its init parameter + assignment (lines 46, 51):

```swift
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
```

Update the private `context` helper (lines 57-64) to carry `ports`:

```swift
    private func context(
        config: Config, branch: String, port: Int, ports: [String: Int],
        dbName: String, worktree: String
    ) -> TemplateContext {
        TemplateContext(
            project: config.project.name, branch: branch,
            port: port, dbName: dbName, worktree: worktree, ports: ports)
    }
```

In `create`, replace the allocation + single-context block (lines 104-107) with the plan-based primary context:

```swift
            let plan = portPlan(config.run.processes)
            let port = primaryPort(config.run.processes)
            let ctx = context(
                config: config, branch: branch, port: port, ports: plan,
                dbName: dbName, worktree: worktreePath)
```

(`port` keeps its name so the later `WorkspaceRecord(... port: port ...)`, `writeLocal(... port: port ...)`, and setup `childEnv` are unchanged. Setup keeps using the primary-port `ctx`/`childEnv`.)

Replace the process-launch loop (lines 131-139) with per-process port + env:

```swift
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
```

In `rollback`, the `context(...)` call (lines 167-169) gains `ports: [:]`:

```swift
            let ctx = context(
                config: config, branch: branch, port: 0, ports: [:],
                dbName: dbName, worktree: worktreePath)
```

In `teardown`, the `context(...)` call (lines 196-198) gains `ports`:

```swift
        let ctx = context(
            config: config, branch: record.branch, port: record.port,
            ports: portPlan(config.run.processes),
            dbName: record.dbName, worktree: record.worktreePath)
```

- [ ] **Step 7: Update `Fixtures.swift`**

Replace the `config()` body (lines 6-24) — drop `port:`, give the process a port — and fix the assertion (line 31):

```swift
    static func config() -> Config {
        Config(
            project: ProjectConfig(name: "shop"),
            worktree: WorktreeConfig(baseDir: "/wt", branchPrefix: "feature/"),
            env: EnvConfig(symlinkSources: [".env"], localFile: ".env.local"),
            database: DatabaseConfig(
                createCommand: "createdb {{db_name}}",
                dropCommand: "dropdb --if-exists {{db_name}}",
                urlTemplate: "postgres://localhost/{{db_name}}"
            ),
            setup: [
                SetupStep(name: "deps", command: "npm ci"),
                SetupStep(name: "migrate", command: "npm run migrate"),
            ],
            run: RunConfig(processes: [
                ProcessConfig(name: "server", command: "npm run dev", port: 4000)
            ]),
            hooks: HooksConfig()
        )
    }
```

Replace the `fixtureConfigBuilds` assertion `#expect(c.port.lower == 4000)` (line 31) with:

```swift
    #expect(c.run.processes.first?.port == 4000)
```

- [ ] **Step 8: Update `TOMLConfigLoaderTests.swift`**

In every sample TOML string, delete the `[port]` / `lower` / `upper` lines (in `sampleTOML` lines 13-15, and in the inline TOMLs at lines 65-67, 99-101, 131-133, 181-183).

In `parsesFullConfig`, delete the two assertions `#expect(config.port.lower == 4000)` and `#expect(config.port.upper == 4010)` (lines 41-42).

Replace `roundTripsProcessPortFlag` (lines 146-164) — use the int `port`:

```swift
@Test func roundTripsProcessPort() throws {
    let config = Config(
        project: ProjectConfig(name: "shop"),
        worktree: WorktreeConfig(baseDir: "/wt", branchPrefix: "feature/"),
        env: EnvConfig(symlinkSources: [], localFile: ".env.local"),
        database: DatabaseConfig(
            createCommand: "createdb {{db_name}}",
            dropCommand: "dropdb {{db_name}}",
            urlTemplate: "postgres://localhost/{{db_name}}"),
        setup: [],
        run: RunConfig(processes: [
            ProcessConfig(name: "web", command: "bin/rails server", port: 4000),
            ProcessConfig(name: "worker", command: "bin/jobs"),
        ]),
        hooks: HooksConfig())
    let reparsed = try TOMLConfigLoader.parse(TOMLConfigWriter.serialize(config))
    #expect(reparsed.run.processes == config.run.processes)
}
```

Replace `parsesProcessPortFlag` (lines 174-202) — note `[port]` block already removed above:

```swift
@Test func parsesProcessPort() throws {
    let toml = """
        [project]
        name = "shop"
        [worktree]
        base_dir = "/wt"
        branch_prefix = "feature/"
        [env]
        symlink_sources = []
        local_file = ".env.local"
        [database]
        create_command = "createdb {{db_name}}"
        drop_command = "dropdb {{db_name}}"
        url_template = "postgres://localhost/{{db_name}}"
        [[run.process]]
        name = "web"
        command = "bin/rails server -p {{port}}"
        port = 4000
        [[run.process]]
        name = "worker"
        command = "bin/jobs"
        """
    let config = try TOMLConfigLoader.parse(toml)
    #expect(config.run.processes[0].port == 4000)
    #expect(config.run.processes[1].port == nil)
}

@Test func rejectsDuplicateProcessPorts() {
    let toml = """
        [project]
        name = "shop"
        [worktree]
        base_dir = "/wt"
        branch_prefix = "feature/"
        [env]
        symlink_sources = []
        local_file = ".env.local"
        [database]
        create_command = "createdb {{db_name}}"
        drop_command = "dropdb {{db_name}}"
        url_template = "postgres://localhost/{{db_name}}"
        [[run.process]]
        name = "web"
        command = "a"
        port = 4000
        [[run.process]]
        name = "api"
        command = "b"
        port = 4000
        """
    #expect(throws: ConfigError.duplicatePort(4000)) { _ = try TOMLConfigLoader.parse(toml) }
}
```

- [ ] **Step 9: Update `TOMLConfigWriterTests.swift`**

In `roundTripsThroughParse`, delete the two port assertions `#expect(parsed.port.lower == original.port.lower)` and `#expect(parsed.port.upper == original.port.upper)` (lines 14-15).

In `roundTripsConsoles`, remove the `port:` argument from the `Config(...)` initializer (delete the `PortConfig(lower: 4000, upper: 4050)` line, lines 42).

- [ ] **Step 10: Update `WorkspaceManagerTests.swift`**

Replace the `makeManager` helper (lines 12-33) — drop the `prober` parameter and `portAllocator`:

```swift
private func makeManager(
    shell: FakeShellRunner, store: FakeStateStore,
    fs: FakeFileSystem = FakeFileSystem(),
    checker: ProcessChecker = AliveChecker(alive: []),
    terminator: FakeProcessTerminator = FakeProcessTerminator()
)
    -> WorkspaceManager
{
    let renderer = TemplateRenderer()
    return WorkspaceManager(
        git: GitService(shell: shell),
        database: DatabaseService(shell: shell, renderer: renderer),
        envLinker: EnvLinker(fs: fs), fs: fs,
        setupRunner: SetupRunner(shell: shell, renderer: renderer),
        store: store, checker: checker, terminator: terminator,
        renderer: renderer, shell: shell
    )
}
```

Delete the `FreeProber` struct (line 35) and the `StubProber`-free helper references. Remove every `prober:` argument from `makeManager(...)` calls in this file (lines 42, 65, 86, 117, 137, 170, 195, 219, 236-238, 250-252, 263-265 — each `prober: FreeProber()` token is deleted; where it is the only remaining trailing arg after `store:`/`fs:`, just drop it).

Concretely the call sites become, e.g.:

```swift
    let mgr = makeManager(shell: shell, store: store, fs: fs)
```
```swift
    let mgr = makeManager(shell: shell, store: store)
```
```swift
    let mgr = makeManager(shell: shell, store: store, prober: FreeProber(), terminator: term)
    // becomes:
    let mgr = makeManager(shell: shell, store: store, terminator: term)
```
```swift
    let mgr = makeManager(
        shell: shell, store: store, fs: fs, checker: AliveChecker(alive: []))
```

`createPersistsRunningRecordWithPortAndDB` still asserts `rec.port == 4000`; the Fixtures process now declares `port: 4000`, so `primaryPort` returns 4000 — assertion holds unchanged.

- [ ] **Step 11: Update `TemplateRendererTests.swift`**

Add a test for own-port and sibling-port rendering (append after `renderReplacesAllVariables`, line 34):

```swift
@Test func renderResolvesOwnAndSiblingPorts() {
    let ctx = TemplateContext(
        project: "shop", branch: "main", port: 4000,
        dbName: "shop", worktree: "/wt", ports: ["web": 4000, "vite": 4001])
    let r = TemplateRenderer()
    #expect(r.render("-p {{port}}", ctx) == "-p 4000")
    #expect(r.render("VITE={{port.vite}} WEB={{port.web}}", ctx) == "VITE=4001 WEB=4000")
}
```

- [ ] **Step 12: Delete `PortAllocatorTests.swift`, create `PortPlanTests.swift`**

```bash
git rm Tests/SproutEngineTests/PortAllocatorTests.swift
```

Create `Tests/SproutEngineTests/PortPlanTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

@Test func portPlanMapsOnlyBinders() {
    let procs = [
        ProcessConfig(name: "web", command: "a", port: 4000),
        ProcessConfig(name: "vite", command: "b", port: 4001),
        ProcessConfig(name: "worker", command: "c"),
    ]
    #expect(portPlan(procs) == ["web": 4000, "vite": 4001])
}

@Test func primaryPortIsFirstBinder() {
    let procs = [
        ProcessConfig(name: "worker", command: "c"),
        ProcessConfig(name: "web", command: "a", port: 4000),
        ProcessConfig(name: "vite", command: "b", port: 4001),
    ]
    #expect(primaryPort(procs) == 4000)
}

@Test func primaryPortZeroWhenNoBinders() {
    let procs = [ProcessConfig(name: "worker", command: "c")]
    #expect(primaryPort(procs) == 0)
    #expect(portPlan(procs).isEmpty)
}
```

- [ ] **Step 13: Build + test the engine**

Run: `swift build`
Expected: `Build complete!` with no warnings.

Run: `swift test`
Expected: all tests PASS (full suite, ~50 tests). No `PortAllocatorTests`; `PortPlanTests` present.

- [ ] **Step 14: Lint**

Run: `swift format lint -r Sources Tests`
Expected: no output (clean).

- [ ] **Step 15: Commit**

```bash
git add Sources/SproutEngine Tests/SproutEngineTests
git commit -m "feat: explicit per-process fixed ports, drop port range + allocator"
```

---

## Task 2: CLI (`sprout-cli`)

**Files:**
- Modify: `Sources/sprout-cli/Sprout.swift:17-32` (makeManager), `:98-138` (Server.run)

- [ ] **Step 1: Drop `portAllocator` from `makeManager`**

Replace `makeManager` (lines 17-32):

```swift
private func makeManager(config: Config, store: StateStore) -> WorkspaceManager {
    let shell = LoginShellRunner()
    let renderer = TemplateRenderer()
    return WorkspaceManager(
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
```

- [ ] **Step 2: Per-process ctx/env in `Server.run`**

In `Server.run`, delete the shared `ctx` (lines 100-102) and `env` (lines 104-108) and the `wt` line stays. Replace the body from the `let wt = ...` line through the per-target loop (lines 103-133) with:

```swift
        let wt = URL(fileURLWithPath: rec.worktreePath)
        let plan = portPlan(config.run.processes)

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
                let ownPort = proc.port ?? rec.port
                let ctx = TemplateContext(
                    project: config.project.name, branch: rec.branch,
                    port: ownPort, dbName: rec.dbName, worktree: rec.worktreePath, ports: plan)
                let env = [
                    "PORT": String(ownPort),
                    "DATABASE_URL": DatabaseService(shell: shell, renderer: renderer)
                        .databaseURL(config.database, ctx: ctx),
                ]
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
```

(The `shell` and `renderer` locals declared at lines 98-99 remain in use.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!` no warnings.

- [ ] **Step 4: Commit**

```bash
git add Sources/sprout-cli/Sprout.swift
git commit -m "feat: per-process ports in sprout-cli server restart"
```

---

## Task 3: App (SproutApp)

**Files:**
- Modify: `Sources/SproutApp/Model/ProjectStore.swift:62-79` (makeManager), `:117-127` (context/childEnv), `:189-193` (startProcess call)
- Modify: `Sources/SproutApp/Model/ConfigDraft.swift`
- Modify: `Sources/SproutApp/Views/ConfigFormView.swift:112-115` (remove section), `:150-171` (process rows)
- Modify: `Sources/SproutApp/Views/CreateWorkspaceSheet.swift:28-30`
- Modify: `Sources/SproutApp/Views/WorkspaceDetailView.swift:105-110`

- [ ] **Step 1: `ProjectStore.makeManager` drop allocator**

In `makeManager` (lines 66-78), delete the `portAllocator:` argument block:

```swift
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
```

- [ ] **Step 2: `context`/`childEnv` take optional process name**

Replace `context` (lines 117-121) and `childEnv` (lines 123-127):

```swift
    private func context(_ rec: WorkspaceRecord, process name: String? = nil) -> TemplateContext {
        let plan = portPlan(config.run.processes)
        let own = name.flatMap { plan[$0] } ?? rec.port
        return TemplateContext(
            project: config.project.name, branch: rec.branch,
            port: own, dbName: rec.dbName, worktree: rec.worktreePath, ports: plan)
    }

    private func childEnv(_ rec: WorkspaceRecord, process name: String? = nil) -> [String: String] {
        let ctx = context(rec, process: name)
        let url = DatabaseService(shell: shell, renderer: renderer)
            .databaseURL(config.database, ctx: ctx)
        return ["PORT": String(ctx.port), "DATABASE_URL": url]
    }
```

- [ ] **Step 3: `startProcess` passes the process name**

In `startProcess`, update the `sup.start(...)` call (lines 189-193):

```swift
            let pid = try await sup.start(
                command: command, ctx: context(rec, process: name),
                cwd: URL(fileURLWithPath: rec.worktreePath),
                env: childEnv(rec, process: name), onLog: onLog(branch: rec.branch, process: name),
                onExit: onExit)
```

(`startConsole` keeps `context(rec)` / `childEnv(rec)` — consoles bind no port, so they take the primary; no change there.)

- [ ] **Step 4: `ConfigDraft` — drop port range, add per-process port**

In `ProcessRow` (lines 18-22) add `port`:

```swift
    struct ProcessRow: Identifiable {
        let id = UUID()
        var name: String
        var command: String
        var port: String
    }
```

Delete the `@Published var portLower` / `portUpper` properties (lines 27-28).

In `init(_:)` delete the `portLower`/`portUpper` lines (45-46) and map the new port field (line 53):

```swift
        processes = c.run.processes.map {
            ProcessRow(name: $0.name, command: $0.command, port: $0.port.map(String.init) ?? "")
        }
```

In `template()` (lines 61-73) delete the `port: PortConfig(lower: 3000, upper: 3020),` line:

```swift
    static func template() -> ConfigDraft {
        ConfigDraft(
            Config(
                project: ProjectConfig(name: ""),
                worktree: WorktreeConfig(baseDir: "../worktrees", branchPrefix: "feature/"),
                env: EnvConfig(symlinkSources: [], localFile: ".env.local"),
                database: DatabaseConfig(
                    createCommand: "createdb {{db_name}}",
                    dropCommand: "dropdb --if-exists {{db_name}}",
                    urlTemplate: "postgres://localhost/{{db_name}}"),
                setup: [],
                run: RunConfig(processes: []),
                hooks: HooksConfig()))
    }
```

In `build()` delete the port-bound parsing + guard (lines 84-90), and replace the process mapping (lines 102-108) to parse the optional int port:

```swift
        let procs = try processes.compactMap { row -> ProcessConfig? in
            let n = row.name.trimmingCharacters(in: .whitespaces)
            let c = row.command.trimmingCharacters(in: .whitespaces)
            let pStr = row.port.trimmingCharacters(in: .whitespaces)
            if n.isEmpty, c.isEmpty, pStr.isEmpty { return nil }  // drop fully-blank rows
            guard !n.isEmpty, !c.isEmpty else { throw DraftError.incompleteProcess }
            var port: Int? = nil
            if !pStr.isEmpty {
                guard let v = Int(pStr) else { throw DraftError.notAnInt("Port for \(n)") }
                port = v
            }
            return ProcessConfig(name: n, command: c, port: port)
        }
```

In the returned `Config(...)` (lines 115-126) delete the `port: PortConfig(lower: lower, upper: upper),` line.

In `DraftError` (lines 129-145) delete the `case portRange` and its `errorDescription` arm (keep `notAnInt`, now used for process ports):

```swift
enum DraftError: LocalizedError {
    case empty(String)
    case notAnInt(String)
    case incompleteStep
    case incompleteProcess

    var errorDescription: String? {
        switch self {
        case .empty(let field): return "\(field) cannot be empty."
        case .notAnInt(let field): return "\(field) must be a whole number."
        case .incompleteStep: return "Every setup step needs both a name and a command."
        case .incompleteProcess: return "Every run process needs both a name and a command."
        }
    }
}
```

- [ ] **Step 5: `ConfigFormView` — remove Port range section, add port field**

Delete the "Port range" `Section` in `basicTab` (lines 112-115):

```swift
// DELETE:
            Section("Port range") {
                TextField("Lower", text: $draft.portLower)
                TextField("Upper", text: $draft.portUpper)
            }
```

In the "Run processes" section, add a port field to each row (inside the `ForEach($draft.processes)` HStack, lines 151-164):

```swift
                ForEach($draft.processes) { $proc in
                    HStack {
                        TextField("name", text: $proc.name)
                            .frame(width: 110)
                        TextField("command", text: $proc.command)
                            .font(.callout.monospaced())
                        TextField("port", text: $proc.port)
                            .frame(width: 60)
                        Button(role: .destructive) {
                            removeProcess(proc.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove process")
                    }
                }
```

- [ ] **Step 6: `CreateWorkspaceSheet` — show planned ports**

Replace the `LabeledContent("Port", ...)` (lines 28-30) with:

```swift
                LabeledContent("Ports", value: portSummary)
```

Add a computed property to the view (near `dbPreview`/`worktreePreview`):

```swift
    private var portSummary: String {
        let plan = portPlan(project.config.run.processes)
        if plan.isEmpty { return "none" }
        return plan.sorted { $0.value < $1.value }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "  ")
    }
```

- [ ] **Step 7: `WorkspaceDetailView` — per-binder port rows**

Replace the single port `field` line in `inspector` (line 106) with plan-derived rows:

```swift
            Section {
                portRows
                field("Database", rec.dbName)
                field("Branch", rec.branch)
                field("Worktree", rec.worktreePath)
            }
```

Add a `@ViewBuilder` property to the view:

```swift
    @ViewBuilder private var portRows: some View {
        let plan = portPlan(project.config.run.processes)
        if plan.isEmpty {
            field("Port", "none")
        } else {
            ForEach(plan.sorted { $0.value < $1.value }, id: \.key) { name, port in
                field(name, ":\(port)")
            }
        }
    }
```

(`openInBrowser` at line 334 keeps using `rec.port` — the primary port — unchanged.)

- [ ] **Step 8: Build the app**

Run: `swift build`
Expected: `Build complete!` no warnings.

- [ ] **Step 9: Lint**

Run: `swift format lint -r Sources Tests`
Expected: no output.

- [ ] **Step 10: Commit**

```bash
git add Sources/SproutApp
git commit -m "feat: per-process ports in app model, config form, and detail view"
```

---

## Task 4: Repo config + final verification

**Files:**
- Modify: `.sprout.toml`

- [ ] **Step 1: Migrate `.sprout.toml`**

The repo's own config still uses the dropped `[port]` table and the long-removed `[run] server_command`. Replace lines 8-10 (the `[port]` block) by deleting them, and replace the `[run]` block (lines 29-31) with a process declaring a port:

```toml
[run]

[[run.process]]
name = "server"
command = "npm run dev -- --port {{port}}"
port = 4000
```

(Delete the `[port]` / `lower` / `upper` lines entirely. The file no longer has a `[port]` table.)

- [ ] **Step 2: Verify the repo config loads**

Run: `swift run sprout doctor`
Expected: tool checks print; no `ConfigError` / parse failure (the migrated `.sprout.toml` loads cleanly).

- [ ] **Step 3: Full build + test + lint**

Run: `swift build && swift test && swift format lint -r Sources Tests`
Expected: build clean, all tests PASS, lint silent.

- [ ] **Step 4: Manual app smoke test**

Run: `swift run SproutApp`
Expected: app launches; the config form's Run-processes rows show a port field; the create sheet shows `Ports  server:4000`. Quit the app.

- [ ] **Step 5: Commit**

```bash
git add .sprout.toml
git commit -m "chore: migrate .sprout.toml to per-process port"
```

---

## Self-Review Notes

- **Spec coverage:** explicit `port: Int?` (Task 1.1), `portPlan`/`primaryPort` replacing allocator (1.2), `{{port.<name>}}` sibling refs (1.5), per-process `PORT`/`{{port}}` at launch (1.6), allocator deletion across engine/CLI/app (1.2/2.1/3.1), inspector per-binder rows (3.7), duplicate-port guard as a config boundary check (1.3). The single-active-workspace concern is explicitly deferred (header note).
- **No leftover `PortConfig` / `PortAllocator` / `bindsPort` references:** after Task 3, grep `port\.lower|port\.upper|PortConfig|PortAllocator|bindsPort|BindPortProber|PortProber` should return only doc/spec files. Verify during execution.
- **Type consistency:** `portPlan(_ processes: [ProcessConfig]) -> [String: Int]` and `primaryPort(_:)` signatures are used identically in engine, CLI, and app. `TemplateContext.ports` defaulted to `[:]` so existing constructions compile.
- **No on-disk migration:** `WorkspaceRecord.port: Int` is untouched; it now stores the primary port.

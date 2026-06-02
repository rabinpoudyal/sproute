# Single Active Workspace & Per-Process Ports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce one running workspace per project (starting/creating a workspace stops the others' processes and consoles) and give each port-binding process its own deterministic, shared-across-workspaces port.

**Architecture:** A new `port = true` flag on `[[run.process]]` marks port binders. A pure engine helper `makePortPlan(config)` maps each binder to `port.lower + index` (declaration order); the first binder's port is the "primary". `TemplateContext` carries the full name→port map so `{{port}}` (own port) and `{{port.<name>}}` (sibling) both render. `WorkspaceManager.create` launches each process with its own port context/`PORT`; the dynamic `PortAllocator` is removed. `ProjectStore.stopOthers(exceptBranch:)` runs before any start/create to guarantee a single active workspace.

**Tech Stack:** Swift 6 (strict concurrency), Swift Package Manager, Swift Testing (`import Testing`, `@Test`, `#expect`), TOMLKit, SwiftUI (macOS).

---

## File Structure

**Engine (`Sources/SproutEngine/`):**
- `Config/Config.swift` — add `bindsPort` to `ProcessConfig`.
- `Config/TOMLConfigLoader.swift` — parse `port` bool; add `ConfigError.tooManyPorts`.
- `Config/TOMLConfigWriter.swift` — emit `port = true` when set.
- `Config/TemplateRenderer.swift` — `TemplateContext.ports`; render `{{port.<name>}}`.
- `Port/PortPlan.swift` — **new.** `PortPlan` + `makePortPlan(_:)`.
- `Port/PortAllocator.swift` — **deleted.**
- `Workspace/WorkspaceManager.swift` — drop `portAllocator`; fixed ports; per-process launch context.

**CLI (`Sources/sprout-cli/`):**
- `Sprout.swift` — stop constructing `PortAllocator`.

**App (`Sources/SproutApp/`):**
- `Model/ProjectStore.swift` — per-process `context`/`childEnv`; `stopOthers`; expose `portPlan`.
- `Model/ConfigDraft.swift` — `ProcessRow.bindsPort`; carry through `build()`.
- `Views/ConfigFormView.swift` — per-process port toggle.
- `Views/WorkspaceDetailView.swift` — inspector shows one row per port.

**Tests (`Tests/SproutEngineTests/`):**
- `TOMLConfigLoaderTests.swift` — `port = true` parse + round-trip.
- `PortPlanTests.swift` — **new.**
- `TemplateRendererTests.swift` — named ports.
- `WorkspaceManagerTests.swift` — new constructor; per-process ports.
- `PortAllocatorTests.swift` — **deleted.**

---

## Task 1: Add `bindsPort` to `ProcessConfig` and parse `port` flag

**Files:**
- Modify: `Sources/SproutEngine/Config/Config.swift:70-74`
- Modify: `Sources/SproutEngine/Config/TOMLConfigLoader.swift:59-70`
- Test: `Tests/SproutEngineTests/TOMLConfigLoaderTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/SproutEngineTests/TOMLConfigLoaderTests.swift`:

```swift
@Test func parsesProcessPortFlag() throws {
    let toml = """
        [project]
        name = "shop"
        [worktree]
        base_dir = "/wt"
        branch_prefix = "feature/"
        [port]
        lower = 4000
        upper = 4010
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
        port = true
        [[run.process]]
        name = "worker"
        command = "bin/jobs"
        """
    let config = try TOMLConfigLoader.parse(toml)
    #expect(config.run.processes[0].bindsPort == true)
    #expect(config.run.processes[1].bindsPort == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter parsesProcessPortFlag`
Expected: FAIL — `value of type 'ProcessConfig' has no member 'bindsPort'` (compile error).

- [ ] **Step 3: Add the property to `ProcessConfig`**

Replace `Sources/SproutEngine/Config/Config.swift:70-74` with:

```swift
public struct ProcessConfig: Sendable, Equatable {
    public var name: String
    public var command: String  // template, long-running
    public var bindsPort: Bool  // process binds a listen port; gets its own port
    public init(name: String, command: String, bindsPort: Bool = false) {
        self.name = name; self.command = command; self.bindsPort = bindsPort
    }
}
```

- [ ] **Step 4: Parse the flag in the loader**

In `Sources/SproutEngine/Config/TOMLConfigLoader.swift`, replace the process-parsing loop (lines 59-70) with:

```swift
        var processes: [ProcessConfig] = []
        if let arr = runT?["process"]?.array {
            for entry in arr {
                guard let pt = entry.table,
                    let name = pt["name"]?.string,
                    let cmd = pt["command"]?.string
                else {
                    throw ConfigError.missingKey("run.process[].name/command")
                }
                processes.append(
                    ProcessConfig(
                        name: name, command: cmd,
                        bindsPort: pt["port"]?.bool ?? false))
            }
        }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter parsesProcessPortFlag`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutEngine/Config/Config.swift Sources/SproutEngine/Config/TOMLConfigLoader.swift Tests/SproutEngineTests/TOMLConfigLoaderTests.swift
git commit -m "feat: parse per-process port flag in config"
```

---

## Task 2: Emit `port = true` from the writer (round-trip)

**Files:**
- Modify: `Sources/SproutEngine/Config/TOMLConfigWriter.swift:41-45`
- Test: `Tests/SproutEngineTests/TOMLConfigLoaderTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/SproutEngineTests/TOMLConfigLoaderTests.swift`:

```swift
@Test func roundTripsProcessPortFlag() throws {
    let config = Config(
        project: ProjectConfig(name: "shop"),
        worktree: WorktreeConfig(baseDir: "/wt", branchPrefix: "feature/"),
        port: PortConfig(lower: 4000, upper: 4010),
        env: EnvConfig(symlinkSources: [], localFile: ".env.local"),
        database: DatabaseConfig(
            createCommand: "createdb {{db_name}}",
            dropCommand: "dropdb {{db_name}}",
            urlTemplate: "postgres://localhost/{{db_name}}"),
        setup: [],
        run: RunConfig(processes: [
            ProcessConfig(name: "web", command: "bin/rails server", bindsPort: true),
            ProcessConfig(name: "worker", command: "bin/jobs", bindsPort: false),
        ]),
        hooks: HooksConfig())
    let reparsed = try TOMLConfigLoader.parse(TOMLConfigWriter.serialize(config))
    #expect(reparsed.run.processes == config.run.processes)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter roundTripsProcessPortFlag`
Expected: FAIL — `bindsPort` lost on serialize, so `reparsed.run.processes != config.run.processes` (the `web` row comes back with `bindsPort == false`).

- [ ] **Step 3: Emit the flag**

In `Sources/SproutEngine/Config/TOMLConfigWriter.swift`, replace the process loop (lines 41-45) with:

```swift
        let procs = TOMLArray()
        for p in config.run.processes {
            let t = TOMLTable(["name": p.name, "command": p.command])
            if p.bindsPort { t["port"] = true }
            procs.append(t)
        }
        run["process"] = procs
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter roundTripsProcessPortFlag`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Config/TOMLConfigWriter.swift Tests/SproutEngineTests/TOMLConfigLoaderTests.swift
git commit -m "feat: serialize per-process port flag"
```

---

## Task 3: `PortPlan` helper

**Files:**
- Create: `Sources/SproutEngine/Port/PortPlan.swift`
- Modify: `Sources/SproutEngine/Config/TOMLConfigLoader.swift:4-7` (add `ConfigError` case)
- Test: `Tests/SproutEngineTests/PortPlanTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SproutEngineTests/PortPlanTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

private func config(_ procs: [ProcessConfig], lower: Int = 4000, upper: Int = 4010) -> Config {
    Config(
        project: ProjectConfig(name: "shop"),
        worktree: WorktreeConfig(baseDir: "/wt", branchPrefix: "feature/"),
        port: PortConfig(lower: lower, upper: upper),
        env: EnvConfig(symlinkSources: [], localFile: ".env.local"),
        database: DatabaseConfig(
            createCommand: "c", dropCommand: "d", urlTemplate: "u"),
        setup: [],
        run: RunConfig(processes: procs),
        hooks: HooksConfig())
}

@Test func assignsPortsByDeclarationOrder() throws {
    let plan = try makePortPlan(
        config([
            ProcessConfig(name: "web", command: "x", bindsPort: true),
            ProcessConfig(name: "worker", command: "y", bindsPort: false),
            ProcessConfig(name: "vite", command: "z", bindsPort: true),
        ]))
    #expect(plan.byName == ["web": 4000, "vite": 4001])
    #expect(plan.primary == 4000)
}

@Test func primaryFallsBackToLowerWhenNoBinders() throws {
    let plan = try makePortPlan(
        config([ProcessConfig(name: "worker", command: "y", bindsPort: false)]))
    #expect(plan.byName.isEmpty)
    #expect(plan.primary == 4000)
}

@Test func throwsWhenBindersExceedRange() {
    let procs = (0..<3).map { ProcessConfig(name: "p\($0)", command: "x", bindsPort: true) }
    #expect(throws: ConfigError.self) {
        _ = try makePortPlan(config(procs, lower: 4000, upper: 4001))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PortPlanTests`
Expected: FAIL — `cannot find 'makePortPlan' in scope`.

- [ ] **Step 3: Add the `ConfigError` case**

Replace `Sources/SproutEngine/Config/TOMLConfigLoader.swift:4-7` with:

```swift
public enum ConfigError: Error, Equatable {
    case missingKey(String)
    case parseFailed(String)
    case tooManyPorts(needed: Int, available: Int)
}
```

- [ ] **Step 4: Implement `PortPlan`**

Create `Sources/SproutEngine/Port/PortPlan.swift`:

```swift
import Foundation

/// Deterministic port assignment for a project's port-binding processes.
/// Because only one workspace per project runs at a time, ports are fixed and
/// shared across every workspace: the i-th port-binding process (in declaration
/// order) listens on `config.port.lower + i`.
public struct PortPlan: Sendable, Equatable {
    /// Process name → its dedicated port. Only port-binding processes appear.
    public let byName: [String: Int]
    /// Port used for the workspace headline (browser, `.env`): the first binder,
    /// or `config.port.lower` when no process binds a port.
    public let primary: Int

    public init(byName: [String: Int], primary: Int) {
        self.byName = byName
        self.primary = primary
    }
}

/// Builds the plan from config. Throws `ConfigError.tooManyPorts` when more
/// processes bind ports than the `[port]` range can fit.
public func makePortPlan(_ config: Config) throws -> PortPlan {
    let binders = config.run.processes.filter(\.bindsPort)
    let available = config.port.upper - config.port.lower + 1
    guard binders.count <= available else {
        throw ConfigError.tooManyPorts(needed: binders.count, available: available)
    }
    var byName: [String: Int] = [:]
    for (i, proc) in binders.enumerated() {
        byName[proc.name] = config.port.lower + i
    }
    let primary = binders.first.flatMap { byName[$0.name] } ?? config.port.lower
    return PortPlan(byName: byName, primary: primary)
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter PortPlanTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutEngine/Port/PortPlan.swift Sources/SproutEngine/Config/TOMLConfigLoader.swift Tests/SproutEngineTests/PortPlanTests.swift
git commit -m "feat: deterministic per-process PortPlan"
```

---

## Task 4: Named ports in `TemplateContext` / `TemplateRenderer`

**Files:**
- Modify: `Sources/SproutEngine/Config/TemplateRenderer.swift:3-49`
- Test: `Tests/SproutEngineTests/TemplateRendererTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/SproutEngineTests/TemplateRendererTests.swift`:

```swift
@Test func renderResolvesNamedPorts() {
    let ctx = TemplateContext(
        project: "shop", branch: "f", port: 4000,
        dbName: "shop_f", worktree: "/wt", ports: ["web": 4000, "vite": 4001])
    let r = TemplateRenderer()
    #expect(r.render("self={{port}} vite={{port.vite}}", ctx) == "self=4000 vite=4001")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter renderResolvesNamedPorts`
Expected: FAIL — `TemplateContext` has no `ports:` parameter (compile error).

- [ ] **Step 3: Add `ports` and render named entries**

In `Sources/SproutEngine/Config/TemplateRenderer.swift`, replace the `TemplateContext` struct's stored properties + init (lines 4-13) with:

```swift
    public var project: String
    public var branch: String
    public var port: Int
    public var dbName: String
    public var worktree: String
    /// All port-binding processes by name, for `{{port.<name>}}` references.
    public var ports: [String: Int]

    public init(
        project: String, branch: String, port: Int, dbName: String, worktree: String,
        ports: [String: Int] = [:]
    ) {
        self.project = project; self.branch = branch; self.port = port
        self.dbName = dbName; self.worktree = worktree; self.ports = ports
    }
```

Then in `TemplateRenderer.render` (lines 37-49), replace the body with:

```swift
    public func render(_ template: String, _ ctx: TemplateContext) -> String {
        var out = template
        var map: [String: String] = [
            "{{project}}": ctx.project,
            "{{branch}}": ctx.branch,
            "{{branch_slug}}": ctx.branchSlug,
            "{{port}}": String(ctx.port),
            "{{db_name}}": ctx.dbName,
            "{{worktree}}": ctx.worktree,
        ]
        for (name, port) in ctx.ports {
            map["{{port.\(name)}}"] = String(port)
        }
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter renderResolvesNamedPorts`
Expected: PASS. Also run `swift test --filter renderReplacesAllVariables` — Expected: PASS (default `ports: [:]` keeps it working).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Config/TemplateRenderer.swift Tests/SproutEngineTests/TemplateRendererTests.swift
git commit -m "feat: named port template vars"
```

---

## Task 5: Remove `PortAllocator`; fix ports in `WorkspaceManager.create`

**Files:**
- Delete: `Sources/SproutEngine/Port/PortAllocator.swift`
- Delete: `Tests/SproutEngineTests/PortAllocatorTests.swift`
- Modify: `Sources/SproutEngine/Workspace/WorkspaceManager.swift` (constructor + `create` + `context`)
- Modify: `Tests/SproutEngineTests/WorkspaceManagerTests.swift:11-32` (`makeManager`)
- Modify: `Sources/sprout-cli/Sprout.swift:22`

- [ ] **Step 1: Update the failing test first (drives the new constructor)**

In `Tests/SproutEngineTests/WorkspaceManagerTests.swift`, replace the `makeManager` helper (lines 11-32) with (drops `prober` param and the `portAllocator` argument):

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

Then delete the now-unused `FreeProber` struct (the line `private struct FreeProber: PortProber { func isFree(_ port: Int) -> Bool { true } }`) and remove the `prober:` argument from every `makeManager(...)` call site in this file (e.g. `makeManager(shell: shell, store: store, fs: fs, prober: FreeProber())` becomes `makeManager(shell: shell, store: store, fs: fs)`).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter createPersistsRunningRecordWithPortAndDB`
Expected: FAIL — compile error: `WorkspaceManager` still has a `portAllocator` parameter / `PortProber` referenced.

- [ ] **Step 3: Delete `PortAllocator` and update `WorkspaceManager`**

Delete the files:

```bash
git rm Sources/SproutEngine/Port/PortAllocator.swift Tests/SproutEngineTests/PortAllocatorTests.swift
```

In `Sources/SproutEngine/Workspace/WorkspaceManager.swift`:

(a) Remove the stored property `let portAllocator: PortAllocator` (line 34) and the `portAllocator: PortAllocator,` init parameter (line 46) and its assignment `self.portAllocator = portAllocator` (in the init body, line 51).

(b) Replace the `context` helper (lines 57-64) to thread `ports`:

```swift
    private func context(
        config: Config, branch: String, port: Int,
        dbName: String, worktree: String, ports: [String: Int] = [:]
    ) -> TemplateContext {
        TemplateContext(
            project: config.project.name, branch: branch,
            port: port, dbName: dbName, worktree: worktree, ports: ports)
    }
```

(c) In `create`, replace the allocation + single-context section. Replace lines 104-118 (`let port = try portAllocator.allocate()` through the `writeLocal(...)` call) with:

```swift
            let plan = try makePortPlan(config)
            let port = plan.primary
            let ctx = context(
                config: config, branch: branch, port: port,
                dbName: dbName, worktree: worktreePath, ports: plan.byName)

            try await database.create(config.database, ctx: ctx, cwd: repo)
            didDB = true

            try envLinker.link(
                sources: config.env.symlinkSources,
                primaryRepo: repo, worktree: worktreeURL)
            let dbURL = database.databaseURL(config.database, ctx: ctx)
            try envLinker.writeLocal(
                file: config.env.localFile, worktree: worktreeURL,
                port: port, databaseURL: dbURL)
```

(d) Replace the process-launch loop (lines 131-139) so each process gets its own port + `PORT`:

```swift
            for proc in config.run.processes {
                let supervisor = ServerSupervisor(shell: shell, renderer: renderer)
                let name = proc.name
                let procPort = plan.byName[name] ?? port
                let procCtx = context(
                    config: config, branch: branch, port: procPort,
                    dbName: dbName, worktree: worktreePath, ports: plan.byName)
                let procEnv = ["PORT": String(procPort), "DATABASE_URL": dbURL]
                let pid = try await supervisor.start(
                    command: proc.command, ctx: procCtx,
                    cwd: worktreeURL, env: procEnv, onLog: { log(name, $0) },
                    onExit: { pid, code in onProcessExit(name, pid, code) })
                startedProcesses.append(ProcessState(name: proc.name, pid: pid, status: .running))
            }
```

Note: the `let childEnv = ["PORT": String(port), "DATABASE_URL": dbURL]` on line 126 is still used by `setupRunner.run` below it — leave that line and the setup call as-is (setup uses the primary port).

- [ ] **Step 4: Update the CLI**

In `Sources/sprout-cli/Sprout.swift`, remove the `portAllocator:` argument (line 22). Delete the whole line:

```swift
        portAllocator: PortAllocator(config: config.port, store: store, prober: BindPortProber()),
```

- [ ] **Step 5: Update `ProjectStore.makeManager` (compile dependency)**

In `Sources/SproutApp/Model/ProjectStore.swift`, remove the `portAllocator:` argument from `makeManager` (lines 67-69). Delete:

```swift
            portAllocator: PortAllocator(
                config: config.port, store: store, prober: BindPortProber()),
```

- [ ] **Step 6: Verify no dangling references**

Run: `grep -rn "PortAllocator\|PortProber\|BindPortProber\|PortError" Sources Tests`
Expected: no matches. If any remain (e.g. `PortError` mapped in `AppError`), remove those references too.

- [ ] **Step 7: Build + run the affected tests**

Run: `swift build`
Expected: `Build complete!`
Run: `swift test --filter WorkspaceManagerTests`
Expected: PASS. `createPersistsRunningRecordWithPortAndDB` still expects `rec.port == 4000` — with `Fixtures.config()` the primary port is `lower` (4000), so it holds.

- [ ] **Step 8: Add a test for distinct per-process ports**

Add to `Tests/SproutEngineTests/WorkspaceManagerTests.swift`:

```swift
@Test func createLaunchesEachProcessWithItsOwnPort() async throws {
    let shell = FakeShellRunner()
    shell.handles = [
        ("WEB", { FakeProcessHandle(pid: 901, exitCode: 0, lines: []) }),
        ("VITE", { FakeProcessHandle(pid: 902, exitCode: 0, lines: []) }),
    ]
    let store = FakeStateStore()
    let fs = FakeFileSystem(); fs.existing = ["/repo/.env"]
    let mgr = makeManager(shell: shell, store: store, fs: fs)

    var cfg = Fixtures.config()
    cfg.run = RunConfig(processes: [
        ProcessConfig(name: "web", command: "echo WEB port={{port}}", bindsPort: true),
        ProcessConfig(name: "vite", command: "echo VITE port={{port}}", bindsPort: true),
    ])
    _ = try await mgr.create(config: cfg, repo: repo, base: "main", branch: "feature/login") { _, _ in }

    let webCmd = shell.launches.first { $0.command.contains("WEB") }?.command
    let viteCmd = shell.launches.first { $0.command.contains("VITE") }?.command
    #expect(webCmd == "echo WEB port=4000")
    #expect(viteCmd == "echo VITE port=4001")
}
```

VERIFY DURING IMPLEMENTATION: `FakeShellRunner` must expose recorded launches (a `launches` array of `(command, cwd, env)`) and match `handles` by substring, the same way existing tests use `shell.handles`. Read `Tests/SproutEngineTests/Support/FakeShellRunner.swift` first; if the recorded-launches property has a different name (e.g. `launchCalls`), use that name and adjust the `shell.handles` keys to whatever substring the fake matches on. If the fake matches handles by exact command string, set the `handles` keys to the exact rendered commands `"echo WEB port=4000"` / `"echo VITE port=4001"`.

- [ ] **Step 9: Run the new test**

Run: `swift test --filter createLaunchesEachProcessWithItsOwnPort`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: fixed per-process ports, remove PortAllocator"
```

---

## Task 6: `ProjectStore` — per-process context/env + expose `portPlan`

**Files:**
- Modify: `Sources/SproutApp/Model/ProjectStore.swift` (`context`, `childEnv`, `startProcess`, `startConsole`, add `portPlan`)

This is a `@MainActor` app type constructed with real I/O (`LoginShellRunner`, on-disk `JSONStateStore`), so it has no unit-test seam. Verify by building and by the manual check in Task 9.

- [ ] **Step 1: Add a cached `portPlan` and thread it through context/env**

In `Sources/SproutApp/Model/ProjectStore.swift`, add a stored plan near the other lets (after `let config: Config` on line 31):

```swift
    /// Deterministic port assignment for this project's processes. Falls back to
    /// an empty plan (primary = port.lower) if the config over-subscribes the range;
    /// surfacing that as an error is handled at config-save time.
    let portPlan: PortPlan
```

In `init` (after `self.config = config` on line 53), add:

```swift
        self.portPlan = (try? makePortPlan(config))
            ?? PortPlan(byName: [:], primary: config.port.lower)
```

Replace `context` (lines 117-121) and `childEnv` (lines 123-127) with:

```swift
    private func context(_ rec: WorkspaceRecord, process name: String? = nil) -> TemplateContext {
        let port = name.flatMap { portPlan.byName[$0] } ?? portPlan.primary
        return TemplateContext(
            project: config.project.name, branch: rec.branch,
            port: port, dbName: rec.dbName, worktree: rec.worktreePath,
            ports: portPlan.byName)
    }

    private func childEnv(_ rec: WorkspaceRecord, process name: String? = nil) -> [String: String] {
        let port = name.flatMap { portPlan.byName[$0] } ?? portPlan.primary
        let url = DatabaseService(shell: shell, renderer: renderer)
            .databaseURL(config.database, ctx: context(rec, process: name))
        return ["PORT": String(port), "DATABASE_URL": url]
    }
```

- [ ] **Step 2: Pass the process name at the start call sites**

In `startProcess` (lines 189-193), change the `sup.start` call to pass `process: name`:

```swift
            let pid = try await sup.start(
                command: command, ctx: context(rec, process: name),
                cwd: URL(fileURLWithPath: rec.worktreePath),
                env: childEnv(rec, process: name), onLog: onLog(branch: rec.branch, process: name),
                onExit: onExit)
```

In `startConsole` (lines 259-262), consoles don't bind a port — pass no process name (keeps primary port, unchanged behavior):

```swift
            let session = try await consoleSupervisor.start(
                branch: branch, name: name, command: command,
                ctx: context(rec), cwd: URL(fileURLWithPath: rec.worktreePath),
                env: childEnv(rec), onExit: onExit)
```

(That `context(rec)` / `childEnv(rec)` call is the same shape as before since the new params default to `nil`.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/SproutApp/Model/ProjectStore.swift
git commit -m "feat: per-process port context in ProjectStore"
```

---

## Task 7: `ProjectStore.stopOthers` — single active workspace

**Files:**
- Modify: `Sources/SproutApp/Model/ProjectStore.swift` (add `stopOthers`; call in `startProcess`, `startConsole`, `create`)

- [ ] **Step 1: Add the helper**

In `Sources/SproutApp/Model/ProjectStore.swift`, add this method in the `// MARK: - Lifecycle actions` area (e.g. right after `childEnv`):

```swift
    /// Enforce one active workspace per project: stop every running process and
    /// console belonging to a branch other than `branch`. Called before any start.
    private func stopOthers(exceptBranch branch: String) async {
        let otherSupervisors = supervisors.filter { $0.key.branch != branch }
        for (key, sup) in otherSupervisors {
            await sup.stop(graceSeconds: 5)
            supervisors[key] = nil
            if var rec = try? store.load().first(where: { $0.branch == key.branch }) {
                upsertProcess(&rec, ProcessState(name: key.name, pid: nil, status: .stopped))
                try? store.upsert(rec)
            }
        }
        for session in consoleSessions where session.branch != branch {
            consoleControllers[session.id]?.stop()
            consoleControllers[session.id] = nil
            await consoleSupervisor.stop(id: session.id)
        }
        consoleSessions = consoleSessions.filter { $0.branch == branch }
        refresh()
    }
```

- [ ] **Step 2: Call it before starting a process**

In `startProcess`, immediately after `guard let command = command(for: name) else { return }` (line 174), add:

```swift
        await stopOthers(exceptBranch: item.record.branch)
```

- [ ] **Step 3: Call it before starting a console**

In `startConsole`, immediately after `guard let command = consoleCommand(for: name) else { return }` (line 252), add:

```swift
        await stopOthers(exceptBranch: item.record.branch)
```

- [ ] **Step 4: Call it before create launches processes**

In `create`, immediately before the `do {` block that calls `manager.create` (line 143), add:

```swift
        await stopOthers(exceptBranch: branch)
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutApp/Model/ProjectStore.swift
git commit -m "feat: enforce single active workspace per project"
```

---

## Task 8: Carry `bindsPort` through the config form

**Files:**
- Modify: `Sources/SproutApp/Model/ConfigDraft.swift:18-22,53,102-108`
- Modify: `Sources/SproutApp/Views/ConfigFormView.swift:150-171`

- [ ] **Step 1: Add `bindsPort` to `ProcessRow`**

In `Sources/SproutApp/Model/ConfigDraft.swift`, replace the `ProcessRow` struct (lines 18-22) with:

```swift
    struct ProcessRow: Identifiable {
        let id = UUID()
        var name: String
        var command: String
        var bindsPort: Bool = false
    }
```

- [ ] **Step 2: Initialize it from config**

Replace line 53 with:

```swift
        processes = c.run.processes.map {
            ProcessRow(name: $0.name, command: $0.command, bindsPort: $0.bindsPort)
        }
```

- [ ] **Step 3: Pass it through `build()`**

In `build()`, replace the process mapping (lines 102-108) with:

```swift
        let procs = try processes.compactMap { row -> ProcessConfig? in
            let n = row.name.trimmingCharacters(in: .whitespaces)
            let c = row.command.trimmingCharacters(in: .whitespaces)
            if n.isEmpty, c.isEmpty { return nil }  // drop fully-blank rows
            guard !n.isEmpty, !c.isEmpty else { throw DraftError.incompleteProcess }
            return ProcessConfig(name: n, command: c, bindsPort: row.bindsPort)
        }
```

- [ ] **Step 4: Add a toggle in the form**

In `Sources/SproutApp/Views/ConfigFormView.swift`, replace the process row `HStack` (lines 152-164) with one that includes a port toggle:

```swift
                    HStack {
                        TextField("name", text: $proc.name)
                            .frame(width: 110)
                        TextField("command", text: $proc.command)
                            .font(.callout.monospaced())
                        Toggle("Port", isOn: $proc.bindsPort)
                            .toggleStyle(.checkbox)
                            .help("This process binds a port and gets its own")
                        Button(role: .destructive) {
                            removeProcess(proc.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove process")
                    }
```

And update the "Add process" default (line 167) so it constructs with the new field — it already compiles because `bindsPort` defaults to `false`, but make it explicit:

```swift
                    draft.processes.append(.init(name: "", command: "", bindsPort: false))
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutApp/Model/ConfigDraft.swift Sources/SproutApp/Views/ConfigFormView.swift
git commit -m "feat: per-process port toggle in config form"
```

---

## Task 9: Inspector shows one row per port

**Files:**
- Modify: `Sources/SproutApp/Views/WorkspaceDetailView.swift` (inspector `field("Port", ...)` → per-process rows)

- [ ] **Step 1: Replace the single Port field with per-process rows**

In `Sources/SproutApp/Views/WorkspaceDetailView.swift`, in the `inspector` view, replace the line `field("Port", ":\(rec.port)")` with:

```swift
                if project.portPlan.byName.isEmpty {
                    field("Port", ":\(rec.port)")
                } else {
                    ForEach(
                        project.portPlan.byName.sorted(by: { $0.value < $1.value }), id: \.key
                    ) { name, port in
                        field("Port (\(name))", ":\(port)")
                    }
                }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Lint**

Run: `swift format lint -r Sources Tests`
Expected: exit 0, no output. Fix any `[AddLines]` style issues by putting trailing-closure actions on their own lines (do NOT run `swift format format -i`).

- [ ] **Step 4: Full test suite**

Run: `swift test`
Expected: all suites PASS.

- [ ] **Step 5: Manual verification of single-active + ports**

Update the repo's `.sprout.toml` to declare two port-binding processes (temporarily, for the check), then:

```bash
swift run SproutApp
```

In the app: create/select a workspace, Start all. Confirm in the inspector that `web` and `vite` show distinct ports (e.g. :4000, :4001) and neither process crashes on a port-in-use error. Select a *second* workspace and Start all — confirm the first workspace's processes and any open console flip to stopped (single active). Quit the app.

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutApp/Views/WorkspaceDetailView.swift
git commit -m "feat: inspector lists per-process ports"
```

---

## Self-Review Notes (addressed)

- **Spec coverage:** Part 1 (single active) → Task 7. Part 2 (per-process ports) → Tasks 1–6, 9. Config schema → Tasks 1, 2, 8. Template `{{port.<name>}}` → Task 4. PortAllocator removal → Task 5. Inspector UI → Task 9. State/migration → no code change needed (`rec.port` stays primary), covered by Task 5 Step 7 assertion.
- **Beyond spec:** Task 8 (config form `bindsPort`) added because editing config in the app would otherwise silently drop `port = true` on save.
- **Type consistency:** `bindsPort` (Config), `makePortPlan`/`PortPlan.byName`/`PortPlan.primary`, `TemplateContext.ports`, `context(_:process:)`/`childEnv(_:process:)`, `stopOthers(exceptBranch:)`, `ProjectStore.portPlan` used consistently across tasks.
- **Verify-during-implementation flags:** `FakeShellRunner` recorded-launch property name + matching strategy (Task 5 Step 8); any `PortError` reference in `AppError` (Task 5 Step 6); TOMLKit `?.bool` accessor (Task 1 — confirm it compiles, else use `?.int == 1`/string compare).

# Multi-process Workspaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a workspace run multiple independently-supervised long-running processes (e.g. a Rails server **and** an asset watcher) instead of a single server command.

**Architecture:** Replace the single `RunConfig.serverCommand` / `WorkspaceRecord.serverPID` with a process list (`[[run.process]]` in TOML → `[ProcessConfig]` → `[ProcessState]`). Each process is supervised by its own `ServerSupervisor` instance. Workspace status is aggregated ("all-running" semantics) from per-process status. To keep `swift build` and the pre-commit hook (lint + build + 58 tests) green at **every commit**, the migration is transitional: Tasks 1–2 add the new fields *additively* (keeping `serverCommand`/`serverPID`), Tasks 3–6 migrate each consumer, and Task 7 removes the legacy fields in one final cleanup.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI macOS 14, TOMLKit, Swift Testing. No new dependencies.

---

## File Structure

- **`Sources/SproutEngine/State/StateStore.swift`** — add `ProcessStatus`, `ProcessState`, `WorkspaceRecord.processes`, tolerant `init(from:)`, free func `aggregateStatus`. (Task 1)
- **`Sources/SproutEngine/Config/Config.swift`** — add `ProcessConfig`, `RunConfig.processes`. (Task 2)
- **`Sources/SproutEngine/Config/TOMLConfigLoader.swift`** / **`TOMLConfigWriter.swift`** — parse/emit `[[run.process]]`. (Task 2)
- **`Sources/SproutEngine/Workspace/WorkspaceManager.swift`** — multi-process create/teardown/reconcile. (Task 3)
- **`Sources/SproutApp/Model/ProjectStore.swift`** + **`Views/WorkspaceDetailView.swift`** + **`Views/SproutAppMain.swift`** + **`Views/LogConsoleView.swift`** + **`Views/MenuBarContentView.swift`** — per-process view-model + UI (atomic app-layer change). (Task 4)
- **`Sources/SproutApp/Model/ConfigDraft.swift`** + **`Views/ConfigFormView.swift`** — process-row editor. (Task 5)
- **`Sources/sprout-cli/Sprout.swift`** — per-process list + `--process` flag. (Task 6)
- **All of the above + `Tests/.../Fixtures.swift`, `WorkspaceManagerTests.swift`, `JSONStateStoreTests.swift`, `PortAllocatorTests.swift`, `TOMLConfigLoaderTests.swift`** — remove `serverCommand`/`serverPID`. (Task 7)

### Why transitional

`RunConfig.serverCommand` and `WorkspaceRecord.serverPID` are referenced across all three products and the tests. Removing them up front breaks the package, so no intermediate commit would compile (pre-commit hook builds + tests). Instead the new fields are added with defaulted init params so existing callers keep compiling, each consumer migrates to the new fields, and the legacy fields are deleted only once nothing reads them.

### Testing note

Engine changes are covered by Swift Testing unit tests with injected fakes (existing pattern). App and CLI have **no** unit-test infra in this repo — they are verified by `swift build` + `swift format lint` + a manual run checklist. Each engine task is test-first. Do **not** run `swift format format -i` (it rewraps the intentional compact style); only `swift format lint`.

---

## Task 1: State layer — per-process state (additive)

**Files:**
- Modify: `Sources/SproutEngine/State/StateStore.swift`
- Create: `Tests/SproutEngineTests/StateAggregateTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SproutEngineTests/StateAggregateTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

@Test func aggregateEmptyIsStopped() {
    #expect(aggregateStatus([]) == .stopped)
}

@Test func aggregateAllRunningIsRunning() {
    let ps = [
        ProcessState(name: "server", pid: 1, status: .running),
        ProcessState(name: "assets", pid: 2, status: .running),
    ]
    #expect(aggregateStatus(ps) == .running)
}

@Test func aggregateAnyCrashedIsCrashed() {
    let ps = [
        ProcessState(name: "server", pid: 1, status: .running),
        ProcessState(name: "assets", pid: nil, status: .crashed),
    ]
    #expect(aggregateStatus(ps) == .crashed)
}

@Test func aggregateMixedRunningStoppedIsStopped() {
    let ps = [
        ProcessState(name: "server", pid: 1, status: .running),
        ProcessState(name: "assets", pid: nil, status: .stopped),
    ]
    #expect(aggregateStatus(ps) == .stopped)
}

@Test func recordDecodesWithoutProcessesKey() throws {
    // Existing on-disk state has serverPID and no processes key.
    let json = """
        {"id":"00000000-0000-0000-0000-000000000000","branch":"b","base":"main",
         "worktreePath":"/wt/b","port":4000,"dbName":"d","status":"stopped",
         "serverPID":123,"createdAt":"1970-01-01T00:00:00Z"}
        """
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let rec = try dec.decode(WorkspaceRecord.self, from: Data(json.utf8))
    #expect(rec.processes.isEmpty)
    #expect(rec.branch == "b")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StateAggregate`
Expected: compile failure — `aggregateStatus`, `ProcessState`, `WorkspaceRecord.processes` not defined.

- [ ] **Step 3: Add the types, field, tolerant decode, and aggregator**

In `Sources/SproutEngine/State/StateStore.swift`, after the `WorkspaceStatus` enum (line 5) add:

```swift
public enum ProcessStatus: String, Codable, Sendable { case running, stopped, crashed }

public struct ProcessState: Codable, Sendable, Equatable {
    public var name: String
    public var pid: Int32?
    public var status: ProcessStatus
    public init(name: String, pid: Int32?, status: ProcessStatus) {
        self.name = name; self.pid = pid; self.status = status
    }
}
```

In `WorkspaceRecord`, add the `processes` stored property after `serverPID` (line 15):

```swift
    public var serverPID: Int32?
    public var processes: [ProcessState]
    public var createdAt: Date
```

Update the memberwise `init` to take a defaulted `processes` (so existing callers compile unchanged):

```swift
    public init(
        id: UUID, branch: String, base: String, worktreePath: String,
        port: Int, dbName: String, status: WorkspaceStatus,
        serverPID: Int32?, createdAt: Date, processes: [ProcessState] = []
    ) {
        self.id = id; self.branch = branch; self.base = base
        self.worktreePath = worktreePath; self.port = port; self.dbName = dbName
        self.status = status; self.serverPID = serverPID; self.createdAt = createdAt
        self.processes = processes
    }
```

Add a tolerant decoder right after the memberwise init (CodingKeys are auto-synthesized; encoding stays synthesized). This lets existing on-disk state — which has `serverPID` and no `processes` key — still load:

```swift
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        branch = try c.decode(String.self, forKey: .branch)
        base = try c.decode(String.self, forKey: .base)
        worktreePath = try c.decode(String.self, forKey: .worktreePath)
        port = try c.decode(Int.self, forKey: .port)
        dbName = try c.decode(String.self, forKey: .dbName)
        status = try c.decode(WorkspaceStatus.self, forKey: .status)
        serverPID = try c.decodeIfPresent(Int32.self, forKey: .serverPID)
        processes = try c.decodeIfPresent([ProcessState].self, forKey: .processes) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
```

At the end of the file (after the `StateStore` protocol) add the aggregator:

```swift
/// "All-running" semantics: running only if every process runs; crashed if any
/// crashed; otherwise stopped. `creating`/`tearingDown` are set explicitly elsewhere
/// and never derived from processes.
public func aggregateStatus(_ processes: [ProcessState]) -> WorkspaceStatus {
    if processes.isEmpty { return .stopped }
    if processes.contains(where: { $0.status == .crashed }) { return .crashed }
    if processes.allSatisfy({ $0.status == .running }) { return .running }
    return .stopped
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StateAggregate`
Expected: 5 tests pass.

- [ ] **Step 5: Build & lint**

Run: `swift build && swift format lint -r Sources/SproutEngine/State/StateStore.swift`
Expected: `Build complete!`, no lint output.

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutEngine/State/StateStore.swift Tests/SproutEngineTests/StateAggregateTests.swift
git commit -m "feat(engine): add ProcessState, processes field, and aggregateStatus"
```

---

## Task 2: Config + TOML — process list (additive)

**Files:**
- Modify: `Sources/SproutEngine/Config/Config.swift`
- Modify: `Sources/SproutEngine/Config/TOMLConfigLoader.swift`
- Modify: `Sources/SproutEngine/Config/TOMLConfigWriter.swift`
- Modify: `Tests/SproutEngineTests/TOMLConfigLoaderTests.swift`

`serverCommand` is kept for now; `processes` is added alongside it. Both are read and written, so the existing round-trip stays valid.

- [ ] **Step 1: Write the failing tests**

In `Tests/SproutEngineTests/TOMLConfigLoaderTests.swift`, add two tests after `parsesFullConfig` (the existing `sampleTOML` has no `[[run.process]]`, so it must parse to an empty list):

```swift
@Test func parsesEmptyProcessListWhenAbsent() throws {
    let config = try TOMLConfigLoader.parse(sampleTOML)
    #expect(config.run.processes.isEmpty)
}

@Test func parsesAndRoundTripsMultipleProcesses() throws {
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
        drop_command = "dropdb --if-exists {{db_name}}"
        url_template = "postgres://localhost/{{db_name}}"
        [run]
        server_command = "npm run dev"
        [[run.process]]
        name = "server"
        command = "bin/rails server -p {{port}}"
        [[run.process]]
        name = "assets"
        command = "yarn build --watch"
        """
    let config = try TOMLConfigLoader.parse(toml)
    #expect(config.run.processes.map(\.name) == ["server", "assets"])
    #expect(config.run.processes[0].command == "bin/rails server -p {{port}}")

    // Round-trips through the writer.
    let reparsed = try TOMLConfigLoader.parse(TOMLConfigWriter.serialize(config))
    #expect(reparsed.run.processes == config.run.processes)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TOMLConfigLoaderTests`
Expected: compile failure — `RunConfig.processes` and `ProcessConfig` not defined.

- [ ] **Step 3: Add `ProcessConfig` and `RunConfig.processes`**

In `Sources/SproutEngine/Config/Config.swift`, replace the `RunConfig` struct (lines 70–73) with:

```swift
public struct ProcessConfig: Sendable, Equatable {
    public var name: String
    public var command: String  // template, long-running
    public init(name: String, command: String) { self.name = name; self.command = command }
}

public struct RunConfig: Sendable {
    public var serverCommand: String  // template, long-running (legacy; removed in cleanup)
    public var processes: [ProcessConfig]
    public init(serverCommand: String, processes: [ProcessConfig] = []) {
        self.serverCommand = serverCommand; self.processes = processes
    }
}
```

- [ ] **Step 4: Parse `[[run.process]]` in the loader**

In `Sources/SproutEngine/Config/TOMLConfigLoader.swift`, after the setup-array loop (line 57, before the `hooksT` line) add:

```swift
        var processes: [ProcessConfig] = []
        if let arr = runT["process"]?.array {
            for entry in arr {
                guard let pt = entry.table,
                    let name = pt["name"]?.string,
                    let cmd = pt["command"]?.string
                else {
                    throw ConfigError.missingKey("run.process[].name/command")
                }
                processes.append(ProcessConfig(name: name, command: cmd))
            }
        }
```

Then update the `run:` argument in the returned `Config` (line 80):

```swift
            run: RunConfig(
                serverCommand: try str(runT, "server_command", "run.server_command"),
                processes: processes),
```

- [ ] **Step 5: Emit `[[run.process]]` in the writer**

In `Sources/SproutEngine/Config/TOMLConfigWriter.swift`, replace the single `run` line (line 40) with:

```swift
        let run = TOMLTable()
        run["server_command"] = config.run.serverCommand
        let procs = TOMLArray()
        for p in config.run.processes {
            procs.append(TOMLTable(["name": p.name, "command": p.command]))
        }
        run["process"] = procs
        root["run"] = run
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter TOMLConfigLoaderTests && swift test --filter TOMLConfigWriterTests`
Expected: all pass (existing `roundTripsThroughParse` still asserts `serverCommand`; new tests assert `processes`).

- [ ] **Step 7: Build & lint**

Run: `swift build && swift format lint -r Sources/SproutEngine/Config`
Expected: `Build complete!`, no lint output.

- [ ] **Step 8: Commit**

```bash
git add Sources/SproutEngine/Config Tests/SproutEngineTests/TOMLConfigLoaderTests.swift
git commit -m "feat(engine): parse and write [[run.process]] alongside server_command"
```

---

## Task 3: Engine — multi-process create / teardown / reconcile

**Files:**
- Modify: `Sources/SproutEngine/Workspace/WorkspaceManager.swift`
- Modify: `Tests/SproutEngineTests/Support/Fixtures.swift`
- Modify: `Tests/SproutEngineTests/WorkspaceManagerTests.swift`

After this task the engine drives processes from `config.run.processes` and writes `record.processes`; `record.serverPID` is left `nil` (the legacy field still exists but the engine no longer reads or writes it).

- [ ] **Step 1: Update the fixture to declare processes**

In `Tests/SproutEngineTests/Support/Fixtures.swift`, replace the `run:` line (line 21) with:

```swift
            run: RunConfig(
                serverCommand: "npm run dev",
                processes: [ProcessConfig(name: "server", command: "npm run dev")]),
```

- [ ] **Step 2: Update the engine tests to assert on processes**

In `Tests/SproutEngineTests/WorkspaceManagerTests.swift`:

Replace the `serverPID` assertion in `createPersistsRunningRecordWithPortAndDB` (line 52) with:

```swift
    #expect(rec.processes == [ProcessState(name: "server", pid: 900, status: .running)])
```

Replace `seedRecord` (lines 102–109) so it seeds a process instead of a bare PID:

```swift
private func seedRecord(into store: FakeStateStore, pid: Int32? = 900) -> WorkspaceRecord {
    let procs = pid.map { [ProcessState(name: "server", pid: $0, status: .running)] } ?? []
    let r = WorkspaceRecord(
        id: UUID(), branch: "feature/login", base: "main",
        worktreePath: "/wt/feature_login", port: 4000, dbName: "shop_feature_login",
        status: .running, serverPID: nil, createdAt: Date(), processes: procs)
    store.records = [r]
    return r
}
```

`teardownWithPushRunsFullOrderAndClearsState` already asserts `term.terminated == [900]` — the seeded process has pid 900, so it stays correct. `reconcileMarksDeadPidStopped` asserts `result.first?.status == .stopped` and `reconcileKeepsRunningWhenPidAlive` asserts `.running`; both stay correct under aggregation (single process). `reconcileFlagsMissingWorktreeAsOrphaned` seeds `pid: nil` → empty processes → status aggregates to `.stopped`; it only asserts `orphaned == true`, so it stays correct. No further test edits needed.

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter WorkspaceManagerTests`
Expected: failures — `createPersistsRunningRecordWithPortAndDB` (rec.processes empty, engine still single-server) and any others depending on the new behavior.

- [ ] **Step 4: Multi-process `create`**

In `Sources/SproutEngine/Workspace/WorkspaceManager.swift`, replace the single-supervisor block in `create` (lines 118–124) with a loop:

```swift
            var processes: [ProcessState] = []
            for proc in config.run.processes {
                let supervisor = ServerSupervisor(shell: shell, renderer: renderer)
                let pid = try await supervisor.start(
                    command: proc.command, ctx: ctx,
                    cwd: worktreeURL, env: childEnv, onLog: onLog)
                processes.append(ProcessState(name: proc.name, pid: pid, status: .running))
            }
            record.processes = processes
            record.status = aggregateStatus(processes)
            try store.upsert(record)
            return record
```

Zero processes → the loop starts nothing, `aggregateStatus([])` is `.stopped`, and the record persists with no running server.

- [ ] **Step 5: Multi-process `teardown`**

Replace the single-PID stop in `teardown` (lines 190–192) with a loop over the record's processes:

```swift
        // stop every process
        for proc in record.processes {
            if let pid = proc.pid {
                await terminator.terminate(pid: pid, graceSeconds: 5)
            }
        }
```

- [ ] **Step 6: Multi-process `reconcile`**

Replace the body of the `reconcile` loop (lines 211–216) with per-process liveness:

```swift
            var changed = false
            for i in record.processes.indices {
                guard let pid = record.processes[i].pid else { continue }
                if !checker.isAlive(pid: pid), record.processes[i].status == .running {
                    record.processes[i].status = .stopped
                    record.processes[i].pid = nil
                    changed = true
                }
            }
            if changed, record.status != .creating, record.status != .tearingDown {
                record.status = aggregateStatus(record.processes)
                try store.upsert(record)
            }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter WorkspaceManagerTests && swift test --filter StateAggregate && swift test --filter TOMLConfig`
Expected: all pass.

- [ ] **Step 8: Full test, build & lint**

Run: `swift test && swift build && swift format lint -r Sources/SproutEngine`
Expected: full suite passes, `Build complete!`, no lint output.

- [ ] **Step 9: Commit**

```bash
git add Sources/SproutEngine/Workspace/WorkspaceManager.swift Tests/SproutEngineTests/Support/Fixtures.swift Tests/SproutEngineTests/WorkspaceManagerTests.swift
git commit -m "feat(engine): supervise multiple processes per workspace"
```

---

## Task 4: App — per-process view-model + UI (atomic)

**Files:**
- Modify: `Sources/SproutApp/Model/ProjectStore.swift`
- Modify: `Sources/SproutApp/Views/SproutAppMain.swift`
- Modify: `Sources/SproutApp/Views/LogConsoleView.swift`
- Modify: `Sources/SproutApp/Views/WorkspaceDetailView.swift`
- Modify: `Sources/SproutApp/Views/MenuBarContentView.swift`

The app layer has no unit tests, so `ProjectStore` and every view that calls it change together in one commit; the gate is `swift build`. The old `startOrRestartServer`/`stopServer`/`logBuffer(for:)` API is replaced (not wrapped) by per-process methods.

- [ ] **Step 1: Rekey `ProjectStore` and add per-process methods**

In `Sources/SproutApp/Model/ProjectStore.swift`:

Replace the two dictionaries (lines 28–29) with process-keyed ones and add a key type:

```swift
    private var buffers: [ProcessKey: LogBuffer] = [:]
    private var supervisors: [ProcessKey: ServerSupervisor] = [:]
```

Add the key struct just above the `ProjectStore` class declaration (after `WorkspaceItem`, around line 10):

```swift
/// Identifies one supervised process within a workspace branch.
private struct ProcessKey: Hashable {
    let branch: String
    let name: String
}
```

Replace the Logs section (lines 65–75) with process-scoped buffers:

```swift
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
```

Replace `startOrRestartServer` and `stopServer` (lines 124–159) with per-process and bulk actions. `create` (lines 112–122) still calls `onLog(for:)`, which no longer exists — fix it too:

```swift
    func create(base: String, branch: String) async {
        let log = onLog(branch: branch, process: "create")
        do {
            _ = try await manager.create(
                config: config, repo: rootURL,
                base: base, branch: branch, onLog: log)
            refresh()
        } catch {
            lastError = AppError(error)
        }
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
        let sup = ServerSupervisor(shell: shell, renderer: renderer)
        do {
            let pid = try await sup.start(
                command: command, ctx: context(rec),
                cwd: URL(fileURLWithPath: rec.worktreePath),
                env: childEnv(rec), onLog: onLog(branch: rec.branch, process: name))
            supervisors[key] = sup
            upsertProcess(&rec, ProcessState(name: name, pid: pid, status: .running))
            try store.upsert(rec)
            refresh()
        } catch {
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

    /// Replace (or insert) a process state by name and recompute the record's status.
    private func upsertProcess(_ rec: inout WorkspaceRecord, _ state: ProcessState) {
        if let i = rec.processes.firstIndex(where: { $0.name == state.name }) {
            rec.processes[i] = state
        } else {
            rec.processes.append(state)
        }
        rec.status = aggregateStatus(rec.processes)
    }
```

In `teardown` (lines 172–182), the line `supervisors[item.record.branch] = nil` no longer type-checks. Replace it with a clear of all this branch's supervisors:

```swift
            supervisors = supervisors.filter { $0.key.branch != item.record.branch }
```

- [ ] **Step 2: Add `process` to `LogTarget`**

In `Sources/SproutApp/Views/SproutAppMain.swift`, replace the `LogTarget` struct (lines 5–9) with:

```swift
/// Identifies a detached log window: a process within a workspace branch within a project.
struct LogTarget: Identifiable, Hashable, Codable {
    let projectID: String
    let branch: String
    let process: String
    var id: String { "\(projectID)#\(branch)#\(process)" }
}
```

- [ ] **Step 3: Point the detached window at the per-process buffer**

In `Sources/SproutApp/Views/LogConsoleView.swift`, update `DetachedLogWindow.body` (lines 65–76) to use the new buffer lookup:

```swift
        Group {
            if let target,
                let project = app.projects.first(where: { $0.id == target.projectID })
            {
                LogConsoleView(
                    buffer: project.logBuffer(branch: target.branch, process: target.process)
                )
                .navigationTitle("\(project.name) / \(target.branch) / \(target.process)")
            } else {
                ContentUnavailableView("No Logs", systemImage: "doc.plaintext")
            }
        }
```

- [ ] **Step 4: Process picker + per-process controls in the detail view**

In `Sources/SproutApp/Views/WorkspaceDetailView.swift`:

Add selection state after `@State private var dirtyWarning = false` (line 14):

```swift
    @State private var selectedProcess: String?
```

Add a computed helper for the process names and the currently-selected name (after `rec`, line 16):

```swift
    private var processNames: [String] { project.config.run.processes.map(\.name) }
    private var current: String? { selectedProcess ?? processNames.first }
```

Replace the `body`'s top `VStack` content (lines 19–27) so the picker drives which log is shown:

```swift
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let current {
                processBar(current)
                Divider()
                LogConsoleView(
                    buffer: project.logBuffer(branch: rec.branch, process: current),
                    onPopOut: {
                        openWindow(
                            value: LogTarget(
                                projectID: project.id, branch: rec.branch, process: current))
                    })
            } else {
                ContentUnavailableView(
                    "No processes", systemImage: "bolt.slash",
                    description: Text("This workspace defines no run processes."))
            }
        }
```

Replace the header's `PID` field (line 78) with nothing (the per-process status now lives in the picker); delete that single line so the header shows Port + Database only:

```swift
            field("Port", ":\(rec.port)")
            field("Database", rec.dbName)
            Spacer()
```

Add the process bar and a per-process status dot after `header` (before `field(_:_:)`, line 84):

```swift
    private func processBar(_ name: String) -> some View {
        HStack(spacing: 12) {
            Picker("Process", selection: Binding(
                get: { current ?? name },
                set: { selectedProcess = $0 })
            ) {
                ForEach(processNames, id: \.self) { proc in
                    Label {
                        Text(proc)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(dotColor(proc))
                    }
                    .tag(proc)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer()
            Button { run { await project.startProcess(item, name: name) } } label: {
                Label("Start", systemImage: "play.fill")
            }
            Button { run { await project.stopProcess(item, name: name) } } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            Button { run { await project.restartProcess(item, name: name) } } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal).padding(.vertical, 6)
    }

    private func dotColor(_ name: String) -> Color {
        switch rec.processes.first(where: { $0.name == name })?.status {
        case .running: return .green
        case .crashed: return .red
        default: return .secondary
        }
    }
```

Replace the toolbar's start/stop/restart group (lines 96–115) with workspace-wide Start all / Stop all:

```swift
            if busy { ProgressView().controlSize(.small) }
            Button {
                run { await project.startAll(item) }
            } label: {
                Label("Start all", systemImage: "play.fill")
            }
            .disabled(item.orphaned)
            Button {
                run { await project.stopAll(item) }
            } label: {
                Label("Stop all", systemImage: "stop.fill")
            }
```

- [ ] **Step 5: Update the menu-bar row to bulk actions**

In `Sources/SproutApp/Views/MenuBarContentView.swift`, replace the start/stop buttons in `MenuBarRow.body` (lines 58–71) with bulk actions (status is already aggregated on `item.record.status`):

```swift
            } else if item.record.status == .running {
                Button {
                    toggle { await project.stopAll(item) }
                } label: {
                    Image(systemName: "stop.fill")
                }
            } else {
                Button {
                    toggle { await project.startAll(item) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(item.orphaned)
            }
```

- [ ] **Step 6: Build & lint**

Run: `swift build && swift format lint -r Sources/SproutApp`
Expected: `Build complete!`, no lint output.

- [ ] **Step 7: Manual run check**

Run: `swift run SproutApp`
Verify (point a project's `.sprout.toml` at two `[[run.process]]` entries first):
- Detail view shows a segmented process picker with a colored status dot per process.
- Selecting a process swaps the log console to that process's buffer; Pop Out opens a window titled `project / branch / process`.
- Start / Stop / Restart act on the selected process; the picker dot updates.
- Toolbar Start all / Stop all start/stop every process; the status badge reflects aggregate status.
- Menu-bar row play/stop start/stop all processes for that workspace.

- [ ] **Step 8: Commit**

```bash
git add Sources/SproutApp/Model/ProjectStore.swift Sources/SproutApp/Views/SproutAppMain.swift Sources/SproutApp/Views/LogConsoleView.swift Sources/SproutApp/Views/WorkspaceDetailView.swift Sources/SproutApp/Views/MenuBarContentView.swift
git commit -m "feat(app): per-process logs, controls, and start/stop all"
```

---

## Task 5: App — process-row config editor

**Files:**
- Modify: `Sources/SproutApp/Model/ConfigDraft.swift`
- Modify: `Sources/SproutApp/Views/ConfigFormView.swift`

`ConfigDraft.serverCommand` becomes a list of editable `ProcessRow`s; the "at least one server command" guard is dropped. During transition `build()` still supplies a (now empty) `serverCommand` to `RunConfig` so the legacy field stays valid until Task 7.

- [ ] **Step 1: Replace `serverCommand` with process rows in the draft**

In `Sources/SproutApp/Model/ConfigDraft.swift`:

Add a `ProcessRow` type next to `Step` (after line 17):

```swift
    struct ProcessRow: Identifiable {
        let id = UUID()
        var name: String
        var command: String
    }
```

Replace the `serverCommand` published property (line 30) with:

```swift
    @Published var processes: [ProcessRow]
```

In `init(_ c: Config)`, replace the `serverCommand` assignment (line 46) with:

```swift
        processes = c.run.processes.map { ProcessRow(name: $0.name, command: $0.command) }
```

In `template()`, replace the `run:` line (line 64) with one blank process row:

```swift
                run: RunConfig(serverCommand: "", processes: []),
```

(`template()` builds a `Config`, which has no rows; the draft then maps to an empty `processes` list. Add a blank row for editing convenience in `build()` is unnecessary — the form's "Add process" button handles it.)

In `build()`, delete the `serverCommand` empty guard (lines 83–85) and build the process list from the rows. Replace the `steps` block region by adding, after the `steps` mapping (line 96):

```swift
        let procs = try processes.compactMap { row -> ProcessConfig? in
            let n = row.name.trimmingCharacters(in: .whitespaces)
            let c = row.command.trimmingCharacters(in: .whitespaces)
            if n.isEmpty, c.isEmpty { return nil }  // drop fully-blank rows
            guard !n.isEmpty, !c.isEmpty else { throw DraftError.incompleteProcess }
            return ProcessConfig(name: n, command: c)
        }
```

Replace the `run:` argument in the returned `Config` (line 111) with:

```swift
            run: RunConfig(serverCommand: "", processes: procs),
```

Add the new error case to `DraftError` (after `case incompleteStep`, line 121):

```swift
    case incompleteProcess
```

And its message (in the `switch`, after the `incompleteStep` case, line 128):

```swift
        case .incompleteProcess: return "Every run process needs both a name and a command."
```

- [ ] **Step 2: Replace the Run section editor in the form**

In `Sources/SproutApp/Views/ConfigFormView.swift`, replace the `Section("Run")` block in `configTab` (lines 149–152) with a name+command row editor mirroring "Setup steps":

```swift
            Section("Run processes") {
                ForEach($draft.processes) { $proc in
                    HStack {
                        TextField("name", text: $proc.name)
                            .frame(width: 110)
                        TextField("command", text: $proc.command)
                            .font(.callout.monospaced())
                        Button(role: .destructive) {
                            removeProcess(proc.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    draft.processes.append(.init(name: "", command: ""))
                } label: {
                    Label("Add process", systemImage: "plus")
                }
            }
```

Add a `removeProcess` helper next to `removeStep` (after line 225):

```swift
    private func removeProcess(_ id: ConfigDraft.ProcessRow.ID) {
        draft.processes.removeAll { $0.id == id }
    }
```

- [ ] **Step 3: Build & lint**

Run: `swift build && swift format lint -r Sources/SproutApp`
Expected: `Build complete!`, no lint output.

- [ ] **Step 4: Manual run check**

Run: `swift run SproutApp`
Verify:
- Configurations tab "Run processes" section shows a name+command row editor with Add / remove, styled like "Setup steps".
- Adding two processes and saving writes two `[[run.process]]` entries (re-open the project; rows stick).
- A row with a name but no command (or vice-versa) → Save shows "Every run process needs both a name and a command." in the bottom banner.
- Zero processes saves successfully (no "server command required" error).
- "New Project" sheet shows the same editor and creates a project with zero or more processes.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutApp/Model/ConfigDraft.swift Sources/SproutApp/Views/ConfigFormView.swift
git commit -m "feat(app): edit run processes as a row list"
```

---

## Task 6: CLI — per-process list + `--process` flag

**Files:**
- Modify: `Sources/sprout-cli/Sprout.swift`

- [ ] **Step 1: Per-process summary in `create` and `list`**

In `Sources/sprout-cli/Sprout.swift`:

Replace the `create` print (lines 64–65) with a process summary:

```swift
        let procs = rec.processes.map { "\($0.name):\($0.pid ?? -1)" }.joined(separator: ",")
        print("created \(rec.branch)  port=\(rec.port)  db=\(rec.dbName)  [\(procs)]")
```

Replace the `list` print (lines 73–75) with:

```swift
            let procs = r.processes.map { "\($0.name):\($0.pid ?? -1)" }.joined(separator: ",")
            print("\(r.id)  \(r.branch)  :\(r.port)  \(r.dbName)  \(r.status.rawValue)  [\(procs)]")
```

- [ ] **Step 2: Rework the `Server` command for multiple processes**

Replace the entire `Server` struct (lines 80–117) with per-process control. It stops/restarts **all** processes by default, or one when `--process` is given, then recomputes status via `aggregateStatus`:

```swift
struct Server: AsyncParsableCommand {
    @Argument var id: String
    @Argument var action: String  // "stop" | "restart"
    @Option(name: .long) var process: String?

    func run() async throws {
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
```

- [ ] **Step 3: Build & lint**

Run: `swift build && swift format lint -r Sources/sprout-cli`
Expected: `Build complete!`, no lint output.

- [ ] **Step 4: Commit**

```bash
git add Sources/sprout-cli/Sprout.swift
git commit -m "feat(cli): per-process list output and --process control"
```

---

## Task 7: Remove legacy `serverCommand` / `serverPID`

**Files:**
- Modify: `Sources/SproutEngine/Config/Config.swift`
- Modify: `Sources/SproutEngine/Config/TOMLConfigLoader.swift`
- Modify: `Sources/SproutEngine/Config/TOMLConfigWriter.swift`
- Modify: `Sources/SproutEngine/State/StateStore.swift`
- Modify: `Sources/SproutApp/Model/ConfigDraft.swift`
- Modify: `Tests/SproutEngineTests/Support/Fixtures.swift`
- Modify: `Tests/SproutEngineTests/WorkspaceManagerTests.swift`
- Modify: `Tests/SproutEngineTests/JSONStateStoreTests.swift`
- Modify: `Tests/SproutEngineTests/PortAllocatorTests.swift`
- Modify: `Tests/SproutEngineTests/TOMLConfigLoaderTests.swift`
- Modify: `Tests/SproutEngineTests/TOMLConfigWriterTests.swift`

Nothing reads the legacy fields after Tasks 3–6, so they can be deleted. Do the engine + tests together so the build and suite stay green.

- [ ] **Step 1: Drop `serverCommand` from `RunConfig`**

In `Config.swift`, replace `RunConfig` (the struct added in Task 2) with:

```swift
public struct RunConfig: Sendable {
    public var processes: [ProcessConfig]
    public init(processes: [ProcessConfig]) { self.processes = processes }
}
```

- [ ] **Step 2: Stop reading/writing `server_command`, allow a missing `[run]`**

In `TOMLConfigLoader.swift`, replace `let runT = try tbl("run")` (line 42) with an optional lookup so zero-process configs with no `[run]` table are valid:

```swift
        let runT = table["run"]?.table
```

Update the process-array loop guard to use the optional table:

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
                processes.append(ProcessConfig(name: name, command: cmd))
            }
        }
```

Replace the `run:` argument in the returned `Config` with:

```swift
            run: RunConfig(processes: processes),
```

In `TOMLConfigWriter.swift`, delete the `run["server_command"] = config.run.serverCommand` line from the `run` block so only `[[run.process]]` is emitted:

```swift
        let run = TOMLTable()
        let procs = TOMLArray()
        for p in config.run.processes {
            procs.append(TOMLTable(["name": p.name, "command": p.command]))
        }
        run["process"] = procs
        root["run"] = run
```

- [ ] **Step 3: Drop `serverPID` from `WorkspaceRecord`**

In `StateStore.swift`:

Delete the `public var serverPID: Int32?` stored property.

Update the memberwise init to drop `serverPID`:

```swift
    public init(
        id: UUID, branch: String, base: String, worktreePath: String,
        port: Int, dbName: String, status: WorkspaceStatus,
        createdAt: Date, processes: [ProcessState] = []
    ) {
        self.id = id; self.branch = branch; self.base = base
        self.worktreePath = worktreePath; self.port = port; self.dbName = dbName
        self.status = status; self.createdAt = createdAt; self.processes = processes
    }
```

Delete the `serverPID` line from the custom `init(from:)` (keep the tolerant `processes` decode; old on-disk `serverPID` keys are simply ignored by `KeyedDecodingContainer`):

```swift
        status = try c.decode(WorkspaceStatus.self, forKey: .status)
        processes = try c.decodeIfPresent([ProcessState].self, forKey: .processes) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
```

- [ ] **Step 4: Drop `serverCommand` from `ConfigDraft`**

In `ConfigDraft.swift`, update `template()`'s `run:` line to the new initializer:

```swift
                run: RunConfig(processes: []),
```

And `build()`'s `run:` argument:

```swift
            run: RunConfig(processes: procs),
```

- [ ] **Step 5: Update the tests that still name the legacy fields**

`Tests/SproutEngineTests/Support/Fixtures.swift` — replace the `run:` line:

```swift
            run: RunConfig(processes: [ProcessConfig(name: "server", command: "npm run dev")]),
```

`Tests/SproutEngineTests/WorkspaceManagerTests.swift` — in `seedRecord`, drop `serverPID: nil`:

```swift
    let r = WorkspaceRecord(
        id: UUID(), branch: "feature/login", base: "main",
        worktreePath: "/wt/feature_login", port: 4000, dbName: "shop_feature_login",
        status: .running, createdAt: Date(), processes: procs)
```

`Tests/SproutEngineTests/JSONStateStoreTests.swift` — in `sampleRecord`, drop `serverPID: 123` and seed a process so the round-trip still exercises a populated record:

```swift
private func sampleRecord(branch: String = "feature/login") -> WorkspaceRecord {
    WorkspaceRecord(
        id: UUID(), branch: branch, base: "main",
        worktreePath: "/wt/\(branch)", port: 4001, dbName: "shop_x",
        status: .running, createdAt: Date(timeIntervalSince1970: 0),
        processes: [ProcessState(name: "server", pid: 123, status: .running)])
}
```

`Tests/SproutEngineTests/PortAllocatorTests.swift` — in `record(port:)`, drop `serverPID: nil`:

```swift
private func record(port: Int) -> WorkspaceRecord {
    WorkspaceRecord(
        id: UUID(), branch: "b", base: "main", worktreePath: "/x",
        port: port, dbName: "d", status: .running, createdAt: Date())
}
```

`Tests/SproutEngineTests/TOMLConfigLoaderTests.swift` — delete the `server_command = "npm run dev"` line from `sampleTOML` and the `#expect(config.run.serverCommand == "npm run dev")` assertion in `parsesFullConfig`.

`Tests/SproutEngineTests/TOMLConfigWriterTests.swift` — delete the `#expect(parsed.run.serverCommand == original.run.serverCommand)` line from `roundTripsThroughParse`.

- [ ] **Step 6: Full test, build & lint**

Run: `swift test && swift build && swift format lint -r Sources Tests`
Expected: full suite passes, `Build complete!`, no lint output.

- [ ] **Step 7: Manual run check**

Run: `swift run SproutApp`
Verify a clean end-to-end pass: create a project with two processes, create a workspace, start/stop/restart each process, Start all / Stop all, pop out a per-process log, save a zero-process config.

- [ ] **Step 8: Commit**

```bash
git add Sources Tests
git commit -m "refactor: drop legacy serverCommand and serverPID"
```

---

## Self-Review

- **Spec coverage:**
  - §1 Config model — `ProcessConfig` + `RunConfig.processes` (Task 2), `serverCommand` removed (Task 7) ✓
  - §2 TOML — `[[run.process]]` parse/write mirroring `[[setup]]`, empty list valid, no `server_command` after cleanup (Tasks 2, 7) ✓
  - §3 State — `ProcessStatus`, `ProcessState`, `processes`, tolerant `init(from:)`, `aggregateStatus`, `serverPID` removed (Tasks 1, 7) ✓
  - §4 Supervision — `ServerSupervisor` unchanged, one instance per process (Tasks 3, 4) ✓
  - §5 Engine — create loop, teardown loop, reconcile per-process + aggregate, zero-process skip (Task 3) ✓
  - §6 App view-model — `ProcessKey` keying, `logBuffer(branch:process:)`, `onLog(branch:process:)`, start/stop/restart/startAll/stopAll (Task 4) ✓
  - §7 App UI — process picker w/ status dot, per-process controls, Start all/Stop all toolbar, `LogTarget.process` + window wiring (Task 4) ✓
  - §8 Config form — `ProcessRow`, `processes`, `DraftError.incompleteProcess`, drop blank rows, no min-one guard, row editor (Task 5) ✓
  - §9 CLI — per-process `list`, `server` acts on all + `--process` (Task 6) ✓
  - §10 Tests — fixtures, loader/writer two-process + empty cases, manager create/teardown/reconcile, supervisor untouched (Tasks 1–3, 7) ✓
  - Out of scope (ordering, auto-restart, per-process env/cwd) — none added ✓
- **Placeholder scan:** none — every code step has full code; every command step has the exact command + expected output.
- **Type consistency:** `ProcessState(name:pid:status:)`, `ProcessConfig(name:command:)`, `aggregateStatus(_:)`, `RunConfig(serverCommand:processes:)` (Tasks 1–6) → `RunConfig(processes:)` (Task 7), `ProcessKey{branch,name}`, `LogTarget{projectID,branch,process}`, `ConfigDraft.ProcessRow{id,name,command}`, `logBuffer(branch:process:)`, `startProcess/stopProcess/restartProcess(_:name:)`, `startAll/stopAll(_:)`, `DraftError.incompleteProcess` — all names match between definition and use across tasks.
- **Transitional integrity:** Tasks 1–2 add fields with defaulted init params (existing callers compile); Tasks 3–6 migrate each consumer to the new fields while legacy fields linger unused; Task 7 deletes legacy fields with all references already gone. Every task ends green on build + lint (+ tests for engine tasks).

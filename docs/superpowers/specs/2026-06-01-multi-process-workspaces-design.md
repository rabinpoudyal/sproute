# Multi-process workspaces

## Goal

Let a workspace run multiple long-running processes (e.g. a Rails server **and** an
asset watcher) instead of a single server command. Each process is independently
configured, supervised, logged, and controlled.

## Decisions (locked)

- **Config schema:** `[[run.process]]` array only. Drop `run.server_command` entirely.
  No legacy fallback — existing configs are updated by hand.
- **Logs:** separate console per process. The detail view gets a process picker; each
  process has its own log buffer and pop-out window.
- **Control:** per-process start/stop/restart, plus Start all / Stop all.
- **Workspace status:** "all-running" semantics — `running` only if every process is
  running; `crashed` if any process crashed; otherwise `stopped`.
- **Empty run list:** allowed. Zero processes is valid; create skips auto-start. Removes
  the current "server command required" rule.

## 1. Config model — `Sources/SproutEngine/Config/Config.swift`

Replace `RunConfig.serverCommand` with a process list:

```swift
public struct ProcessConfig: Sendable, Equatable {
    public var name: String
    public var command: String  // template, long-running
    public init(name: String, command: String) { self.name = name; self.command = command }
}

public struct RunConfig: Sendable {
    public var processes: [ProcessConfig]
    public init(processes: [ProcessConfig]) { self.processes = processes }
}
```

`serverCommand` is removed from the whole codebase.

## 2. TOML — `TOMLConfigLoader.swift` / `TOMLConfigWriter.swift`

`[[run.process]]` array-of-tables, each table with `name` and `command`. Mirror the
existing `[[setup]]` array parsing/writing. A missing or empty `run.process` array
yields `processes: []` (valid). No `server_command` read or write.

Example:

```toml
[[run.process]]
name = "server"
command = "rbenv exec ruby bin/rails server -p {{port}}"

[[run.process]]
name = "assets"
command = "yarn build --watch"
```

## 3. State — `Sources/SproutEngine/State/StateStore.swift`

Replace `WorkspaceRecord.serverPID: Int32?` with a per-process list:

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
// WorkspaceRecord gains: public var processes: [ProcessState]   (serverPID removed)
```

**Tolerant decode:** give `WorkspaceRecord` a custom `init(from:)` that defaults
`processes` to `[]` when the key is absent, so existing on-disk state (which has the old
`serverPID` key and no `processes`) still loads. Such records load with zero processes
and are corrected on the next reconcile. The stale `serverPID` key is simply ignored.

**Status aggregation:** add a free function in this file:

```swift
public func aggregateStatus(_ processes: [ProcessState]) -> WorkspaceStatus {
    if processes.isEmpty { return .stopped }
    if processes.contains(where: { $0.status == .crashed }) { return .crashed }
    if processes.allSatisfy({ $0.status == .running }) { return .running }
    return .stopped
}
```

`creating` and `tearingDown` are still set explicitly during those phases and are not
derived from processes.

## 4. Supervision — `Sources/SproutEngine/Server/ServerSupervisor.swift`

Unchanged. It already supervises exactly one process (status, log streaming, exit watch,
process-group terminate). Multi-process is achieved by running **one `ServerSupervisor`
instance per process**. The name is kept to avoid churn across the CLI and tests.

## 5. Engine — `Sources/SproutEngine/Workspace/WorkspaceManager.swift`

- **create:** after `setupRunner.run`, loop `config.run.processes`. For each, start a
  fresh `ServerSupervisor` and collect a `ProcessState` (`name`, returned `pid`,
  `.running`). Zero processes → start nothing. Set `record.processes` and
  `record.status = aggregateStatus(record.processes)` before the final upsert.
- **teardown:** replace the single `record.serverPID` kill with a loop over
  `record.processes`, terminating each non-nil `pid` (process group) via `terminator`.
- **reconcile:** for each record, for each process: if `pid` set and not alive and
  `status == .running`, set that process `.stopped` and clear its `pid`. After updating
  processes, set `record.status = aggregateStatus(record.processes)` (unless the record
  is `creating`/`tearingDown`). Upsert if anything changed.

## 6. App view-model — `Sources/SproutApp/Model/ProjectStore.swift`

- Key `supervisors` and `buffers` by `(branch, processName)`. Use a `Hashable` struct
  `ProcessKey { branch: String; name: String }` (file-private) for both dictionaries.
- `logBuffer(branch:process:)` replaces `logBuffer(for:)`. `onLog(for:)` becomes
  `onLog(branch:process:)`.
- New actions:
  - `startProcess(_ item:, name:)` — terminate any existing pid for that process, start a
    new `ServerSupervisor` with that process's command, store its `ProcessState` into the
    record's `processes`, recompute `record.status` via `aggregateStatus`, upsert, refresh.
  - `restartProcess(_ item:, name:)` — stop then start that one process.
  - `stopProcess(_ item:, name:)` — stop that process's supervisor (or terminate pid),
    set its `ProcessState` to `.stopped`/nil pid, recompute status, upsert, refresh.
  - `startAll(_ item:)` / `stopAll(_ item:)` — loop the config's processes.
- `childEnv` and `context` unchanged (all processes share `PORT`/`DATABASE_URL`; the
  `{{port}}` template is available to every process command).

## 7. App UI — `Sources/SproutApp/Views/WorkspaceDetailView.swift`

- Header: replace the single `PID` field with a process **picker** (segmented control)
  listing each process name with a per-process status dot.
- Below the header: the selected process's `LogConsoleView`, plus per-process
  Start / Stop / Restart buttons.
- Toolbar: add **Start all** and **Stop all** alongside existing actions.
- Pop-out: `LogTarget` gains a `process: String` field so the detached window is scoped
  to one (branch, process). Update `MainWindow`/wherever `LogTarget` windows are opened.

## 8. Config form — `ConfigDraft.swift` + `ConfigFormView.swift`

- `ConfigDraft.serverCommand: String` → `processes: [ProcessRow]`, where
  `ProcessRow: Identifiable { let id = UUID(); var name: String; var command: String }`.
- `init(_ c: Config)` maps `c.run.processes`; `template()` starts with an empty list (or
  one blank row); `build()` validates each row needs both name and command (reuse a
  `DraftError.incompleteProcess`), drops fully-blank rows, and **no longer requires** at
  least one process. Remove the `serverCommand` empty guard.
- Configurations tab "Run" section becomes a name+command row editor with Add / remove,
  styled like the existing "Setup steps" section.

## 9. CLI — `Sources/sprout-cli/Sprout.swift`

- `list`: print a per-process summary (e.g. `name:pid` joined) instead of single
  `pid=...`.
- `server <id> stop|restart`: act on **all** processes by default; add an optional
  `--process <name>` flag to target a single process. Update the record's
  `ProcessState`(s) and recompute `status` via `aggregateStatus`.

## 10. Tests

- Update `Tests/SproutEngineTests/Support/Fixtures.swift` and any fixture configs from
  `serverCommand` to `processes`.
- `TOMLConfigLoaderTests` / `TOMLConfigWriterTests`: add a round-trip with two
  `[[run.process]]` entries and an empty-processes case.
- `WorkspaceManagerTests`: update create/teardown/reconcile tests to assert on
  `record.processes` and aggregated status (e.g. create persists running processes with
  pids; reconcile marks a dead process stopped and recomputes status; teardown kills all
  process pids).
- `ServerSupervisorTests`: unchanged.

## Out of scope (YAGNI)

- Process start ordering / dependencies (start all concurrently).
- Auto-restart on crash.
- Per-process env overrides or per-process working directories.

## Testing strategy

Engine changes verified by Swift Testing unit tests with injected fakes (existing
pattern). App/UI changes verified by `swift build` + `swift format lint` + manual run
(no SwiftUI view-test infra in this repo).

# Sprout Engine — Design (Phase 1: Headless Core + CLI)

> **Date:** 2026-06-01 · **Status:** Approved · **Scope:** Engine core library + thin debug CLI.

This is the first sub-project of the Sprout macOS app (see the product spec for
the full vision). It delivers the **headless engine** — all domain logic for
sprouting isolated git-worktree workspaces — plus a thin CLI to drive it
end-to-end against real git/Postgres. No GUI in this phase; the SwiftUI app is a
later sub-project that consumes this engine.

## Scope decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Phase scope | Engine core (worktree → port → DB → env → setup → server) + thin CLI | The hard macOS problems (PATH, supervision, isolation) live here; nail them before UI. |
| Database engines | **Postgres only** | Most common reset+seed workflow. `createdb`/`dropdb`. MySQL/SQLite deferred. |
| Config source | **Injected `Config` struct** | Engine agnostic to where config loaded. TOML loading is a thin separate piece; cleaner test seam. |
| Test strategy | **Protocol `ShellRunner` + fake** | Pure logic tested with no external dep; few gated integration tests for real commands. |
| Deliverable | **Library + thin debug CLI** | CLI drives engine by hand during dev. Not the shipped product. |
| State persistence | **`StateStore` protocol, `JSONStateStore` impl** | SwiftData is UI-tied; engine stays headless. GUI later plugs a SwiftData-backed store. |

## 1. Package layout

SPM workspace, two source targets + tests. Engine has zero AppKit / SwiftUI /
SwiftData dependency.

```
Sprout/  (Package.swift)
├── Sources/
│   ├── SproutEngine/        # library — all domain logic
│   │   ├── Shell/           # ShellRunner protocol + LoginShellRunner impl
│   │   ├── Config/          # Config struct + TemplateRenderer
│   │   ├── Git/             # GitService
│   │   ├── Port/            # PortAllocator
│   │   ├── Database/        # DatabaseService (Postgres)
│   │   ├── Setup/           # SetupRunner
│   │   ├── Server/          # ServerSupervisor
│   │   ├── Env/             # EnvLinker
│   │   ├── State/           # StateStore protocol + JSONStateStore
│   │   └── Workspace/       # WorkspaceManager orchestrator
│   └── sprout-cli/          # thin debug CLI (executable target)
└── Tests/
    └── SproutEngineTests/   # unit (fake shell) + gated integration
```

Consumers: the CLI now, the SwiftUI GUI later. Both depend only on
`SproutEngine`'s public protocols and the `WorkspaceManager` orchestrator.

## 2. Core abstractions (the seams)

Three protocols = three injection seams. Every engine service depends on these,
never on concretes.

### ShellRunner

Everything external runs through this. Solves the GUI-PATH problem (§3.1 of the
product spec): the real impl runs commands through the user's **login shell** so
`nvm`/`asdf`/`rbenv`/Homebrew PATH are all loaded.

```swift
struct ProcessResult: Sendable { let stdout: String; let stderr: String; let exitCode: Int32 }
struct LogLine: Sendable { enum Source { case stdout, stderr }; let source: Source; let text: String }

protocol ShellRunner: Sendable {
    // one-shot: run, wait, collect
    func run(_ command: String, cwd: URL, env: [String: String]) async throws -> ProcessResult
    // streaming: long-running, live log lines
    func stream(_ command: String, cwd: URL, env: [String: String]) -> AsyncThrowingStream<LogLine, Error>
}
```

- **`LoginShellRunner`** — real impl. Resolves shell from `$SHELL` / `getpwuid`,
  default `/bin/zsh`. Invokes `[shell, "-l", "-c", command]`. Caches the resolved
  login-shell PATH at init; `refresh()` re-resolves on demand. Injects per-call
  `env` (carries `PORT`, `DATABASE_URL`) merged over the process environment.
- **`FakeShellRunner`** — test double. Matches command patterns → canned
  `ProcessResult` / scripted streams. Records every call (command, cwd, env) for
  order + content assertions.

### Config

Injected struct. Caller (CLI now, app later) loads it from `.sprout.toml` or an
app-local source; the engine never reads files to get config.

```swift
struct Config: Sendable {
    let project: ProjectConfig          // name
    let worktree: WorktreeConfig        // base dir, branch prefix
    let port: PortConfig                // range lo...hi
    let env: EnvConfig                  // symlink sources, .env.local targets
    let database: DatabaseConfig        // createCmd, dropCmd, urlTemplate
    let setup: [SetupStep]              // ordered: name + command
    let run: RunConfig                  // server command
    let hooks: HooksConfig              // pre/post teardown
}
```

### StateStore

Persisted workspace records — survive CLI invocations, enable reconciliation.

```swift
enum WorkspaceStatus: String, Codable, Sendable {
    case creating, running, crashed, stopped, tearingDown
}

struct WorkspaceRecord: Codable, Sendable {
    let id: UUID
    let branch: String; let base: String
    let worktreePath: String
    let port: Int; let dbName: String
    var status: WorkspaceStatus
    var serverPID: Int32?
    let createdAt: Date
}

protocol StateStore: Sendable {
    func load() throws -> [WorkspaceRecord]
    func upsert(_ r: WorkspaceRecord) throws
    func remove(id: UUID) throws
}
```

`JSONStateStore` writes `~/.sprout/state.json`. GUI later supplies a
SwiftData-backed store implementing the same protocol.

## 3. Services + lifecycle flows

Each service does one job and depends only on protocols.

| Service | Does | Deps |
|---------|------|------|
| `TemplateRenderer` | render `{{project}}`,`{{branch}}`,`{{branch_slug}}`,`{{port}}`,`{{db_name}}`,`{{worktree}}` into any string | none (pure) |
| `GitService` | worktree add/list/remove, `fetch`, branch list, push, dirty-check, branch delete | ShellRunner |
| `PortAllocator` | first free port in range, skip ports held by existing records, probe-bind to confirm | StateStore |
| `DatabaseService` | run rendered `createdb`/`dropdb`, build `DATABASE_URL` | ShellRunner |
| `SetupRunner` | run `[setup]` steps in order, stream logs, stop on non-zero, report failing step index | ShellRunner |
| `ServerSupervisor` | start server (own process group), track PID + status, detect exit, restart, SIGTERM→grace→SIGKILL whole group | ShellRunner |
| `EnvLinker` | symlink shared `.env`, write `.env.local` (PORT, DATABASE_URL) | Foundation |
| `WorkspaceManager` | orchestrate the above for create / teardown / reconcile | all |

### Create flow — `WorkspaceManager.create`

```
render branch_slug → GitService.worktreeAdd(base, branch)
  → PortAllocator.allocate → DatabaseService.create
  → EnvLinker.link + writeLocal → StateStore.upsert(status: creating)
  → SetupRunner.run(steps)  [stream logs]
  → ServerSupervisor.start  → upsert(status: running, pid)
```

Failure mid-way rolls back completed steps in reverse order (drop DB, free port,
remove worktree), per the product-spec §9 error table.

### Teardown flow — `Done`

```
hook.pre → dirty-check (abort unless force) → GitService.push (abort on fail)
  → ServerSupervisor.stop → DatabaseService.drop → GitService.worktreeRemove
  → GitService.branchDelete (unless keep) → hook.post → StateStore.remove
```

`Discard` = same minus the push and the dirty-check.

### Reconcile — CLI startup / `sprout doctor`

```
for each record:
    serverPID alive?      → keep running, else status = stopped
    worktreePath exists?  → else flag record as orphaned
offer cleanup of orphans
```

### Process-group termination

Server spawned in its own process group (`setsid`-equivalent on the `Process`).
Signals sent to `-pgid` so children (e.g. `node` under `npm run dev`) die with
the parent — no orphaned servers holding ports.

## 4. CLI (`sprout-cli`)

Thin: parse args (swift-argument-parser), load `Config` from `.sprout.toml` in
cwd via a small TOML loader, call `WorkspaceManager`, stream logs to stdout.

| Command | Action |
|---------|--------|
| `sprout create --base <b> --branch <n>` | full create flow, stream logs |
| `sprout list` | read StateStore, print branch / port / db / status / PID |
| `sprout server <id> restart\|stop` | ServerSupervisor control |
| `sprout push <id>` | GitService.push |
| `sprout done <id> [--force]` | teardown with push |
| `sprout discard <id>` | teardown without push |
| `sprout doctor` | toolchain check (git/createdb/node on resolved PATH) + reconcile |

## 5. Testing

**Unit** (FakeShellRunner, no external dependency):
- templating: all variables + slug edge cases
- port allocation: skips held ports, probe-bind confirmation
- setup: ordering, stop-on-fail, correct failing-step index
- teardown: ordering, push-abort on failure, dirty-abort
- reconcile: dead PID, alive PID, orphaned worktree
- env: `.env.local` contents (PORT, DATABASE_URL)
- rollback: reverse order on create failure

**Integration** (gated behind `SPROUT_INTEGRATION=1`): real git worktree in a
temp repo, real `createdb`/`dropdb`, real short-lived server process group with
kill verification. Few, high-value.

Framework: Swift Testing. `FakeShellRunner` records calls → assert exact
commands and order.

## Out of scope (this phase)

- SwiftUI app, MenuBarExtra, log console, new-workspace sheet
- SwiftData persistence (engine uses `JSONStateStore`)
- MySQL / SQLite database presets
- Signing, notarization, Sparkle, distribution
- Terminal / zellij integration
- `gh` PR creation, resource view, DB snapshots

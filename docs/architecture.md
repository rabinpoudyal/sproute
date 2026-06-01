# Sprout Architecture

Sprout gives every git branch its own throwaway dev environment on macOS. When you
start work on a branch, Sprout creates a git worktree for it, provisions a dedicated
database, allocates a free port, symlinks shared secrets, runs your setup steps, and
launches a supervised dev server — all driven by a single `.sprout.toml` per project.
When you are done, it tears the whole thing down (optionally pushing first).

This document describes how the code is organized and why.

## 1. High-level shape

The project is a single Swift Package (`Package.swift`, Swift 6, macOS 14+) producing
three products:

| Product | Target | Kind | Role |
|---------|--------|------|------|
| `SproutEngine` | `Sources/SproutEngine` | library | All real logic. Headless, testable, no UI. |
| `sprout` | `Sources/sprout-cli` | executable | Thin ArgumentParser CLI over the engine. |
| `SproutApp` | `Sources/SproutApp` | executable | SwiftUI macOS app (menu bar + window). |

The guiding rule: **the engine holds all business logic; the CLI and the app are thin
clients.** Both build their own composition root (wiring concrete implementations into
the engine's protocols) and add no orchestration of their own. Anything worth testing
lives in the engine.

External dependencies are deliberately minimal:
- `swift-argument-parser` — CLI command parsing (CLI only).
- `TOMLKit` — `.sprout.toml` parsing/serialization (engine only).

```
                +------------------------+      +------------------------+
                |   sprout (CLI)         |      |   SproutApp (SwiftUI)  |
                |  composition root +    |      |  @MainActor view-models|
                |  subcommands           |      |  + views               |
                +-----------+------------+      +-----------+------------+
                            |                               |
                            +---------------+---------------+
                                            v
                            +------------------------------+
                            |        SproutEngine          |
                            |  WorkspaceManager (orchestr.)|
                            |  Config / Git / DB / Port /  |
                            |  Env / Setup / Server / State|
                            +------------------------------+
                                            |
                            login shell  ·  git  ·  postgres  ·  fs  ·  ~/.sprout
```

## 2. The engine

`Sources/SproutEngine` is organized into one folder per concern. Each module owns a
typed error enum and (where it touches the outside world) a protocol seam with a "real"
implementation and a test fake.

### 2.1 Config (`Config/`)

- **`Config.swift`** — the parsed configuration as plain `Sendable` value types:
  `Config` aggregates `ProjectConfig`, `WorktreeConfig`, `PortConfig`, `EnvConfig`,
  `DatabaseConfig`, `[SetupStep]`, `RunConfig`, `HooksConfig`. No behavior, just data.
- **`TOMLConfigLoader.swift` / `TOMLConfigWriter.swift`** — round-trip `.sprout.toml`
  ↔ `Config` via TOMLKit.
- **`TemplateRenderer.swift`** — the `{{var}}` substitution engine. A `TemplateContext`
  (project, branch, port, dbName, worktree) renders into config strings such as
  `createdb {{db_name}}` or `postgres://localhost/{{db_name}}`. Also home to
  `slugify()`, which turns a branch name into a filesystem/identifier-safe slug
  (lowercase, non-alphanumeric runs collapsed to `_`, trimmed). This slug is the
  backbone of derived names: worktree dir, db name, state filename.

### 2.2 Shell (`Shell/`)

Everything that runs an external command goes through the `ShellRunner` protocol, which
has two modes:
- `run(...)` — one-shot: execute, wait, collect `ProcessResult` (stdout/stderr/exit).
- `launch(...)` — long-running: return a `ProcessHandle` exposing the PID, a live
  `AsyncStream<LogLine>` of output, and lifecycle control.

`LoginShellRunner` is the real implementation. Two design decisions matter:

1. **Login shell, not interactive shell.** It runs `$SHELL -l -c`, which sources
   `.zprofile`/`.zlogin` but **not** `.zshrc`. Version managers (rbenv/nvm) usually init
   in `.zshrc`, so commands in `.sprout.toml` must be self-sufficient (e.g. prefix Ruby
   with `rbenv exec`).
2. **Own process group via `posix_spawn` + `POSIX_SPAWN_SETSID`.** `PosixSpawnedProcess`
   launches the dev server in its own session so the whole process tree can be signalled
   by killing the negative PID (`kill(-pid, ...)`). Termination is graceful: `SIGTERM`
   the group, wait the grace period, then `SIGKILL` survivors. Output is pumped off two
   pipes (stdout/stderr) on background queues into the `AsyncStream`.

### 2.3 The provisioning services

Each is a small `Sendable` struct that takes a `ShellRunner` (and often a
`TemplateRenderer`) and does one job:

- **`Git/GitService.swift`** — `worktreeAdd -b`, `worktreeRemove --force`,
  `worktreePrune`, `isDirty` (porcelain), `push -u`, `deleteBranch -D`, `fetch`,
  `branches`. All args are single-quote escaped.
- **`Database/DatabaseService.swift`** — renders and runs the create/drop commands and
  builds the `DATABASE_URL` from `urlTemplate`. DB engine is config-defined (the default
  `.sprout.toml` uses `createdb`/`dropdb`/postgres), so Sprout is not Postgres-specific.
- **`Port/PortAllocator.swift`** — scans the configured `[lower, upper]` range, skips
  ports already held in state, and confirms each candidate is actually free via a
  `PortProber`. `BindPortProber` proves freeness by `bind()`-ing `127.0.0.1:<port>`.
- **`Env/EnvLinker.swift`** — symlinks shared gitignored secrets from the primary repo
  into the worktree, and writes the per-workspace `.env.local` (`PORT`, `DATABASE_URL`).
  It only symlinks **existing** sources and does **not** create parent dirs — so only
  branch-invariant secrets (e.g. `master.key`) should be listed; never `node_modules`,
  `storage`, builds, etc., which diverge per branch. Filesystem access is itself behind
  a `FileSystem` protocol (`RealFileSystem`).
- **`Setup/SetupRunner.swift`** — runs `[SetupStep]` sequentially, streaming each step's
  logs and aborting on the first non-zero exit.

### 2.4 Server supervision (`Server/ServerSupervisor.swift`)

An `actor` that owns the lifecycle of one long-running dev server: `start` → launch via
the shell, record status, spawn a background task to stream logs and another to watch
for exit. `stop`/`restart` drive graceful termination. It distinguishes an **expected**
shutdown (`stopping` flag set → `.stopped`) from a crash (unexpected non-zero exit →
`.crashed`). Status: `starting / running / crashed / stopped`.

### 2.5 State (`State/`)

- **`StateStore.swift`** — the `StateStore` protocol plus the persisted model:
  `WorkspaceRecord` (id, branch, base, worktreePath, port, dbName, status, serverPID,
  createdAt) and `WorkspaceStatus`.
- **`JSONStateStore`** — JSON-file-backed implementation. State is the source of truth
  for "what workspaces exist" and is what lets port allocation, reconciliation, and
  teardown work across separate process invocations.

### 2.6 Orchestration (`Workspace/`)

**`WorkspaceManager.swift`** is the heart of the engine — the only type that composes
all the services. It is a `Sendable` struct injected with every dependency (so tests
wire fakes). Three public operations:

- **`create(config, repo, base, branch, onLog:)`** — the full provisioning pipeline:
  1. Resolve the worktree path. A **relative `base_dir` is anchored to the repo, not the
     process cwd**, because git resolves it relative to the repo; otherwise git and the
     file APIs would disagree.
  2. `git worktree add -b` → allocate port → create DB → symlink env + write
     `.env.local` → persist a `creating` record → run setup steps → start the server →
     persist a `running` record with the PID.
  3. **Transactional rollback.** Every step tracks what it did; on any failure it
     reverses in order (drop DB, remove worktree dir, prune, **delete the branch that
     `add -b` created**), so a retry of the same branch name is not blocked by leftovers.
- **`teardown(id, config, repo, push, force)`** — optional pre-hook → optional push
  (refusing a dirty worktree unless `force`) → terminate the server's process group →
  drop DB → remove worktree → delete branch → optional post-hook → drop the record.
- **`reconcile()`** — reality-check persisted state against the OS: mark `running`
  records whose PID is dead as `stopped`, and flag records whose worktree dir has
  vanished as `orphaned`. This is how a fresh process (CLI invocation or app launch)
  recovers an accurate view of the world.

`DoctorService.swift` is a standalone diagnostic: `command -v` each required tool and
report presence/path.

Process lifecycle helpers (`ProcessChecker`/`PosixProcessChecker` via `kill(pid,0)`,
`ProcessTerminator`/`PosixProcessTerminator`) live alongside the manager.

## 3. The CLI (`Sources/sprout-cli/Sprout.swift`)

A single file. The top is a **composition root** (`makeManager`) that wires the real
implementations — `LoginShellRunner`, `GitService`, `PortAllocator(BindPortProber)`,
`DatabaseService`, `EnvLinker(RealFileSystem)`, `SetupRunner`, `JSONStateStore`,
`PosixProcessChecker/Terminator` — into a `WorkspaceManager`. Config is loaded from
`./.sprout.toml`; state from `~/.sprout/state.json`; the repo is the cwd.

Subcommands map almost one-to-one onto engine operations: `create`, `list`, `server
<id> stop|restart`, `push`, `done` (teardown + push), `discard` (teardown, no push,
forced), `doctor` (tool check + reconcile). Logs print straight to stdout.

> **Gotcha:** the one-shot CLI `create` exits when the command returns, which closes the
> server's stdout pipe → the dev server gets EPIPE and dies. That is expected; the GUI
> keeps pipes open so the server keeps running. For a persistent server from the CLI you
> manage it separately.

## 4. The app (`Sources/SproutApp`)

A SwiftUI multi-project app with a dual surface: a menu bar dropdown and a main control
window, plus detachable log windows. It mirrors the CLI's thin-client philosophy — the
view-models own engine types and translate between engine state and SwiftUI's
observation model. All view-models are `@MainActor ObservableObject`s.

### 4.1 Entry & lifecycle (`Views/SproutAppMain.swift`)

`@main App` declaring four scenes: the main `WindowGroup`, a `MenuBarExtra`, a
per-target detached log `WindowGroup<LogTarget>`, and `Settings`. An `AppDelegate`
forces `.regular` activation policy on launch — without it, `MenuBarExtra` runs the app
as an accessory and the main window can't take keyboard focus (modals wouldn't receive
typed input).

### 4.2 Model / state layer (`Model/`)

- **`AppModel`** — top-level state: the roster of projects and an aggregate status for
  the menu bar. Owns the `ProjectRegistry`, loads/saves `Config` via the engine's
  TOML loader/writer, and creates a `ProjectStore` per registered project.
- **`ProjectStore`** — the per-project view-model and the app's bridge to the engine. It
  owns a `WorkspaceManager`, a `JSONStateStore` (`~/.sprout/state/<slug>.json`), and
  per-workspace `LogBuffer`s and `ServerSupervisor`s. Exposes `create`, server
  start/stop, `teardown`, `push`, `refresh` (which calls `reconcile()`).
- **`ConfigDraft`** — an editable, validatable mirror of `Config` for the config form
  (numbers as strings, identifiable rows). `build()` validates and converts back to a
  `Config`; invalid input throws `DraftError`.
- **`LogBuffer`** — bounded (5000-line FIFO), observable log store per workspace, with a
  pause flag (pauses display, never drops lines).
- **`ProjectRegistry`** — `Codable, Sendable` list of project root paths, persisted to
  `~/.sprout/projects.json`.
- **`SproutPaths`** — central definition of `~/.sprout` locations.
- **`AppError`** — maps engine error enums (`GitError`, `DatabaseError`, `SetupError`,
  `PortError`, `TeardownError`, `ConfigError`) to user-facing title + detail.

### 4.3 View layer (`Views/`)

```
SproutAppMain
├── MainWindow
│   ├── Sidebar (projects / workspaces)
│   └── Detail
│       ├── WorkspaceDetailView ── LogConsoleView
│       ├── ProjectOverviewView ── ConfigFormView (tabbed: Basic/Configs/Env/Hooks)
│       ├── CreateWorkspaceSheet ── LogConsoleView (live setup logs)
│       └── CreateProjectSheet  ── ConfigFormView
├── MenuBarContentView (per-workspace rows: status + port + start/stop)
├── Settings → SettingsView
└── DetachedLogWindow → LogConsoleView
```

`ErrorBanner` and `StatusBadge` are shared building blocks. `ConfigFormView` is the
recently added Xcode-preferences-style tabbed config editor.

### 4.4 Log streaming into the UI

The engine emits `LogLine`s from background contexts. `ProjectStore` hands the engine a
`@Sendable (LogLine) -> Void` closure that hops back to the main actor
(`Task { @MainActor in buffer.append(line) }`) and appends to the workspace's
`LogBuffer`. SwiftUI observes the buffer and re-renders `LogConsoleView`. This is the
single path from `ServerSupervisor`/`SetupRunner` output to the screen.

## 5. Concurrency model

Swift 6 strict concurrency throughout, kept warning-free:
- **Value types are `Sendable`** (`Config`, `WorkspaceRecord`, `LogLine`, …).
- **Stateful concurrency is an `actor`** (`ServerSupervisor`).
- **UI state is `@MainActor`** (all app view-models), which makes them implicitly
  `Sendable`; background closures capture them via `Task { @MainActor in … }`.
- **External-world access is behind protocols** (`ShellRunner`, `FileSystem`,
  `StateStore`, `PortProber`, `ProcessChecker`, `ProcessTerminator`), enabling fakes in
  unit tests and real implementations in the composition roots.

## 6. State & paths

- Project registry (app): `~/.sprout/projects.json`.
- Per-project state (app): `~/.sprout/state/<slug>.json`.
- Single state file (CLI): `~/.sprout/state.json`.
- Worktrees: under each project's configured `worktree.base_dir`.

State files are the durable contract that lets independent process invocations
(`sprout` runs, app launches) agree on what exists, which ports are taken, and what to
reconcile or tear down.

## 7. Testing

- **Framework:** Swift Testing (`@Test`/`#expect`), not XCTest.
- **Unit tests** inject fakes (`Tests/SproutEngineTests/Support/`) and never touch the
  real shell/fs/git. There is one fake or fixture per engine seam.
- **Integration tests** (real git worktrees, real process kills) are gated behind the
  `SPROUT_INTEGRATION=1` environment variable.
- `swift test` requires the Xcode `xctest` runner; `SproutEngineTests` carries
  `unsafeFlags` pointing at the CommandLineTools frameworks.

## 8. Design principles (summary)

1. **Engine is the brain; clients are thin.** No business logic in CLI or app.
2. **Protocol seams at every system boundary.** Real impls in composition roots, fakes
   in tests.
3. **Config-driven, not hardcoded.** DB engine, ports, setup, env, hooks all come from
   `.sprout.toml` + template rendering.
4. **Transactional provisioning.** `create` rolls back fully on any failure.
5. **State is reconcilable.** The OS is the source of truth; persisted state is
   reality-checked on every fresh process.

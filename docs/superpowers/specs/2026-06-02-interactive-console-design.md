# Interactive Console (rails console) inside SproutApp — Design

Date: 2026-06-02
Status: Approved (pending spec review)

## Goal

Run an interactive REPL (e.g. `rails console`) directly inside the SproutApp
GUI, per workspace, so the user can inspect a running app without leaving the
tool. The console must behave like a real terminal session: arrow-key history,
tab completion, colors, multi-line editing.

## Key Constraint

A plain pipe-backed child process makes IRB/Pry tty-detect to `false` and drop
into "dumb" mode (no readline, no completion, no color, broken prompts). A real
interactive console requires a **pseudo-terminal (PTY)**. Rendering a PTY
stream requires a VT100/ANSI terminal emulator.

## Decisions (from brainstorming)

- **Fidelity:** full interactive PTY-backed terminal (not a line REPL).
- **Emulator:** use **SwiftTerm** (Miguel de Icaza, MIT) rather than hand-rolling
  an emulator. New third-party dependency.
- **Console definition:** multiple named consoles via a `[[run.console]]` array
  in `.sprout.toml` (generic — works for rails, db, node, psql, etc.).
- **UI placement:** inline in `WorkspaceDetailView` with pop-out to a detached
  window (mirrors how logs already work).
- **Supervision scope:** survive tab/window close (A), show in process list with
  start/stop controls (B), killed on workspace teardown (D). Do **not** survive
  app restart (C skipped — PTY child dies with parent; daemonizing rejected).

## Architecture — two layers

SwiftTerm is an AppKit dependency; `SproutEngine` is headless and shared with the
CLI, which must not gain a terminal-emulator dependency. Responsibilities split:

### Engine layer (`SproutEngine`) — process truth, no SwiftTerm

- **PTY spawner** using `forkpty(3)`: launches the login shell over a real
  pseudo-terminal so the child tty-detects `true` and runs fully interactive.
  Exposes:
  - `output: AsyncStream<Data>` — raw bytes from the PTY master
  - `send(_ data: Data)` — write user input to the PTY master
  - `resize(cols:rows:)` — `TIOCSWINSZ` on window resize
  - `terminate(graceSeconds:)`, `waitForExit() -> Int32`, `pid`
  - Injected via a `PTYSpawner` protocol seam (mirrors `ShellRunner`) so tests
    inject a fake.
- **`actor ConsoleSupervisor`** — owns live console sessions per workspace.
  - `start(consoleName:workspace:env:cwd:) -> ConsoleSession`
  - `stop(id:)`, `list(workspace:)`, `killAll(workspace:)`
  - Tracks PID + status (`running`, `exited`). Authority for supervision (B) and
    teardown-kill (D).
  - Kept **separate** from `ServerSupervisor` — its pipe/log-only model does not
    fit bidirectional PTY I/O.
- **`ConsoleSession`** — value/handle exposing id, configured name, pid, status,
  `output`, `send`, `resize`.

### App layer (`SproutApp`) — emulator + view, owns SwiftTerm

- **`ConsoleSessionStore`** (`@MainActor ObservableObject`) — for each engine
  session, holds a live SwiftTerm `Terminal`/view; pumps engine `output` →
  terminal feed and terminal keystrokes → engine `send`. Lives **outside** the
  SwiftUI view, keyed by session id. This persistence is what makes a console
  survive tab/window close with scrollback intact (A).
- **`ConsoleView: NSViewRepresentable`** wrapping SwiftTerm's terminal view,
  bound to a store session. View disappearance detaches only; it does NOT kill
  the PTY.

Bridge between layers = session id + the byte streams. Engine never imports
SwiftTerm.

## Config & environment

New `[[run.console]]` array in `.sprout.toml`, mirroring `[[run.process]]`:

```toml
[[run.console]]
name = "rails"
command = "rbenv exec ruby bin/rails console"

[[run.console]]
name = "db"
command = "rbenv exec ruby bin/rails dbconsole"
```

- New `ConsoleConfig` struct (`name`, `command`) in `Config.swift`, parsed in
  `TOMLConfigLoader` like `ProcessConfig`. `command` gets the same `{{var}}`
  template rendering.
- Empty/absent array → no console UI is shown.

**Environment:** the console must receive the exact same resolved env the dev
server gets (DB name, allocated port, symlinked secrets, local env file),
otherwise `rails console` connects to the wrong DB. Reuse whatever
`WorkspaceManager` builds for `ServerSupervisor.start`; pass it (plus workspace
cwd) into `ConsoleSupervisor.start`. The `rbenv exec` prefix stays in the user's
config command per the rbenv login-shell gotcha; the PTY runs it via
`$SHELL -l -c "cd <worktree> && <command>"`.

## UI, lifecycle, teardown

### UI (`WorkspaceDetailView`)

- Existing picker (Logs + processes) extended with a section per **running**
  console session.
- A menu/"+" button lists configured console names → starts a new session and
  selects it.
- Selected console renders `ConsoleView` (SwiftTerm) in the same pane where
  `LogConsoleView` renders.
- Pop-out button → `DetachedConsoleWindow`, mirroring `DetachedLogWindow` (reuse
  the `LogTarget` pattern → `ConsoleTarget`). Closing the pop-out detaches the
  view; the session keeps running (A).

### Process list (B)

- View-model merges persisted server processes + live console sessions. Consoles
  show name, status (`running`/`exited`), with **Stop** and **Restart** (restart
  = kill + fresh spawn).
- Consoles are NOT written to `state.json` (no app-restart survival — C
  skipped), so they vanish on app quit.

### Lifecycle

- Start: on-demand when the user picks a console name.
- Tab/window close: detach only.
- App quit: all PTYs die with the app (acceptable; C skipped).
- **Teardown (D):** `WorkspaceManager.teardown` calls
  `ConsoleSupervisor.killAll(workspace)` alongside the server stop, so no
  `rails console` leaks while holding a DB connection.

## Testing

- `ConsoleSupervisor` unit-tested with a fake `PTYSpawner`: start/stop/list/
  killAll, and teardown-kills-consoles.
- Real `forkpty` spawner exercised by an integration test gated behind
  `SPROUT_INTEGRATION`.
- App/SwiftTerm view kept thin; not unit-tested.

## Out of scope

- Surviving app restart / daemonized consoles (C).
- Auto-detecting rails without config.
- Folding console PTYs into `ServerSupervisor`.

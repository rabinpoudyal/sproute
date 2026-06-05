# Bottom-Drawer Interactive Shell — Design

**Date:** 2026-06-05
**Status:** Approved (pending spec review)

## Goal

A per-workspace interactive shell that pops open as a full-width bottom drawer in the
main window. The user toggles it with a toolbar button or `⌘J`, types arbitrary commands
in the selected workspace's worktree, and the session persists in the background when the
drawer is closed.

## Behavior (agreed)

- **Scope:** per-workspace. The shell runs in the selected workspace's worktree (`cwd =
  worktreePath`) with the same child env the workspace's processes get (`PORT`,
  `DATABASE_URL`).
- **Shell flavor:** interactive login shell (`$SHELL -l -i`), so `.zshrc` loads and
  rbenv/nvm/aliases work — unlike the engine's existing `$SHELL -l -c` paths.
- **Lifecycle:** one persistent shell session per workspace. Closing the drawer hides the
  view but keeps the session (and any running command) alive. Reopening reattaches to the
  same SwiftTerm buffer. Switching the selected workspace swaps the drawer to that
  workspace's own session.
- **Toggle:** a toolbar button **and** `⌘J`. Disabled/hidden when the current sidebar
  selection is not a workspace.
- **Placement:** full-width drawer at the bottom of the detail pane, with a drag-to-resize
  handle; height persisted across launches.
- **Teardown:** tearing down a workspace kills its shell session along with its consoles.

## Architecture

Reuse the existing PTY stack (`ForkPTYSpawner` → `PTYHandle`, `ConsoleSupervisor`,
`ConsoleSessionController`, `ConsoleView`). The shell is a PTY session like a console, but
(a) spawned **interactively** (no `-c command`) and (b) tracked separately so it never
appears in the console list. The engine gains a real interactive-spawn path rather than a
magic command string.

### Engine changes (`Sources/SproutEngine/`)

**`Shell/PTYProcess.swift`**
- Add to the `PTYSpawner` protocol:
  ```swift
  func spawnInteractive(cwd: URL, env: [String: String]) throws -> PTYHandle
  ```
- Generalize `ForkPTYProcess` to take its argv explicitly (a designated init taking
  `argv: [String]`), and keep the command path building `[shell, "-l", "-c", command]`.
  The interactive path builds `[shell, "-l", "-i"]` (login + interactive: sources
  `.zprofile`/`.zlogin` **and** `.zshrc`).
- `ForkPTYSpawner.spawnInteractive` merges process env with `env` (same as `spawn`) and
  constructs the interactive `ForkPTYProcess`.
- Factor the argv construction into a tiny testable helper, e.g.
  `static func loginShellArgs(_ shell: String, command: String) -> [String]` and
  `static func interactiveShellArgs(_ shell: String) -> [String]`, so the argv is unit-
  testable without forking.

**`Console/ConsoleSupervisor.swift`**
- Add `enum SessionKind { case console, shell }` and store `kind` on `Entry`.
- New method:
  ```swift
  @discardableResult
  func startShell(
      branch: String, cwd: URL, env: [String: String],
      onExit: @escaping @Sendable (_ id: UUID, _ code: Int32) -> Void
  ) throws -> ConsoleSession
  ```
  spawns via `spawner.spawnInteractive(cwd:env:)`, registers an `Entry` with `kind:
  .shell` and `name: "shell"`, and wires the same natural-exit watcher as `start`.
- `list(branch:)` returns only `.console` entries (shells are not consoles, so the console
  picker is unaffected).
- Add `func shell(branch:) -> ConsoleSessionInfo?` returning the `.shell` entry if any.
- `killAll(branch:)` is unchanged — it already iterates all entries for the branch, so it
  kills the shell too.

### App changes (`Sources/SproutApp/`)

**`Model/ProjectStore.swift`**
- Add `private var shellControllers: [String: ConsoleSessionController] = [:]` keyed by
  branch.
- `func shellController(branch: String) -> ConsoleSessionController?`.
- `func openShell(_ item: WorkspaceItem) async` — if a controller already exists for the
  branch, no-op; otherwise call `consoleSupervisor.startShell(branch:cwd:env:onExit:)`
  with `cwd = worktreePath` and `env = childEnv(rec)`, build a `ConsoleSessionController`,
  store it in `shellControllers[branch]`. The `onExit` closure drops the controller for
  that branch (user typed `exit`/Ctrl-D or it crashed); the next open starts fresh.
- In `teardown(...)`, after `killAll(branch:)`, also `shellControllers[branch]?.stop()`
  and `shellControllers[branch] = nil`.

**`Views/MainWindow.swift` / `Views/DetailContainer`**
- `DetailContainer` wraps its current detail content in a `VStack` with the shell drawer
  pinned to the bottom, shown only when `drawerVisible` **and** the selection is a
  workspace. The drawer is the detail pane's full width.
- Drawer visibility lives as `@State private var drawerVisible` in `MainWindow`; drawer
  height as `@AppStorage("shellDrawerHeight")` (default ~240). A drag handle on the
  drawer's top edge updates the stored height (clamped to a sane min/max).
- A toolbar `Button` (terminal icon) toggles `drawerVisible` and carries
  `.keyboardShortcut("j", modifiers: .command)`, satisfying both the button and `⌘J`
  requirements with one control. It is `.disabled` unless the selection is a workspace.
- The toggle and drawer need the selected workspace's `ProjectStore` + `WorkspaceItem`;
  `MainWindow` already resolves these via `selection` + `app.projects`. Pass them down to
  `DetailContainer` (or resolve there as it already does for the detail switch).

**`Views/ShellDrawer.swift` (new)**
- Inputs: `project: ProjectStore`, `item: WorkspaceItem`, `height: Binding<CGFloat>`,
  `onClose: () -> Void`.
- A top bar: drag handle, title `shell — <branch>`, and a close (chevron-down) button
  calling `onClose`.
- Body: if `project.shellController(branch:)` exists, render `ConsoleView(controller:)`;
  otherwise a brief "Starting shell…" placeholder. On appear (and when the resolved
  workspace changes) call `await project.openShell(item)` to lazily start the session.
- Reuses the existing `ConsoleView` `NSViewRepresentable` for the terminal.

## Data flow

1. User selects a workspace, presses `⌘J` → `drawerVisible = true`.
2. `ShellDrawer.onAppear` → `project.openShell(item)`.
3. `ProjectStore` asks `ConsoleSupervisor.startShell` → `ForkPTYSpawner.spawnInteractive`
   forks `$SHELL -l -i` in the worktree with the workspace env → returns a `PTYHandle`.
4. A `ConsoleSessionController` pumps PTY output into a SwiftTerm `TerminalView`;
   keystrokes/resize flow back through the handle. `ConsoleView` embeds that view.
5. Closing the drawer sets `drawerVisible = false` (view detaches; controller + PTY stay
   alive in `shellControllers`). Reopening re-embeds the same `TerminalView`.
6. Workspace teardown → `killAll(branch:)` SIGTERMs the shell PG; controller dropped.

## Error handling

- `spawnInteractive` failure → `startShell` throws → `openShell` sets `lastError`
  (existing `AppError` surfacing); the drawer shows the placeholder.
- Natural shell exit → `onExit` drops the controller; the drawer shows the placeholder
  until reopened/restarted (next `openShell` spawns a fresh session).

## Testing

Engine (Swift Testing, with fakes — no real fork in unit tests):
- `interactiveShellArgs` / `loginShellArgs` produce the expected argv (`["zsh","-l","-i"]`
  vs `["zsh","-l","-c", cmd]`).
- `FakePTYSpawner` gains `spawnInteractive(cwd:env:)` (records the call, returns a
  `FakePTYHandle`).
- `ConsoleSupervisor.startShell`: spawns via the interactive path; the shell is **absent**
  from `list(branch:)`, **present** via `shell(branch:)`; `killAll(branch:)` terminates it
  and the natural-exit watcher drops it.

App layer follows the existing convention (no SwiftUI view tests): verified by `swift
build` + manual smoke (toggle `⌘J`, run `ruby -v` / `echo $PORT` in the drawer, confirm
rbenv/env present and that closing/reopening preserves scrollback).

## Out of scope

- Multiple shells per workspace / shell tabs (one per workspace for v1).
- Persisting shell sessions across app restarts (consoles already don't; same here).
- A restart button in the drawer (reopening after `exit` starts a fresh shell; an explicit
  restart control can come later).

# Bottom-Drawer Interactive Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-workspace interactive shell that pops open as a full-width bottom drawer in the main window, toggled by a toolbar button or `⌘J`, running an interactive login shell in the selected workspace's worktree.

**Architecture:** Reuse the existing PTY stack (`ForkPTYSpawner`/`PTYHandle`, `ConsoleSupervisor`, `ConsoleSessionController`, `ConsoleView`). Add a real interactive spawn path (`$SHELL -l -i`, no `-c command`) so `.zshrc` loads. The shell is tracked in `ConsoleSupervisor` as `kind: .shell` — killed by `killAll`/teardown but excluded from the console list. `ProjectStore` keeps one persistent shell session per workspace branch; a new `ShellDrawer` SwiftUI view embeds it.

**Tech Stack:** Swift 6 (strict concurrency), Swift Package (SproutEngine / sprout-cli / SproutApp), SwiftTerm, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-05-bottom-drawer-shell-design.md`

---

## File Structure

**Engine (`Sources/SproutEngine/`)**
- `Shell/PTYProcess.swift` — add `spawnInteractive` to `PTYSpawner`; argv helpers on `ForkPTYSpawner`; generalize `ForkPTYProcess` to take `argv`.
- `Console/ConsoleSupervisor.swift` — `SessionKind`, `Entry.kind`, `startShell`, `list` filters to `.console`, `shell(branch:)` accessor.

**App (`Sources/SproutApp/`)**
- `Model/ProjectStore.swift` — `shellControllers` map, `shellController(branch:)`, `openShell`, teardown hook.
- `Views/ShellDrawer.swift` — **new**, the drawer view.
- `Views/MainWindow.swift` — toolbar toggle (`⌘J`), embed `ShellDrawer` at the bottom of the detail pane, drag-resize, `@AppStorage` height.

**Tests (`Tests/SproutEngineTests/`)**
- `PTYProcessTests.swift` — argv-helper tests (pure, non-integration).
- `Support/FakePTYSpawner.swift` — conform to the new `spawnInteractive`.
- `ConsoleSupervisorTests.swift` — `startShell` tests.

---

## Task 1: Engine — interactive PTY spawn path

**Files:**
- Modify: `Sources/SproutEngine/Shell/PTYProcess.swift:25-42` (protocol + `ForkPTYSpawner`), `:67-92` (`ForkPTYProcess.init`)
- Modify: `Tests/SproutEngineTests/Support/FakePTYSpawner.swift:48-62`
- Modify: `Tests/SproutEngineTests/PTYProcessTests.swift`

> The engine target only compiles once `FakePTYSpawner` also conforms to the new protocol method (the test target imports it). Make all edits in this task, then build + test.

- [ ] **Step 1: Write the failing argv-helper test**

Add to `Tests/SproutEngineTests/PTYProcessTests.swift` (inside the `PTYProcessTests` suite, after `sendWritesToChildStdin`):

```swift
    @Test func loginArgsWrapCommand() {
        #expect(ForkPTYSpawner.loginArgs("/bin/zsh", "tty")
            == ["/bin/zsh", "-l", "-c", "tty"])
    }

    @Test func interactiveArgsAreLoginInteractive() {
        #expect(ForkPTYSpawner.interactiveArgs("/bin/zsh")
            == ["/bin/zsh", "-l", "-i"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PTYProcessTests`
Expected: FAIL — `type 'ForkPTYSpawner' has no member 'loginArgs'` / `interactiveArgs`.

- [ ] **Step 3: Generalize `ForkPTYProcess` to take argv**

In `Sources/SproutEngine/Shell/PTYProcess.swift`, change the `ForkPTYProcess` initializer signature and the argv line. Replace the init signature (line 67) and the `argv` construction (line 70):

Current:
```swift
    init(shellPath: String, command: String, cwd: String, env: [String: String]) throws {
        // Build all C arrays BEFORE forking — only async-signal-safe calls (chdir, execve,
        // _exit) may run in the child between fork and exec.
        let argv = [shellPath, "-l", "-c", command]
```

New:
```swift
    init(shellPath: String, argv: [String], cwd: String, env: [String: String]) throws {
        // Build all C arrays BEFORE forking — only async-signal-safe calls (chdir, execve,
        // _exit) may run in the child between fork and exec.
```

(Delete the old `let argv = [shellPath, "-l", "-c", command]` line — `argv` is now the parameter. Everything below that uses `argv` and `shellPath` unchanged.)

- [ ] **Step 4: Add argv helpers + `spawnInteractive` to `ForkPTYSpawner`**

Replace the `ForkPTYSpawner` struct (lines 32-42) with:

```swift
public struct ForkPTYSpawner: PTYSpawner {
    private let shellPath: String
    public init(shellPath: String? = nil) {
        self.shellPath = shellPath ?? LoginShellRunner.resolveLoginShell()
    }

    /// `$SHELL -l -c <command>`: login (non-interactive) — matches `LoginShellRunner`.
    static func loginArgs(_ shell: String, _ command: String) -> [String] {
        [shell, "-l", "-c", command]
    }
    /// `$SHELL -l -i`: login + interactive, so `.zshrc` (rbenv/nvm/aliases) loads.
    static func interactiveArgs(_ shell: String) -> [String] {
        [shell, "-l", "-i"]
    }

    public func spawn(command: String, cwd: URL, env: [String: String]) throws -> PTYHandle {
        let merged = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        return try ForkPTYProcess(
            shellPath: shellPath, argv: Self.loginArgs(shellPath, command),
            cwd: cwd.path, env: merged)
    }

    public func spawnInteractive(cwd: URL, env: [String: String]) throws -> PTYHandle {
        let merged = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        return try ForkPTYProcess(
            shellPath: shellPath, argv: Self.interactiveArgs(shellPath),
            cwd: cwd.path, env: merged)
    }
}
```

- [ ] **Step 5: Add `spawnInteractive` to the `PTYSpawner` protocol**

In `Sources/SproutEngine/Shell/PTYProcess.swift`, replace the protocol (lines 25-27):

```swift
public protocol PTYSpawner: Sendable {
    func spawn(command: String, cwd: URL, env: [String: String]) throws -> PTYHandle
    func spawnInteractive(cwd: URL, env: [String: String]) throws -> PTYHandle
}
```

- [ ] **Step 6: Conform `FakePTYSpawner` to `spawnInteractive`**

In `Tests/SproutEngineTests/Support/FakePTYSpawner.swift`, add an `interactiveSpawns` recorder and the method. Replace the `FakePTYSpawner` class (lines 48-62) with:

```swift
final class FakePTYSpawner: PTYSpawner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var handles: [FakePTYHandle] = []
    private(set) var commands: [String] = []
    private(set) var interactiveCount = 0
    private var nextPid: Int32 = 1000

    func spawn(command: String, cwd: URL, env: [String: String]) throws -> PTYHandle {
        lock.lock(); defer { lock.unlock() }
        commands.append(command)
        let h = FakePTYHandle(pid: nextPid)
        nextPid += 1
        handles.append(h)
        return h
    }

    func spawnInteractive(cwd: URL, env: [String: String]) throws -> PTYHandle {
        lock.lock(); defer { lock.unlock() }
        interactiveCount += 1
        let h = FakePTYHandle(pid: nextPid)
        nextPid += 1
        handles.append(h)
        return h
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter PTYProcessTests`
Expected: PASS (both new argv tests; integration-gated tests still skip without `SPROUT_INTEGRATION`).

- [ ] **Step 8: Build whole package + lint**

Run: `swift build`
Expected: `Build complete!` no warnings.

Run: `swift format lint -r Sources Tests`
Expected: no output.

- [ ] **Step 9: Commit**

```bash
git add Sources/SproutEngine/Shell/PTYProcess.swift Tests/SproutEngineTests/Support/FakePTYSpawner.swift Tests/SproutEngineTests/PTYProcessTests.swift
git commit -m "feat: interactive PTY spawn path ($SHELL -l -i)"
```

---

## Task 2: Engine — ConsoleSupervisor.startShell + kind filtering

**Files:**
- Modify: `Sources/SproutEngine/Console/ConsoleSupervisor.swift:26-89`
- Modify: `Tests/SproutEngineTests/ConsoleSupervisorTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/SproutEngineTests/ConsoleSupervisorTests.swift` (inside the suite, after `naturalExitFiresCallbackAndDropsSession`):

```swift
    @Test func startShellSpawnsInteractiveAndStaysOutOfConsoleList() async throws {
        let spawner = FakePTYSpawner()
        let sup = ConsoleSupervisor(spawner: spawner, renderer: TemplateRenderer())
        let session = try await sup.startShell(
            branch: "feature/x", cwd: URL(fileURLWithPath: "/tmp/wt"),
            env: ["PORT": "4000"], onExit: { _, _ in })
        #expect(spawner.interactiveCount == 1)
        #expect(spawner.commands.isEmpty)  // interactive: no -c command
        // A shell is not a console — the console list must not include it.
        #expect(await sup.list(branch: "feature/x").isEmpty)
        // But it is reachable as the branch's shell.
        let shell = await sup.shell(branch: "feature/x")
        #expect(shell?.id == session.id)
        #expect(shell?.name == "shell")
    }

    @Test func killAllAlsoTerminatesShell() async throws {
        let spawner = FakePTYSpawner()
        let sup = ConsoleSupervisor(spawner: spawner, renderer: TemplateRenderer())
        _ = try await sup.startShell(
            branch: "feature/x", cwd: URL(fileURLWithPath: "/tmp/wt"),
            env: [:], onExit: { _, _ in })
        await sup.killAll(branch: "feature/x")
        #expect(await sup.shell(branch: "feature/x") == nil)
        #expect(spawner.handles.first?.terminated == true)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConsoleSupervisorTests`
Expected: FAIL — `value of type 'ConsoleSupervisor' has no member 'startShell'` / `shell`.

- [ ] **Step 3: Add `SessionKind` + `kind` on `Entry`**

In `Sources/SproutEngine/Console/ConsoleSupervisor.swift`, add the enum after the `ConsoleStatus` enum (after line 3):

```swift
public enum SessionKind: Sendable, Equatable { case console, shell }
```

Replace the private `Entry` struct (lines 27-32) to carry `kind`:

```swift
    private struct Entry {
        let branch: String
        let name: String
        let kind: SessionKind
        let handle: PTYHandle
        var status: ConsoleStatus
    }
```

- [ ] **Step 4: Set `kind: .console` in the existing `start`**

In `start` (the `entries[id] = Entry(...)` line, currently line 54), add the `kind`:

```swift
        entries[id] = Entry(
            branch: branch, name: name, kind: .console, handle: handle, status: .running)
```

- [ ] **Step 5: Add `startShell`**

In `Sources/SproutEngine/Console/ConsoleSupervisor.swift`, add this method after `start` (after its closing brace, ~line 63):

```swift
    /// Spawns an interactive login shell session (`kind: .shell`) for `branch`. Unlike
    /// `start`, there is no command/template: the shell is interactive so `.zshrc` loads.
    /// Shell sessions are excluded from `list` (they are not consoles) but are killed by
    /// `killAll`. `onExit` fires on natural exit (user typed `exit`/Ctrl-D, or crash).
    @discardableResult
    public func startShell(
        branch: String, cwd: URL, env: [String: String],
        onExit: @escaping @Sendable (_ id: UUID, _ code: Int32) -> Void
    ) throws -> ConsoleSession {
        let handle = try spawner.spawnInteractive(cwd: cwd, env: env)
        let id = UUID()
        entries[id] = Entry(
            branch: branch, name: "shell", kind: .shell, handle: handle, status: .running)
        Task { [weak self] in
            let code = await handle.waitForExit()
            await self?.markExited(id: id)
            onExit(id, code)
        }
        return ConsoleSession(id: id, branch: branch, name: "shell", handle: handle)
    }
```

- [ ] **Step 6: Filter `list` to consoles + add `shell(branch:)`**

Replace `list(branch:)` (lines 77-85) with a `.console`-only filter, and add `shell(branch:)`:

```swift
    public func list(branch: String) -> [ConsoleSessionInfo] {
        entries
            .filter { $0.value.branch == branch && $0.value.kind == .console }
            .map {
                ConsoleSessionInfo(
                    id: $0.key, branch: $0.value.branch, name: $0.value.name,
                    pid: $0.value.handle.pid, status: $0.value.status)
            }
    }

    /// The branch's interactive shell session, if one is running.
    public func shell(branch: String) -> ConsoleSessionInfo? {
        entries
            .filter { $0.value.branch == branch && $0.value.kind == .shell }
            .map {
                ConsoleSessionInfo(
                    id: $0.key, branch: $0.value.branch, name: $0.value.name,
                    pid: $0.value.handle.pid, status: $0.value.status)
            }
            .first
    }
```

(`killAll(branch:)` is unchanged — it already filters by branch across all kinds, so it terminates the shell too.)

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter ConsoleSupervisorTests`
Expected: PASS (the two new tests plus the four existing console tests, which still see `.console` entries in `list`).

- [ ] **Step 8: Build + lint**

Run: `swift build`
Expected: `Build complete!` no warnings.

Run: `swift format lint -r Sources Tests`
Expected: no output.

- [ ] **Step 9: Commit**

```bash
git add Sources/SproutEngine/Console/ConsoleSupervisor.swift Tests/SproutEngineTests/ConsoleSupervisorTests.swift
git commit -m "feat: ConsoleSupervisor.startShell for interactive drawer shells"
```

---

## Task 3: App — ProjectStore shell session management

**Files:**
- Modify: `Sources/SproutApp/Model/ProjectStore.swift:47` (add map), `:239-270` (Consoles section — add shell methods), `:322-342` (`teardown`)

> No unit tests: `ProjectStore` is `@MainActor` with live side effects and the project has no view/store tests (consistent with existing convention). Verified by build + Task 4's manual smoke.

- [ ] **Step 1: Add the `shellControllers` map**

In `Sources/SproutApp/Model/ProjectStore.swift`, after the `consoleControllers` property (line 47), add:

```swift
    private var shellControllers: [String: ConsoleSessionController] = [:]
```

- [ ] **Step 2: Add `shellController` + `openShell`**

In the `// MARK: - Consoles` section, after `startConsole` / before `stopConsole` (after line 270), add:

```swift
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
```

- [ ] **Step 3: Kill the shell on teardown**

In `teardown` (lines 322-342), after the existing console cleanup and before/with the `consoleSessions` filter, add shell cleanup. Replace the body up to `try await manager.teardown(...)`:

```swift
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
            shellControllers[item.record.branch]?.stop()
            shellControllers[item.record.branch] = nil
            try await manager.teardown(
                id: item.record.id, config: config,
                repo: rootURL, push: push, force: force)
            supervisors = supervisors.filter { $0.key.branch != item.record.branch }
            buffers = buffers.filter { $0.key.branch != item.record.branch }
            refresh()
        } catch {
            lastError = AppError(error)
        }
    }
```

(`killAll(branch:)` already SIGTERMs the shell's process group; this just drops the controller + pumps task.)

- [ ] **Step 4: Build + lint**

Run: `swift build`
Expected: `Build complete!` no warnings.

Run: `swift format lint -r Sources Tests`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutApp/Model/ProjectStore.swift
git commit -m "feat: per-workspace drawer shell session in ProjectStore"
```

---

## Task 4: App — ShellDrawer view + MainWindow toggle

**Files:**
- Create: `Sources/SproutApp/Views/ShellDrawer.swift`
- Modify: `Sources/SproutApp/Views/MainWindow.swift:10-47`

- [ ] **Step 1: Create `ShellDrawer.swift`**

Create `Sources/SproutApp/Views/ShellDrawer.swift`:

```swift
import SwiftUI
import SproutEngine

/// Full-width bottom drawer hosting a workspace's persistent interactive shell. The shell
/// session lives in `ProjectStore` (keyed by branch) and outlives this view, so closing the
/// drawer keeps the session + scrollback alive. A top edge drag handle resizes the drawer.
struct ShellDrawer: View {
    @ObservedObject var project: ProjectStore
    let item: WorkspaceItem
    @Binding var height: CGFloat
    let onClose: () -> Void

    private let minHeight: CGFloat = 120
    private let maxHeight: CGFloat = 800

    var body: some View {
        VStack(spacing: 0) {
            handle
            header
            Divider()
            content
        }
        .frame(height: height)
        .background(.background)
        .task(id: item.record.branch) { await project.openShell(item) }
    }

    private var handle: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Dragging up (negative translation) grows the drawer.
                        let next = height - value.translation.height
                        height = min(maxHeight, max(minHeight, next))
                    })
            .help("Drag to resize")
    }

    private var header: some View {
        HStack {
            Image(systemName: "terminal")
            Text("shell — \(item.record.branch)").font(.callout.bold())
            Spacer()
            Button(action: onClose) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Hide shell (⌘J)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var content: some View {
        if let controller = project.shellController(branch: item.record.branch) {
            ConsoleView(controller: controller)
        } else {
            VStack {
                Spacer()
                ProgressView()
                Text("Starting shell…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
```

- [ ] **Step 2: Add drawer state + toggle to `MainWindow`**

In `Sources/SproutApp/Views/MainWindow.swift`, replace the `MainWindow` struct (lines 10-47) with:

```swift
struct MainWindow: View {
    @EnvironmentObject var app: AppModel
    @State private var selection: SidebarSelection?
    @State private var createForProject: ProjectStore?
    @State private var drawerVisible = false
    @AppStorage("shellDrawerHeight") private var drawerHeight: Double = 240

    /// The selected workspace as a (store, item) pair, or nil if the selection is not a
    /// workspace or no longer exists.
    private var selectedWorkspace: (ProjectStore, WorkspaceItem)? {
        guard case let .workspace(projectID, id) = selection,
            let project = app.projects.first(where: { $0.id == projectID }),
            let item = project.workspaces.first(where: { $0.id == id })
        else { return nil }
        return (project, item)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $selection,
                onAddProject: { presentAddProjectPanel(app) },
                onNewProject: { app.presentingNewProject = true },
                onNewWorkspace: { createForProject = $0 }
            )
            .frame(minWidth: 240)
        } detail: {
            VStack(spacing: 0) {
                DetailContainer(
                    selection: selection,
                    onNewWorkspace: { createForProject = $0 })
                if drawerVisible, let (project, item) = selectedWorkspace {
                    Divider()
                    ShellDrawer(
                        project: project, item: item,
                        height: Binding(
                            get: { CGFloat(drawerHeight) },
                            set: { drawerHeight = Double($0) }),
                        onClose: { drawerVisible = false })
                }
            }
        }
        .sheet(item: $createForProject) { project in
            CreateWorkspaceSheet(project: project)
        }
        .sheet(isPresented: $app.presentingNewProject) {
            CreateProjectSheet()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reconcile all projects")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    drawerVisible.toggle()
                } label: {
                    Image(systemName: "terminal")
                }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(selectedWorkspace == nil)
                .help("Toggle shell (⌘J)")
            }
        }
        .onAppear { app.refreshAll() }
    }
}
```

- [ ] **Step 3: Build + lint**

Run: `swift build`
Expected: `Build complete!` no warnings.

Run: `swift format lint -r Sources Tests`
Expected: no output.

- [ ] **Step 4: Manual smoke test**

Run: `swift run SproutApp`
Expected:
- With no workspace selected, the terminal toolbar button is disabled and `⌘J` does nothing.
- Select a workspace, press `⌘J` (or the terminal button) → a bottom drawer opens showing a shell prompt in the worktree.
- In the drawer run `pwd` (shows the worktree path), `echo $PORT` (shows the workspace port), and `ruby -v` / `node -v` (rbenv/nvm versions present — proves `.zshrc` loaded).
- Start a long command (e.g. `sleep 30`), press `⌘J` to hide, `⌘J` again → same session, command still running, scrollback intact.
- Drag the top handle → drawer resizes; quit + relaunch → drawer reopens at the saved height.
- Quit the app.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutApp/Views/ShellDrawer.swift Sources/SproutApp/Views/MainWindow.swift
git commit -m "feat: bottom-drawer interactive shell UI with toolbar + Cmd-J toggle"
```

---

## Self-Review Notes

- **Spec coverage:** per-workspace cwd/env via `childEnv(rec)` in `openShell` (Task 3.2); interactive `$SHELL -l -i` (Task 1.4); persistent session keyed by branch, view detaches without killing (Task 3.1/3.2 + `ShellDrawer` controller owned by store, Task 4.1); toolbar button **and** `⌘J`, disabled when no workspace (Task 4.2); full-width bottom drawer with drag-resize + `@AppStorage` height (Task 4.1/4.2); switching workspace swaps via `.task(id: branch)` re-running `openShell` and `shellController(branch:)` lookup (Task 4.1); teardown kills shell (Task 3.3, `killAll` + controller drop); shell excluded from console list (Task 2.6).
- **Placeholder scan:** none — every step has full code or an exact command.
- **Type consistency:** `spawnInteractive(cwd:env:)` identical in protocol, `ForkPTYSpawner`, `FakePTYSpawner` (Task 1); `startShell(branch:cwd:env:onExit:)` and `shell(branch:) -> ConsoleSessionInfo?` used identically in engine + `ProjectStore` (Tasks 2, 3); `shellController(branch:)`, `openShell(_:)` names match between `ProjectStore` and `ShellDrawer` (Tasks 3, 4); `ForkPTYProcess(shellPath:argv:cwd:env:)` callers all updated in Task 1.
- **YAGNI:** no shell tabs, no cross-restart persistence, no in-drawer restart button (deferred per spec's Out of Scope).
```

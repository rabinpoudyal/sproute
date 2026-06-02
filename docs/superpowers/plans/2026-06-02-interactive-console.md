# Interactive Console (rails console) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run interactive PTY-backed REPLs (e.g. `rails console`) inside SproutApp, per workspace, defined as named `[[run.console]]` entries in `.sprout.toml`.

**Architecture:** Two layers. (1) `SproutEngine` owns the PTY process truth — a `forkpty`-based `PTYHandle` and a `ConsoleSupervisor` actor that tracks live sessions per branch; no SwiftTerm dependency. (2) `SproutApp` owns the terminal emulator — a SwiftTerm `TerminalView` wrapped in a long-lived `ConsoleSessionController` (kept in `ProjectStore`, outliving the SwiftUI view so a console survives tab/window close) plus an `NSViewRepresentable`. The layers bridge via a session id, a `AsyncStream<Data>` of PTY output, and `send`/`resize` calls.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, SwiftUI/AppKit, TOMLKit, SwiftTerm (new dep, v1.13.0).

---

## Background the engineer needs

- **Why a PTY (not pipes):** the existing `PosixSpawnedProcess` (`Sources/SproutEngine/Shell/LoginShellRunner.swift`) wires the child's stdio to plain pipes. IRB/Pry call `isatty(0)`; with a pipe it returns false and the REPL drops to dumb mode (no readline, completion, or color). A pseudo-terminal makes `isatty` true, so the REPL runs fully interactive. We render that PTY byte stream with SwiftTerm.
- **forkpty safety:** between `fork` and `exec` only async-signal-safe calls are allowed. We therefore build all C string arrays (argv, envp) BEFORE `forkpty`, and after the fork the child only calls `chdir`, `execve`, `_exit`. This mirrors SwiftTerm's own `PseudoTerminalHelpers.fork`.
- **rbenv gotcha (already documented in CLAUDE.md):** the login shell (`$SHELL -l -c`) does not source `.zshrc`, so Ruby commands must be prefixed with `rbenv exec` in `.sprout.toml`. The console command is the user's responsibility (e.g. `rbenv exec ruby bin/rails console`); we do not add the prefix.
- **Env parity:** a console must get the same `PORT` + `DATABASE_URL` the dev server gets, or `rails console` talks to the wrong DB. `ProjectStore.childEnv(_:)` already builds exactly this map; reuse it.
- **SwiftTerm API facts (verified against v1.13.0 source):**
  - macOS view: `open class TerminalView: NSView`, initialized `public init(frame: CGRect, font: NSFont?)`.
  - Set the delegate: `terminalView.terminalDelegate = self` (`public weak var terminalDelegate: TerminalViewDelegate?`).
  - Feed bytes from the PTY into the view: `public func feed(byteArray: ArraySlice<UInt8>)`.
  - `public protocol TerminalViewDelegate` requires (no default impl): `sizeChanged(source:newCols:newRows:)`, `setTerminalTitle(source:title:)`, `hostCurrentDirectoryUpdate(source:directory:)`, `send(source:data:)`, `scrolled(source:position:)`, `rangeChanged(source:startY:endY:)`. Default impls exist for `requestOpenLink`, `bell`, `iTermContent`, `clipboardCopy`, `clipboardRead`.
  - User keystrokes arrive in `send(source:data:)` as `ArraySlice<UInt8>` — forward to the PTY.
  - Grid resize arrives in `sizeChanged(source:newCols:newRows:)` — forward to the PTY's `TIOCSWINSZ`.

## File structure

**Engine (new):**
- `Sources/SproutEngine/Shell/PTYProcess.swift` — `PTYHandle` protocol, `PTYSpawner` protocol, `ForkPTYSpawner`, `ForkPTYProcess`, `PTYError`.
- `Sources/SproutEngine/Console/ConsoleSupervisor.swift` — `actor ConsoleSupervisor`, `ConsoleSession`, `ConsoleSessionInfo`, `ConsoleStatus`.

**Engine (modify):**
- `Sources/SproutEngine/Config/Config.swift` — add `ConsoleConfig`, extend `RunConfig`.
- `Sources/SproutEngine/Config/TOMLConfigLoader.swift` — parse `[[run.console]]`.
- `Sources/SproutEngine/Config/TOMLConfigWriter.swift` — emit `run.console`.

**App (new):**
- `Sources/SproutApp/Model/ConsoleSessionController.swift` — `@MainActor` holder of one SwiftTerm `TerminalView`, the `TerminalViewDelegate`, output pump.
- `Sources/SproutApp/Views/ConsoleView.swift` — `NSViewRepresentable` + `ConsoleTarget` + `DetachedConsoleWindow`.

**App (modify):**
- `Sources/SproutApp/Model/ConfigDraft.swift` — preserve consoles through edit/save.
- `Sources/SproutApp/Model/ProjectStore.swift` — console supervisor, controllers, start/stop/restart, teardown kill.
- `Sources/SproutApp/Views/WorkspaceDetailView.swift` — selection between processes and consoles, start menu, render, pop-out.
- `Sources/SproutApp/Views/SproutAppMain.swift` — `WindowGroup(for: ConsoleTarget.self)` scene.
- `Package.swift` — add SwiftTerm to the `SproutApp` target.

**Tests (new):**
- Add cases to `Tests/SproutEngineTests/TOMLConfigLoaderTests.swift`, `TOMLConfigWriterTests.swift`.
- `Tests/SproutEngineTests/ConsoleSupervisorTests.swift` + `Tests/SproutEngineTests/Support/FakePTYSpawner.swift`.
- `Tests/SproutEngineTests/PTYProcessTests.swift` (integration, gated by `SPROUT_INTEGRATION`).

> **Deviation from spec (intentional):** the spec said `WorkspaceManager.teardown` calls `ConsoleSupervisor.killAll`. Consoles are app-driven and never persisted to `state.json`, so the engine `WorkspaceManager` has no handle to the live `ConsoleSupervisor` (it lives in `ProjectStore`). Teardown-kill (requirement D) is therefore implemented in `ProjectStore.teardown`, which owns the supervisor. Intent (no leaked `rails console` holding a DB connection) is fully met.

---

### Task 1: Add `ConsoleConfig` to the config model

**Files:**
- Modify: `Sources/SproutEngine/Config/Config.swift:70-79`

- [ ] **Step 1: Add the struct and extend `RunConfig`**

Replace the `ProcessConfig` + `RunConfig` block (lines 70-79) with:

```swift
public struct ProcessConfig: Sendable, Equatable {
    public var name: String
    public var command: String  // template, long-running
    public init(name: String, command: String) { self.name = name; self.command = command }
}

public struct ConsoleConfig: Sendable, Equatable {
    public var name: String
    public var command: String  // template, interactive REPL run under a PTY
    public init(name: String, command: String) { self.name = name; self.command = command }
}

public struct RunConfig: Sendable {
    public var processes: [ProcessConfig]
    public var consoles: [ConsoleConfig]
    public init(processes: [ProcessConfig], consoles: [ConsoleConfig] = []) {
        self.processes = processes
        self.consoles = consoles
    }
}
```

The `consoles` default of `[]` keeps every existing `RunConfig(processes:)` call compiling.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` (the `consoles` default keeps all current call sites valid).

- [ ] **Step 3: Commit**

```bash
git add Sources/SproutEngine/Config/Config.swift
git commit -m "feat: add ConsoleConfig to run config model"
```

---

### Task 2: Parse `[[run.console]]` in the TOML loader

**Files:**
- Modify: `Sources/SproutEngine/Config/TOMLConfigLoader.swift:59-94`
- Test: `Tests/SproutEngineTests/TOMLConfigLoaderTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/SproutEngineTests/TOMLConfigLoaderTests.swift` (inside the existing `TOMLConfigLoaderTests` suite — match the file's existing `@Test` style):

```swift
@Test func parsesConsoleEntries() throws {
    let toml = """
        [project]
        name = "shop"
        [worktree]
        base_dir = "../wt"
        branch_prefix = "feature/"
        [port]
        lower = 4000
        upper = 4050
        [env]
        symlink_sources = []
        local_file = ".env.local"
        [database]
        create_command = "createdb {{db_name}}"
        drop_command = "dropdb {{db_name}}"
        url_template = "postgres://localhost/{{db_name}}"
        [[run.console]]
        name = "rails"
        command = "rbenv exec ruby bin/rails console"
        [[run.console]]
        name = "db"
        command = "rbenv exec ruby bin/rails dbconsole"
        """
    let config = try TOMLConfigLoader.parse(toml)
    #expect(config.run.consoles == [
        ConsoleConfig(name: "rails", command: "rbenv exec ruby bin/rails console"),
        ConsoleConfig(name: "db", command: "rbenv exec ruby bin/rails dbconsole"),
    ])
}

@Test func parsesEmptyConsoleListWhenAbsent() throws {
    let toml = """
        [project]
        name = "shop"
        [worktree]
        base_dir = "../wt"
        branch_prefix = "feature/"
        [port]
        lower = 4000
        upper = 4050
        [env]
        symlink_sources = []
        local_file = ".env.local"
        [database]
        create_command = "createdb {{db_name}}"
        drop_command = "dropdb {{db_name}}"
        url_template = "postgres://localhost/{{db_name}}"
        """
    let config = try TOMLConfigLoader.parse(toml)
    #expect(config.run.consoles.isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TOMLConfigLoaderTests`
Expected: FAIL — `parsesConsoleEntries` fails because `config.run.consoles` is empty (loader doesn't read `run.console` yet).

- [ ] **Step 3: Parse the console array**

In `Sources/SproutEngine/Config/TOMLConfigLoader.swift`, after the `processes` parsing block (ends at line 70, just before the `hooksT` block at line 72), insert:

```swift
        var consoles: [ConsoleConfig] = []
        if let arr = runT?["console"]?.array {
            for entry in arr {
                guard let ct = entry.table,
                    let name = ct["name"]?.string,
                    let cmd = ct["command"]?.string
                else {
                    throw ConfigError.missingKey("run.console[].name/command")
                }
                consoles.append(ConsoleConfig(name: name, command: cmd))
            }
        }
```

Then change the `run:` argument in the returned `Config(...)` (line 93) from:

```swift
            run: RunConfig(processes: processes),
```

to:

```swift
            run: RunConfig(processes: processes, consoles: consoles),
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TOMLConfigLoaderTests`
Expected: PASS (all loader tests, including the two new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Config/TOMLConfigLoader.swift Tests/SproutEngineTests/TOMLConfigLoaderTests.swift
git commit -m "feat: parse [[run.console]] entries from .sprout.toml"
```

---

### Task 3: Emit `run.console` in the TOML writer

**Files:**
- Modify: `Sources/SproutEngine/Config/TOMLConfigWriter.swift:40-46`
- Test: `Tests/SproutEngineTests/TOMLConfigWriterTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/SproutEngineTests/TOMLConfigWriterTests.swift` (match existing suite/style):

```swift
@Test func roundTripsConsoles() throws {
    let original = Config(
        project: ProjectConfig(name: "shop"),
        worktree: WorktreeConfig(baseDir: "../wt", branchPrefix: "feature/"),
        port: PortConfig(lower: 4000, upper: 4050),
        env: EnvConfig(symlinkSources: [], localFile: ".env.local"),
        database: DatabaseConfig(
            createCommand: "createdb {{db_name}}",
            dropCommand: "dropdb {{db_name}}",
            urlTemplate: "postgres://localhost/{{db_name}}"),
        setup: [],
        run: RunConfig(
            processes: [ProcessConfig(name: "web", command: "npm run dev")],
            consoles: [
                ConsoleConfig(name: "rails", command: "rbenv exec ruby bin/rails console"),
                ConsoleConfig(name: "db", command: "rbenv exec ruby bin/rails dbconsole"),
            ]),
        hooks: HooksConfig())
    let reparsed = try TOMLConfigLoader.parse(TOMLConfigWriter.serialize(original))
    #expect(reparsed.run.consoles == original.run.consoles)
    #expect(reparsed.run.processes == original.run.processes)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TOMLConfigWriterTests`
Expected: FAIL — `reparsed.run.consoles` is empty (writer drops consoles).

- [ ] **Step 3: Emit the console array**

In `Sources/SproutEngine/Config/TOMLConfigWriter.swift`, replace the `run` block (lines 40-46):

```swift
        let run = TOMLTable()
        let procs = TOMLArray()
        for p in config.run.processes {
            procs.append(TOMLTable(["name": p.name, "command": p.command]))
        }
        run["process"] = procs
        root["run"] = run
```

with:

```swift
        let run = TOMLTable()
        let procs = TOMLArray()
        for p in config.run.processes {
            procs.append(TOMLTable(["name": p.name, "command": p.command]))
        }
        run["process"] = procs
        let consoles = TOMLArray()
        for c in config.run.consoles {
            consoles.append(TOMLTable(["name": c.name, "command": c.command]))
        }
        run["console"] = consoles
        root["run"] = run
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter TOMLConfigWriterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Config/TOMLConfigWriter.swift Tests/SproutEngineTests/TOMLConfigWriterTests.swift
git commit -m "feat: serialize run.console entries in TOML writer"
```

---

### Task 4: Preserve consoles through the config-form draft

**Files:**
- Modify: `Sources/SproutApp/Model/ConfigDraft.swift:36-37,51,69,119`

**Why:** `ConfigDraft` is the editable mirror used by the config form; `build()` reconstructs a `Config`. If it does not carry `consoles`, then saving the form (`AppModel.saveConfig`) would write a `.sprout.toml` with the `[[run.console]]` entries stripped. We are not building a console editor UI (out of scope), only preventing data loss — so store and re-emit them unchanged.

- [ ] **Step 1: Capture consoles in the draft**

In `Sources/SproutApp/Model/ConfigDraft.swift`, add a stored property after `@Published var processes: [ProcessRow]` (line 35). It is not `@Published` because it is not user-editable here:

```swift
    /// Carried through unchanged (no form UI yet) so saving never drops [[run.console]].
    private var consoles: [ConsoleConfig]
```

- [ ] **Step 2: Initialize it in `init(_:)`**

In `init(_ c: Config)`, after `processes = c.run.processes.map { ProcessRow(name: $0.name, command: $0.command) }` (line 51), add:

```swift
        consoles = c.run.consoles
```

- [ ] **Step 3: Initialize it in `template()`**

The `template()` factory calls `ConfigDraft(Config(... run: RunConfig(processes: [])...))`. `RunConfig(processes:)` already defaults `consoles` to `[]` (Task 1), so the draft's `init` picks up an empty list automatically. No change needed in `template()`.

- [ ] **Step 4: Re-emit consoles in `build()`**

In `build()`, change the `run:` argument (line 119) from:

```swift
            run: RunConfig(processes: procs),
```

to:

```swift
            run: RunConfig(processes: procs, consoles: consoles),
```

- [ ] **Step 5: Build to verify**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutApp/Model/ConfigDraft.swift
git commit -m "fix: preserve [[run.console]] through the config form draft"
```

---

### Task 5: PTY spawner and `ForkPTYProcess`

**Files:**
- Create: `Sources/SproutEngine/Shell/PTYProcess.swift`
- Test: `Tests/SproutEngineTests/PTYProcessTests.swift` (integration, gated)

- [ ] **Step 1: Write the gated integration test**

Create `Tests/SproutEngineTests/PTYProcessTests.swift`:

```swift
import Foundation
import Testing
@testable import SproutEngine

@Suite struct PTYProcessTests {
    private var integration: Bool {
        ProcessInfo.processInfo.environment["SPROUT_INTEGRATION"] == "1"
    }

    @Test func ptyReportsTtyAndEchoesOutput() async throws {
        guard integration else { return }
        let spawner = ForkPTYSpawner()
        // `tty` prints the terminal device name and exits 0 when stdin is a real tty.
        let handle = try spawner.spawn(
            command: "tty; exit", cwd: URL(fileURLWithPath: "/tmp"), env: [:])
        var collected = Data()
        for await chunk in handle.output { collected.append(chunk) }
        let text = String(decoding: collected, as: UTF8.self)
        let code = await handle.waitForExit()
        #expect(text.contains("/dev/"))  // a tty device path, proves isatty() == true
        #expect(code == 0)
    }

    @Test func sendWritesToChildStdin() async throws {
        guard integration else { return }
        let spawner = ForkPTYSpawner()
        // `cat` echoes stdin back to stdout (the same pty), then we kill it.
        let handle = try spawner.spawn(
            command: "cat", cwd: URL(fileURLWithPath: "/tmp"), env: [:])
        handle.send(Data("hello\n".utf8))
        var seen = ""
        for await chunk in handle.output {
            seen += String(decoding: chunk, as: UTF8.self)
            if seen.contains("hello") {
                await handle.terminate(graceSeconds: 1)
            }
        }
        #expect(seen.contains("hello"))
    }
}
```

- [ ] **Step 2: Run to verify it fails to compile**

Run: `SPROUT_INTEGRATION=1 swift test --filter PTYProcessTests`
Expected: FAIL — compile error, `ForkPTYSpawner` / `spawn` undefined.

- [ ] **Step 3: Implement the PTY spawner**

Create `Sources/SproutEngine/Shell/PTYProcess.swift`:

```swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum PTYError: Error, Equatable {
    case forkFailed(Int32)
}

/// Handle on an interactive process running under a pseudo-terminal. Output is the raw
/// byte stream from the pty master (ANSI escape codes intact — a terminal emulator
/// renders it). Input is written back to the same master.
public protocol PTYHandle: Sendable {
    var pid: Int32 { get }
    var output: AsyncStream<Data> { get }
    /// Write user input (keystrokes) to the pty master.
    func send(_ data: Data)
    /// Set the pty window size (TIOCSWINSZ) so the child reflows to the view.
    func resize(cols: Int, rows: Int)
    /// SIGTERM the process group, then SIGKILL after `graceSeconds`.
    func terminate(graceSeconds: Double) async
    func waitForExit() async -> Int32
}

public protocol PTYSpawner: Sendable {
    func spawn(command: String, cwd: URL, env: [String: String]) throws -> PTYHandle
}

/// Spawns the login shell under a real pty via `forkpty`, running `$SHELL -l -c <command>`.
/// The login shell (not interactive) matches `LoginShellRunner`'s environment, so the same
/// rbenv-exec gotcha applies: Ruby commands must be prefixed in `.sprout.toml`.
public struct ForkPTYSpawner: PTYSpawner {
    private let shellPath: String
    public init(shellPath: String? = nil) {
        self.shellPath = shellPath ?? LoginShellRunner.resolveLoginShell()
    }
    public func spawn(command: String, cwd: URL, env: [String: String]) throws -> PTYHandle {
        let merged = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        return try ForkPTYProcess(
            shellPath: shellPath, command: command, cwd: cwd.path, env: merged)
    }
}

final class ForkPTYProcess: PTYHandle, @unchecked Sendable {
    let pid: Int32
    let output: AsyncStream<Data>
    private let masterFD: Int32

    init(shellPath: String, command: String, cwd: String, env: [String: String]) throws {
        // Build all C arrays BEFORE forking — only async-signal-safe calls (chdir, execve,
        // _exit) may run in the child between fork and exec.
        let argv = [shellPath, "-l", "-c", command]
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] =
            env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cCwd = strdup(cwd)
        let cShell = strdup(shellPath)
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            free(cCwd)
            free(cShell)
        }

        var master: Int32 = 0
        var ws = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        let childPid = forkpty(&master, nil, nil, &ws)
        if childPid < 0 { throw PTYError.forkFailed(errno) }
        if childPid == 0 {
            // Child: forkpty already called setsid + made the pty the controlling tty.
            _ = chdir(cCwd)
            _ = execve(cShell, cArgs, cEnv)
            _exit(127)
        }

        self.pid = childPid
        self.masterFD = master
        let fd = master
        self.output = AsyncStream { cont in
            DispatchQueue.global().async {
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n <= 0 { break }  // EOF or EIO once the child's tty closes
                    cont.yield(Data(buf[0..<n]))
                }
                cont.finish()
            }
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            _ = write(masterFD, raw.baseAddress, raw.count)
        }
    }

    func resize(cols: Int, rows: Int) {
        var ws = winsize(
            ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, cols)),
            ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    func terminate(graceSeconds: Double) async {
        kill(-pid, SIGTERM)
        try? await Task.sleep(nanoseconds: UInt64(graceSeconds * 1_000_000_000))
        if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        close(masterFD)
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global().async {
                var status: Int32 = 0
                waitpid(self.pid, &status, 0)
                let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                c.resume(returning: Int32(code))
            }
        }
    }
}
```

Note: `LoginShellRunner.resolveLoginShell()` is `static` and internal to `SproutEngine`, so this same-module call is allowed.

- [ ] **Step 4: Run the gated test to verify it passes**

Run: `SPROUT_INTEGRATION=1 swift test --filter PTYProcessTests`
Expected: PASS (both tests). Also confirm the ungated run skips them: `swift test --filter PTYProcessTests` → tests return early (0 failures).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Shell/PTYProcess.swift Tests/SproutEngineTests/PTYProcessTests.swift
git commit -m "feat: forkpty-based PTYHandle and spawner for interactive consoles"
```

---

### Task 6: `ConsoleSupervisor` actor

**Files:**
- Create: `Sources/SproutEngine/Console/ConsoleSupervisor.swift`
- Create: `Tests/SproutEngineTests/Support/FakePTYSpawner.swift`
- Test: `Tests/SproutEngineTests/ConsoleSupervisorTests.swift`

- [ ] **Step 1: Write the fake spawner**

Create `Tests/SproutEngineTests/Support/FakePTYSpawner.swift`:

```swift
import Foundation
@testable import SproutEngine

/// In-memory PTYHandle that records sent bytes and can be made to "exit" on demand.
final class FakePTYHandle: PTYHandle, @unchecked Sendable {
    let pid: Int32
    let output: AsyncStream<Data>
    private let cont: AsyncStream<Data>.Continuation
    private let exitContinuation = ExitBox()
    private(set) var sent = Data()
    private(set) var terminated = false

    final class ExitBox: @unchecked Sendable {
        var resume: ((Int32) -> Void)?
        var code: Int32?
    }

    init(pid: Int32) {
        self.pid = pid
        var c: AsyncStream<Data>.Continuation!
        self.output = AsyncStream { c = $0 }
        self.cont = c
    }

    func emit(_ text: String) { cont.yield(Data(text.utf8)) }
    func finishOutput() { cont.finish() }

    /// Cause `waitForExit` to return `code`.
    func simulateExit(code: Int32) {
        exitContinuation.code = code
        exitContinuation.resume?(code)
    }

    func send(_ data: Data) { sent.append(data) }
    func resize(cols: Int, rows: Int) {}
    func terminate(graceSeconds: Double) async {
        terminated = true
        simulateExit(code: 0)
    }
    func waitForExit() async -> Int32 {
        if let code = exitContinuation.code { return code }
        return await withCheckedContinuation { c in
            exitContinuation.resume = { c.resume(returning: $0) }
        }
    }
}

final class FakePTYSpawner: PTYSpawner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var handles: [FakePTYHandle] = []
    private(set) var commands: [String] = []
    private var nextPid: Int32 = 1000

    func spawn(command: String, cwd: URL, env: [String: String]) throws -> PTYHandle {
        lock.lock(); defer { lock.unlock() }
        commands.append(command)
        let h = FakePTYHandle(pid: nextPid)
        nextPid += 1
        handles.append(h)
        return h
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/SproutEngineTests/ConsoleSupervisorTests.swift`:

```swift
import Foundation
import Testing
@testable import SproutEngine

@Suite struct ConsoleSupervisorTests {
    private func ctx() -> TemplateContext {
        TemplateContext(
            project: "shop", branch: "feature/x", port: 4000,
            dbName: "shop_x", worktree: "/tmp/wt")
    }

    @Test func startRendersCommandAndTracksSession() async throws {
        let spawner = FakePTYSpawner()
        let sup = ConsoleSupervisor(spawner: spawner, renderer: TemplateRenderer())
        let session = try await sup.start(
            branch: "feature/x", name: "rails",
            command: "bin/rails console {{db_name}}", ctx: ctx(),
            cwd: URL(fileURLWithPath: "/tmp/wt"), env: [:], onExit: { _, _ in })
        #expect(spawner.commands == ["bin/rails console shop_x"])  // template rendered
        let listed = await sup.list(branch: "feature/x")
        #expect(listed.map(\.id) == [session.id])
        #expect(listed.first?.status == .running)
    }

    @Test func stopTerminatesAndDropsSession() async throws {
        let spawner = FakePTYSpawner()
        let sup = ConsoleSupervisor(spawner: spawner, renderer: TemplateRenderer())
        let session = try await sup.start(
            branch: "feature/x", name: "rails", command: "bin/rails console",
            ctx: ctx(), cwd: URL(fileURLWithPath: "/tmp/wt"), env: [:], onExit: { _, _ in })
        await sup.stop(id: session.id)
        let listed = await sup.list(branch: "feature/x")
        #expect(listed.isEmpty)
        #expect(spawner.handles.first?.terminated == true)
    }

    @Test func killAllTerminatesOnlyMatchingBranch() async throws {
        let spawner = FakePTYSpawner()
        let sup = ConsoleSupervisor(spawner: spawner, renderer: TemplateRenderer())
        _ = try await sup.start(
            branch: "feature/x", name: "rails", command: "a",
            ctx: ctx(), cwd: URL(fileURLWithPath: "/tmp/wt"), env: [:], onExit: { _, _ in })
        _ = try await sup.start(
            branch: "feature/y", name: "rails", command: "b",
            ctx: ctx(), cwd: URL(fileURLWithPath: "/tmp/wt"), env: [:], onExit: { _, _ in })
        await sup.killAll(branch: "feature/x")
        #expect(await sup.list(branch: "feature/x").isEmpty)
        #expect(await sup.list(branch: "feature/y").count == 1)
    }

    @Test func naturalExitFiresCallbackAndDropsSession() async throws {
        let spawner = FakePTYSpawner()
        let sup = ConsoleSupervisor(spawner: spawner, renderer: TemplateRenderer())
        let box = ExitCapture()
        let session = try await sup.start(
            branch: "feature/x", name: "rails", command: "a",
            ctx: ctx(), cwd: URL(fileURLWithPath: "/tmp/wt"), env: [:],
            onExit: { id, code in box.record(id: id, code: code) })
        spawner.handles.first?.simulateExit(code: 0)
        // Give the watch task a moment to observe the exit.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(box.captured?.0 == session.id)
        #expect(box.captured?.1 == 0)
        #expect(await sup.list(branch: "feature/x").isEmpty)
    }
}

final class ExitCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (UUID, Int32)?
    var captured: (UUID, Int32)? { lock.lock(); defer { lock.unlock() }; return value }
    func record(id: UUID, code: Int32) { lock.lock(); value = (id, code); lock.unlock() }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter ConsoleSupervisorTests`
Expected: FAIL — compile error, `ConsoleSupervisor` undefined.

- [ ] **Step 4: Implement the supervisor**

Create `Sources/SproutEngine/Console/ConsoleSupervisor.swift`:

```swift
import Foundation

public enum ConsoleStatus: Sendable, Equatable { case running, exited }

/// A live console session. `handle` is the bridge the UI uses for output/input/resize;
/// the supervisor retains it for lifecycle control (stop / killAll).
public struct ConsoleSession: Sendable {
    public let id: UUID
    public let branch: String
    public let name: String
    public let handle: PTYHandle
}

/// Display snapshot of a session (no PTY handle).
public struct ConsoleSessionInfo: Sendable, Equatable {
    public let id: UUID
    public let branch: String
    public let name: String
    public let pid: Int32
    public let status: ConsoleStatus
}

/// Owns interactive PTY console sessions, separate from `ServerSupervisor` (whose pipe/
/// log-only model does not fit bidirectional PTY I/O). Sessions are in-memory only and
/// never persisted: they do not survive an app restart by design.
public actor ConsoleSupervisor {
    private struct Entry {
        let branch: String
        let name: String
        let handle: PTYHandle
        var status: ConsoleStatus
    }

    private let spawner: PTYSpawner
    private let renderer: TemplateRenderer
    private var entries: [UUID: Entry] = [:]

    public init(spawner: PTYSpawner, renderer: TemplateRenderer) {
        self.spawner = spawner
        self.renderer = renderer
    }

    /// Spawns a console. `onExit(id, code)` fires when it later exits naturally (the user
    /// typed `exit`, or it crashed); the session is removed before the callback runs.
    @discardableResult
    public func start(
        branch: String, name: String, command: String,
        ctx: TemplateContext, cwd: URL, env: [String: String],
        onExit: @escaping @Sendable (_ id: UUID, _ code: Int32) -> Void
    ) throws -> ConsoleSession {
        let rendered = renderer.render(command, ctx)
        let handle = try spawner.spawn(command: rendered, cwd: cwd, env: env)
        let id = UUID()
        entries[id] = Entry(branch: branch, name: name, handle: handle, status: .running)
        // Watch for natural exit. The task retains the handle + closure, not self via a
        // strong cycle: we hop back into the actor to drop the entry, then notify.
        Task { [weak self] in
            let code = await handle.waitForExit()
            await self?.markExited(id: id)
            onExit(id, code)
        }
        return ConsoleSession(id: id, branch: branch, name: name, handle: handle)
    }

    public func stop(id: UUID) async {
        guard let entry = entries[id] else { return }
        entries[id] = nil
        await entry.handle.terminate(graceSeconds: 5)
    }

    public func killAll(branch: String) async {
        let toKill = entries.filter { $0.value.branch == branch }
        for (id, _) in toKill { entries[id] = nil }
        for (_, entry) in toKill { await entry.handle.terminate(graceSeconds: 5) }
    }

    public func list(branch: String) -> [ConsoleSessionInfo] {
        entries
            .filter { $0.value.branch == branch }
            .map {
                ConsoleSessionInfo(
                    id: $0.key, branch: $0.value.branch, name: $0.value.name,
                    pid: $0.value.handle.pid, status: $0.value.status)
            }
    }

    private func markExited(id: UUID) {
        entries[id] = nil
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter ConsoleSupervisorTests`
Expected: PASS (all four tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutEngine/Console/ConsoleSupervisor.swift Tests/SproutEngineTests/ConsoleSupervisorTests.swift Tests/SproutEngineTests/Support/FakePTYSpawner.swift
git commit -m "feat: ConsoleSupervisor actor managing PTY console sessions"
```

---

### Task 7: Add the SwiftTerm dependency to SproutApp

**Files:**
- Modify: `Package.swift:12-15,28-31`

- [ ] **Step 1: Add the package dependency**

In `Package.swift`, change the `dependencies:` array (lines 12-15) to:

```swift
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
    ],
```

- [ ] **Step 2: Link SwiftTerm into the SproutApp target only**

Change the `SproutApp` executable target (lines 28-31) to:

```swift
        .executableTarget(
            name: "SproutApp",
            dependencies: [
                "SproutEngine",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
```

Leave `SproutEngine` and `sprout-cli` untouched — neither gets SwiftTerm.

- [ ] **Step 3: Resolve and build**

Run: `swift build`
Expected: SwiftTerm is fetched and resolved, then `Build complete!`. (First run downloads the package; allow extra time.)

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add SwiftTerm dependency to SproutApp"
```

---

### Task 8: `ConsoleSessionController` — the SwiftTerm bridge

**Files:**
- Create: `Sources/SproutApp/Model/ConsoleSessionController.swift`

**Why a long-lived controller:** the SwiftTerm `TerminalView` holds the scrollback buffer. To make a console survive tab/window close (requirement A), the view must outlive the SwiftUI view that displays it. `ProjectStore` (Task 9) retains one controller per session; the SwiftUI `ConsoleView` (Task 10) just reattaches to the controller's view.

- [ ] **Step 1: Implement the controller**

Create `Sources/SproutApp/Model/ConsoleSessionController.swift`:

```swift
import AppKit
import Foundation
import SproutEngine
import SwiftTerm

/// Owns one SwiftTerm `TerminalView` and bridges it to an engine `PTYHandle`:
/// PTY output → `feed`, user keystrokes → `send`, grid resize → `resize`. Kept alive by
/// `ProjectStore` for the life of the session so closing the tab/window does not destroy
/// the terminal buffer or the underlying process.
@MainActor
final class ConsoleSessionController: NSObject, TerminalViewDelegate {
    let id: UUID
    let terminalView: TerminalView
    private let handle: PTYHandle
    private var pumpTask: Task<Void, Never>?

    init(id: UUID, handle: PTYHandle) {
        self.id = id
        self.handle = handle
        self.terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: nil)
        super.init()
        terminalView.terminalDelegate = self
        startPump()
    }

    private func startPump() {
        let handle = self.handle
        pumpTask = Task { [weak self] in
            for await chunk in handle.output {
                let bytes = [UInt8](chunk)
                await MainActor.run { self?.terminalView.feed(byteArray: bytes[...]) }
            }
        }
    }

    func stop() {
        pumpTask?.cancel()
    }

    // MARK: TerminalViewDelegate

    /// User typed something — forward the raw bytes to the pty.
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        handle.send(Data(data))
    }

    /// The view's grid changed size — tell the pty so the child reflows.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        handle.resize(cols: newCols, rows: newRows)
    }

    // Required by the protocol; no behavior needed for an embedded console.
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: `Build complete!`. If the compiler reports an unsatisfied `TerminalViewDelegate` requirement, add the named method exactly as listed in the "SwiftTerm API facts" section — those six are the only ones without default implementations.

- [ ] **Step 3: Commit**

```bash
git add Sources/SproutApp/Model/ConsoleSessionController.swift
git commit -m "feat: ConsoleSessionController bridging SwiftTerm to the engine PTY"
```

---

### Task 9: Console state and actions in `ProjectStore`

**Files:**
- Modify: `Sources/SproutApp/Model/ProjectStore.swift`

- [ ] **Step 1: Add a UI item type and published state**

In `Sources/SproutApp/Model/ProjectStore.swift`, after the `WorkspaceItem` struct (top of file, after line 9), add:

```swift
/// One running interactive console, for display in the detail view and process list.
struct ConsoleSessionItem: Identifiable, Equatable {
    let id: UUID
    let branch: String
    let name: String
    var status: ConsoleStatus
}
```

Inside `ProjectStore`, after `@Published var lastError: AppError?` (line 27), add:

```swift
    @Published private(set) var consoleSessions: [ConsoleSessionItem] = []
```

After the `supervisors` dictionary (line 35), add:

```swift
    private lazy var consoleSupervisor = ConsoleSupervisor(
        spawner: ForkPTYSpawner(), renderer: renderer)
    private var consoleControllers: [UUID: ConsoleSessionController] = [:]
```

`renderer` is already a stored property (line 30), so the `lazy var` can reference it.

- [ ] **Step 2: Add console lifecycle methods**

Add this section to `ProjectStore` (place it after `stopAll(_:)`, around line 224):

```swift
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
```

- [ ] **Step 3: Kill consoles on teardown**

In `teardown(_:push:force:)`, add a console kill BEFORE `manager.teardown` is called. Replace the body's `do {` opening (line 248-251) so it reads:

```swift
        do {
            await consoleSupervisor.killAll(branch: item.record.branch)
            for (id, c) in consoleControllers
            where consoleSessions.contains(where: { $0.id == id && $0.branch == item.record.branch }) {
                c.stop()
                consoleControllers[id] = nil
            }
            consoleSessions = consoleSessions.filter { $0.branch != item.record.branch }
            try await manager.teardown(
                id: item.record.id, config: config,
                repo: rootURL, push: push, force: force)
```

(The rest of the `do`/`catch` — the `supervisors`/`buffers` filtering and `refresh()` — stays unchanged.)

- [ ] **Step 4: Build to verify**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutApp/Model/ProjectStore.swift
git commit -m "feat: console session lifecycle in ProjectStore"
```

---

### Task 10: `ConsoleView` and detached window plumbing

**Files:**
- Create: `Sources/SproutApp/Views/ConsoleView.swift`

- [ ] **Step 1: Implement the representable, target, and detached window**

Create `Sources/SproutApp/Views/ConsoleView.swift`:

```swift
import AppKit
import SwiftTerm
import SwiftUI

/// Embeds a session's persistent SwiftTerm `TerminalView`. The controller owns the view
/// (it survives this representable being recreated on tab switches), so we just hand the
/// existing NSView back to SwiftUI.
struct ConsoleView: NSViewRepresentable {
    let controller: ConsoleSessionController

    func makeNSView(context: Context) -> TerminalView { controller.terminalView }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

/// Identifies a detached console window: a session within a project.
struct ConsoleTarget: Identifiable, Hashable, Codable {
    let projectID: String
    let sessionID: UUID
    var id: String { "\(projectID)#\(sessionID.uuidString)" }
}

/// Standalone window content for a popped-out console, looked up by target.
struct DetachedConsoleWindow: View {
    @EnvironmentObject var app: AppModel
    let target: ConsoleTarget?

    var body: some View {
        Group {
            if let target,
                let project = app.projects.first(where: { $0.id == target.projectID }),
                let controller = project.consoleController(id: target.sessionID)
            {
                ConsoleView(controller: controller)
                    .navigationTitle("\(project.name) console")
            } else {
                ContentUnavailableView("No Console", systemImage: "terminal")
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/SproutApp/Views/ConsoleView.swift
git commit -m "feat: ConsoleView representable and detached console window"
```

---

### Task 11: Register the detached console window scene

**Files:**
- Modify: `Sources/SproutApp/Views/SproutAppMain.swift:48-53`

- [ ] **Step 1: Add the WindowGroup scene**

In `Sources/SproutApp/Views/SproutAppMain.swift`, after the existing detached-log `WindowGroup(for: LogTarget.self)` block (ends line 53), add:

```swift
        // Detached, per-session console windows.
        WindowGroup(for: ConsoleTarget.self) { $target in
            DetachedConsoleWindow(target: target)
                .environmentObject(app)
                .frame(minWidth: 560, minHeight: 360)
        }
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/SproutApp/Views/SproutAppMain.swift
git commit -m "feat: register detached console window scene"
```

---

### Task 12: Wire consoles into `WorkspaceDetailView`

**Files:**
- Modify: `Sources/SproutApp/Views/WorkspaceDetailView.swift`

**Goal:** one selector that switches between log views (per process) and live console terminals, a menu to start a configured console, and a pop-out button for the selected console.

- [ ] **Step 1: Introduce a selection enum and replace process-only state**

In `Sources/SproutApp/Views/WorkspaceDetailView.swift`, replace the state/computed declarations (lines 11-19) with:

```swift
    @State private var busy = false
    @State private var confirmDone = false
    @State private var confirmDiscard = false
    @State private var dirtyWarning = false
    @State private var selection: DetailSelection?

    /// What the main pane is showing: a process's logs, or a live console session.
    enum DetailSelection: Hashable {
        case process(String)
        case console(UUID)
    }

    private var rec: WorkspaceRecord { item.record }
    private var processNames: [String] { project.config.run.processes.map(\.name) }
    private var consoles: [ConsoleSessionItem] {
        project.consoleSessions.filter { $0.branch == rec.branch }
    }
    private var consoleConfigNames: [String] { project.config.run.consoles.map(\.name) }

    /// Default to the first process, else the first console, else nil.
    private var current: DetailSelection? {
        if let selection { return selection }
        if let first = processNames.first { return .process(first) }
        if let firstConsole = consoles.first { return .console(firstConsole.id) }
        return nil
    }
```

- [ ] **Step 2: Replace the body's content switch**

Replace the `if let current { ... } else { ... }` block inside `body` (lines 25-39) with:

```swift
            if let current {
                selectorBar(current)
                Divider()
                content(current)
            } else {
                ContentUnavailableView(
                    "Nothing to show", systemImage: "bolt.slash",
                    description: Text("This workspace defines no run processes or consoles."))
            }
```

- [ ] **Step 3: Replace `processBar(_:)` with `selectorBar(_:)` and add `content(_:)`**

Replace the entire `processBar(_ name:)` function (lines 96-135) with the following two functions:

```swift
    private func selectorBar(_ current: DetailSelection) -> some View {
        HStack(spacing: 12) {
            Picker(
                "View",
                selection: Binding(
                    get: { current },
                    set: { selection = $0 })
            ) {
                ForEach(processNames, id: \.self) { proc in
                    Label {
                        Text(proc)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(dotColor(proc))
                    }
                    .tag(DetailSelection.process(proc))
                }
                ForEach(consoles) { session in
                    Label {
                        Text(session.name)
                    } icon: {
                        Image(systemName: "terminal")
                    }
                    .tag(DetailSelection.console(session.id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Spacer()

            if !consoleConfigNames.isEmpty {
                Menu {
                    ForEach(consoleConfigNames, id: \.self) { name in
                        Button(name) {
                            run {
                                await project.startConsole(item, name: name)
                                if let new = project.consoleSessions
                                    .last(where: { $0.branch == rec.branch && $0.name == name })
                                {
                                    selection = .console(new.id)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Console", systemImage: "terminal")
                }
                .help("Start an interactive console")
            }

            // Per-selection controls.
            switch current {
            case .process(let name):
                Button { run { await project.startProcess(item, name: name) } } label: {
                    Label("Start", systemImage: "play.fill")
                }
                Button { run { await project.stopProcess(item, name: name) } } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                Button { run { await project.restartProcess(item, name: name) } } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
            case .console(let id):
                Button {
                    run { await project.stopConsole(id: id) }
                    selection = nil
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                Button {
                    openWindow(value: ConsoleTarget(projectID: project.id, sessionID: id))
                } label: {
                    Label("Pop Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal).padding(.vertical, 6)
    }

    @ViewBuilder
    private func content(_ current: DetailSelection) -> some View {
        switch current {
        case .process(let name):
            LogConsoleView(
                buffer: project.logBuffer(branch: rec.branch, process: name),
                onPopOut: {
                    openWindow(
                        value: LogTarget(
                            projectID: project.id, branch: rec.branch, process: name))
                })
        case .console(let id):
            if let controller = project.consoleController(id: id) {
                ConsoleView(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Console ended", systemImage: "terminal")
            }
        }
    }
```

`dotColor(_:)`, `field(_:_:)`, the toolbar, and the action helpers below are unchanged.

- [ ] **Step 4: Build to verify**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Manual smoke test**

This UI cannot be unit-tested (AppKit + live PTY). Verify by hand:

```bash
swift run SproutApp
```

In a project whose `.sprout.toml` has a `[[run.console]]` entry (add one, e.g. `name = "sh"`, `command = "bash"` for a quick check that needs no rbenv), create/open a workspace, click the **Console** menu, pick the entry. Expected: a live terminal appears; typing works, arrow keys recall history, `ls`/colors render. Click **Pop Out** → the same session opens in its own window. Close the tab/window → the session stays in the picker (still running). Click **Stop** → it disappears.

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutApp/Views/WorkspaceDetailView.swift
git commit -m "feat: select between process logs and live consoles in detail view"
```

---

### Task 13: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Lint**

Run: `swift format lint -r Sources Tests`
Expected: no output (clean). Fix any reported lines by hand; do NOT run `swift format format -i` (it rewraps the intentional compact style).

- [ ] **Step 2: Build all products**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Full unit suite**

Run: `swift test`
Expected: all tests pass, including the new loader/writer/`ConsoleSupervisor` cases; `PTYProcessTests` are skipped (return early).

- [ ] **Step 4: Gated integration suite**

Run: `SPROUT_INTEGRATION=1 swift test --filter PTYProcessTests`
Expected: both PTY tests pass (real `forkpty`).

- [ ] **Step 5: Commit any lint fixups**

```bash
git add -A
git commit -m "chore: lint fixups for interactive console"
```

(Skip if there was nothing to fix.)

---

## Self-review notes

- **Spec coverage:** PTY fidelity (Task 5) · SwiftTerm dep (Task 7) · two-layer split engine/app (Tasks 5-6 vs 8-10) · `[[run.console]]` named array (Tasks 1-3) · env parity + rbenv (Task 9 reuses `childEnv`) · inline + pop-out UI (Tasks 10-12) · survive tab close via long-lived controller (Tasks 8-9) · process-list status + stop/restart (Tasks 9, 12) · teardown kill = D (Task 9 Step 3) · no app-restart persistence = C skipped (sessions in-memory only, never written to state). All covered.
- **Type consistency:** `PTYHandle`/`PTYSpawner`/`ForkPTYSpawner` (Task 5) used by `ConsoleSupervisor` (Task 6) and `ProjectStore` (Task 9); `ConsoleSession.handle` feeds `ConsoleSessionController(id:handle:)` (Task 8); `ConsoleSessionItem` (Task 9) consumed by `WorkspaceDetailView` (Task 12); `ConsoleTarget` (Task 10) used by the scene (Task 11) and the pop-out button (Task 12). Names match across tasks.
- **No placeholders:** every code step is complete and concrete.

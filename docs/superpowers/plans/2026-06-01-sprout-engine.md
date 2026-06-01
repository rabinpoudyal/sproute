# Sprout Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the headless `SproutEngine` Swift library plus a thin debug CLI that sprouts isolated git-worktree workspaces (own port, own Postgres DB, own env), runs a supervised dev server, then tears it all down.

**Architecture:** Pure-logic engine behind three injection seams — `ShellRunner` (every external command runs through the user's login shell), `Config` (injected struct, engine agnostic to source), `StateStore` (persisted workspace records). Services each do one job; `WorkspaceManager` orchestrates create/teardown/reconcile. CLI is a thin consumer.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing (`import Testing`), swift-argument-parser (CLI), TOMLKit (config loading). macOS 14+. No AppKit/SwiftUI/SwiftData in the engine.

**Refinement vs spec:** The product spec's `ShellRunner` had `run` + `stream`. A log stream can't surface the child PID that `ServerSupervisor` must persist and signal. This plan replaces `stream` with `launch(...) -> ProcessHandle` (exposes `pid`, `logs`, `terminate`, `waitForExit`). Setup steps use the same handle.

---

## File Structure

```
Sprout/
├── Package.swift
├── Sources/
│   ├── SproutEngine/
│   │   ├── Shell/ShellRunner.swift          # protocols + ProcessResult/LogLine/ProcessHandle
│   │   ├── Shell/LoginShellRunner.swift     # real impl (login shell, PID, process group)
│   │   ├── Config/TemplateRenderer.swift     # TemplateContext + render
│   │   ├── Config/Config.swift               # Config + sub-structs
│   │   ├── Config/TOMLConfigLoader.swift     # .sprout.toml -> Config
│   │   ├── State/StateStore.swift            # protocol + WorkspaceRecord + WorkspaceStatus
│   │   ├── State/JSONStateStore.swift        # file-backed impl
│   │   ├── Port/PortAllocator.swift          # PortProber + allocator
│   │   ├── Git/GitService.swift
│   │   ├── Database/DatabaseService.swift
│   │   ├── Env/EnvLinker.swift               # FileSystem protocol + linker
│   │   ├── Setup/SetupRunner.swift
│   │   ├── Server/ServerSupervisor.swift     # actor
│   │   └── Workspace/WorkspaceManager.swift  # ProcessChecker + orchestrator
│   └── sprout-cli/
│       └── main.swift                        # ArgumentParser commands
└── Tests/
    └── SproutEngineTests/
        ├── Support/FakeShellRunner.swift
        ├── Support/Fakes.swift               # FakeStateStore, FakeFileSystem, etc.
        ├── TemplateRendererTests.swift
        ├── JSONStateStoreTests.swift
        ├── PortAllocatorTests.swift
        ├── GitServiceTests.swift
        ├── DatabaseServiceTests.swift
        ├── EnvLinkerTests.swift
        ├── SetupRunnerTests.swift
        ├── ServerSupervisorTests.swift
        ├── WorkspaceManagerTests.swift
        ├── TOMLConfigLoaderTests.swift
        └── IntegrationTests.swift            # gated by SPROUT_INTEGRATION=1
```

---

## Task 0: Package scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/SproutEngine/Shell/ShellRunner.swift` (placeholder marker so target compiles)

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sprout",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SproutEngine", targets: ["SproutEngine"]),
        .executable(name: "sprout", targets: ["sprout-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "SproutEngine",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]
        ),
        .executableTarget(
            name: "sprout-cli",
            dependencies: [
                "SproutEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SproutEngineTests", dependencies: ["SproutEngine"]),
    ]
)
```

- [ ] **Step 2: Create placeholder source so the target compiles**

`Sources/SproutEngine/Shell/ShellRunner.swift`:

```swift
// SproutEngine — replaced in Task 1.
```

Also create a minimal CLI entry `Sources/sprout-cli/main.swift`:

```swift
print("sprout")
```

And an empty test file `Tests/SproutEngineTests/TemplateRendererTests.swift`:

```swift
import Testing
@testable import SproutEngine

@Test func scaffoldCompiles() { #expect(true) }
```

- [ ] **Step 3: Resolve + build**

Run: `swift build`
Expected: builds successfully (downloads swift-argument-parser + TOMLKit).

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: 1 test passes (`scaffoldCompiles`).

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved Sources Tests
git commit -m "chore: scaffold Sprout SPM package (engine lib + CLI + tests)"
```

---

## Task 1: Shell types + ShellRunner protocol + test fakes

**Files:**
- Modify: `Sources/SproutEngine/Shell/ShellRunner.swift`
- Create: `Tests/SproutEngineTests/Support/FakeShellRunner.swift`

- [ ] **Step 1: Write the protocol + value types**

Replace `Sources/SproutEngine/Shell/ShellRunner.swift`:

```swift
import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
    public var succeeded: Bool { exitCode == 0 }
}

public struct LogLine: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case stdout, stderr }
    public let source: Source
    public let text: String
    public init(source: Source, text: String) { self.source = source; self.text = text }
}

/// Handle on a launched, possibly long-running process.
public protocol ProcessHandle: Sendable {
    var pid: Int32 { get }
    var logs: AsyncStream<LogLine> { get }
    /// SIGTERM the process group, then SIGKILL after `graceSeconds`.
    func terminate(graceSeconds: Double) async
    /// Awaits exit, returns exit code.
    func waitForExit() async -> Int32
}

public protocol ShellRunner: Sendable {
    /// One-shot: run, wait, collect output.
    func run(_ command: String, cwd: URL, env: [String: String]) async throws -> ProcessResult
    /// Launch a process, return a handle (PID + live logs + lifecycle control).
    func launch(_ command: String, cwd: URL, env: [String: String]) throws -> ProcessHandle
}
```

- [ ] **Step 2: Write the test fake**

`Tests/SproutEngineTests/Support/FakeShellRunner.swift`:

```swift
import Foundation
@testable import SproutEngine

/// Records every call; returns scripted results matched by command substring.
final class FakeShellRunner: ShellRunner, @unchecked Sendable {
    struct Call: Equatable { let command: String; let cwd: String; let env: [String: String] }

    private(set) var calls: [Call] = []
    /// command-substring -> result. First match wins; falls back to exit 0 empty.
    var runResults: [(match: String, result: ProcessResult)] = []
    /// command-substring -> handle factory.
    var handles: [(match: String, make: () -> FakeProcessHandle)] = []

    func run(_ command: String, cwd: URL, env: [String: String]) async throws -> ProcessResult {
        calls.append(Call(command: command, cwd: cwd.path, env: env))
        for r in runResults where command.contains(r.match) { return r.result }
        return ProcessResult(stdout: "", stderr: "", exitCode: 0)
    }

    func launch(_ command: String, cwd: URL, env: [String: String]) throws -> ProcessHandle {
        calls.append(Call(command: command, cwd: cwd.path, env: env))
        for h in handles where command.contains(h.match) { return h.make() }
        return FakeProcessHandle(pid: 4242, exitCode: 0, lines: [])
    }
}

final class FakeProcessHandle: ProcessHandle, @unchecked Sendable {
    let pid: Int32
    private let exit: Int32
    private let lines: [LogLine]
    private(set) var terminated = false

    init(pid: Int32, exitCode: Int32, lines: [LogLine]) {
        self.pid = pid; self.exit = exitCode; self.lines = lines
    }

    var logs: AsyncStream<LogLine> {
        let lines = self.lines
        return AsyncStream { cont in
            for l in lines { cont.yield(l) }
            cont.finish()
        }
    }
    func terminate(graceSeconds: Double) async { terminated = true }
    func waitForExit() async -> Int32 { exit }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds (protocols + fake compile; fake lives in test target).

- [ ] **Step 4: Add a smoke test for the fake**

Append to `Tests/SproutEngineTests/TemplateRendererTests.swift` (temporary home; moves in Task 2):

```swift
import Foundation

@Test func fakeShellRecordsCalls() async throws {
    let shell = FakeShellRunner()
    shell.runResults = [("echo", ProcessResult(stdout: "hi", stderr: "", exitCode: 0))]
    let r = try await shell.run("echo hi", cwd: URL(fileURLWithPath: "/tmp"), env: [:])
    #expect(r.stdout == "hi")
    #expect(shell.calls.first?.command == "echo hi")
}
```

- [ ] **Step 5: Run tests**

Run: `swift test`
Expected: PASS (`fakeShellRecordsCalls`, `scaffoldCompiles`).

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutEngine/Shell Tests
git commit -m "feat(engine): add ShellRunner protocol, value types, and test fake"
```

---

## Task 2: TemplateRenderer

Pure logic, no deps — the easiest unit to nail with TDD.

**Files:**
- Create: `Sources/SproutEngine/Config/TemplateRenderer.swift`
- Modify: `Tests/SproutEngineTests/TemplateRendererTests.swift`

- [ ] **Step 1: Write failing tests**

Replace `Tests/SproutEngineTests/TemplateRendererTests.swift` (keep the two smoke tests, add real ones):

```swift
import Testing
import Foundation
@testable import SproutEngine

@Test func scaffoldCompiles() { #expect(true) }

@Test func fakeShellRecordsCalls() async throws {
    let shell = FakeShellRunner()
    shell.runResults = [("echo", ProcessResult(stdout: "hi", stderr: "", exitCode: 0))]
    let r = try await shell.run("echo hi", cwd: URL(fileURLWithPath: "/tmp"), env: [:])
    #expect(r.stdout == "hi")
    #expect(shell.calls.first?.command == "echo hi")
}

@Test func slugifyLowercasesAndReplacesNonAlnum() {
    #expect(TemplateContext.slugify("feature/Add-Login") == "feature_add_login")
    #expect(TemplateContext.slugify("  Hot Fix #42 ") == "hot_fix_42")
    #expect(TemplateContext.slugify("a--b__c") == "a_b_c")
}

@Test func renderReplacesAllVariables() {
    let ctx = TemplateContext(
        project: "shop", branch: "feature/Add-Login",
        port: 4011, dbName: "shop_feature_add_login",
        worktree: "/wt/shop-login"
    )
    let r = TemplateRenderer()
    #expect(r.render("{{project}}_{{branch_slug}}", ctx) == "shop_feature_add_login")
    #expect(r.render("port={{port}} db={{db_name}}", ctx)
            == "port=4011 db=shop_feature_add_login")
    #expect(r.render("{{worktree}}/.env", ctx) == "/wt/shop-login/.env")
    #expect(r.render("branch={{branch}}", ctx) == "branch=feature/Add-Login")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TemplateRendererTests`
Expected: FAIL — `TemplateContext`/`TemplateRenderer` not defined.

- [ ] **Step 3: Implement**

`Sources/SproutEngine/Config/TemplateRenderer.swift`:

```swift
import Foundation

public struct TemplateContext: Sendable {
    public var project: String
    public var branch: String
    public var port: Int
    public var dbName: String
    public var worktree: String

    public init(project: String, branch: String, port: Int, dbName: String, worktree: String) {
        self.project = project; self.branch = branch; self.port = port
        self.dbName = dbName; self.worktree = worktree
    }

    public var branchSlug: String { Self.slugify(branch) }

    /// Lowercase, collapse runs of non-alphanumeric chars to a single `_`, trim leading/trailing `_`.
    public static func slugify(_ s: String) -> String {
        var out = ""
        var lastUnderscore = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastUnderscore = false
            } else if !lastUnderscore {
                out.append("_"); lastUnderscore = true
            }
        }
        while out.hasPrefix("_") { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        return out
    }
}

public struct TemplateRenderer: Sendable {
    public init() {}

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
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter TemplateRendererTests`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Config/TemplateRenderer.swift Tests
git commit -m "feat(engine): add TemplateRenderer with branch slugify"
```

---

## Task 3: Config structs

Plain data, no behavior. No test needed beyond "it compiles + a value can be built"; one construction test guards field names.

**Files:**
- Create: `Sources/SproutEngine/Config/Config.swift`
- Create: `Tests/SproutEngineTests/Support/Fixtures.swift`

- [ ] **Step 1: Implement the structs**

`Sources/SproutEngine/Config/Config.swift`:

```swift
import Foundation

public struct Config: Sendable {
    public var project: ProjectConfig
    public var worktree: WorktreeConfig
    public var port: PortConfig
    public var env: EnvConfig
    public var database: DatabaseConfig
    public var setup: [SetupStep]
    public var run: RunConfig
    public var hooks: HooksConfig

    public init(project: ProjectConfig, worktree: WorktreeConfig, port: PortConfig,
                env: EnvConfig, database: DatabaseConfig, setup: [SetupStep],
                run: RunConfig, hooks: HooksConfig) {
        self.project = project; self.worktree = worktree; self.port = port
        self.env = env; self.database = database; self.setup = setup
        self.run = run; self.hooks = hooks
    }
}

public struct ProjectConfig: Sendable {
    public var name: String
    public init(name: String) { self.name = name }
}

public struct WorktreeConfig: Sendable {
    /// Directory where worktrees are created (template-rendered).
    public var baseDir: String
    public var branchPrefix: String
    public init(baseDir: String, branchPrefix: String) {
        self.baseDir = baseDir; self.branchPrefix = branchPrefix
    }
}

public struct PortConfig: Sendable {
    public var lower: Int
    public var upper: Int
    public init(lower: Int, upper: Int) { self.lower = lower; self.upper = upper }
}

public struct EnvConfig: Sendable {
    /// Filenames in the primary repo to symlink into the worktree (e.g. [".env"]).
    public var symlinkSources: [String]
    /// File the per-workspace overrides are written to (e.g. ".env.local").
    public var localFile: String
    public init(symlinkSources: [String], localFile: String) {
        self.symlinkSources = symlinkSources; self.localFile = localFile
    }
}

public struct DatabaseConfig: Sendable {
    public var createCommand: String   // template, e.g. "createdb {{db_name}}"
    public var dropCommand: String     // template, e.g. "dropdb --if-exists {{db_name}}"
    public var urlTemplate: String     // e.g. "postgres://localhost/{{db_name}}"
    public init(createCommand: String, dropCommand: String, urlTemplate: String) {
        self.createCommand = createCommand; self.dropCommand = dropCommand
        self.urlTemplate = urlTemplate
    }
}

public struct SetupStep: Sendable, Equatable {
    public var name: String
    public var command: String          // template
    public init(name: String, command: String) { self.name = name; self.command = command }
}

public struct RunConfig: Sendable {
    public var serverCommand: String    // template, long-running
    public init(serverCommand: String) { self.serverCommand = serverCommand }
}

public struct HooksConfig: Sendable {
    public var preTeardown: String?
    public var postTeardown: String?
    public init(preTeardown: String? = nil, postTeardown: String? = nil) {
        self.preTeardown = preTeardown; self.postTeardown = postTeardown
    }
}
```

- [ ] **Step 2: Add a reusable fixture for later tests**

`Tests/SproutEngineTests/Support/Fixtures.swift`:

```swift
import Foundation
@testable import SproutEngine

enum Fixtures {
    static func config() -> Config {
        Config(
            project: ProjectConfig(name: "shop"),
            worktree: WorktreeConfig(baseDir: "/wt", branchPrefix: "feature/"),
            port: PortConfig(lower: 4000, upper: 4010),
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
            run: RunConfig(serverCommand: "npm run dev"),
            hooks: HooksConfig()
        )
    }
}

@Test func fixtureConfigBuilds() {
    let c = Fixtures.config()
    #expect(c.project.name == "shop")
    #expect(c.setup.count == 2)
    #expect(c.port.lower == 4000)
}
```

Add `import Testing` at the top of `Fixtures.swift`.

- [ ] **Step 3: Run tests**

Run: `swift test --filter fixtureConfigBuilds`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/SproutEngine/Config/Config.swift Tests/SproutEngineTests/Support/Fixtures.swift
git commit -m "feat(engine): add Config data structs and test fixture"
```

---

## Task 4: StateStore protocol + WorkspaceRecord + JSONStateStore

**Files:**
- Create: `Sources/SproutEngine/State/StateStore.swift`
- Create: `Sources/SproutEngine/State/JSONStateStore.swift`
- Create: `Tests/SproutEngineTests/JSONStateStoreTests.swift`
- Create: `Tests/SproutEngineTests/Support/Fakes.swift`

- [ ] **Step 1: Write failing tests for JSONStateStore**

`Tests/SproutEngineTests/JSONStateStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sprout-\(UUID().uuidString).json")
}

private func sampleRecord(branch: String = "feature/login") -> WorkspaceRecord {
    WorkspaceRecord(
        id: UUID(), branch: branch, base: "main",
        worktreePath: "/wt/\(branch)", port: 4001, dbName: "shop_x",
        status: .running, serverPID: 123, createdAt: Date(timeIntervalSince1970: 0)
    )
}

@Test func loadReturnsEmptyWhenFileMissing() throws {
    let store = JSONStateStore(fileURL: tempFile())
    #expect(try store.load().isEmpty)
}

@Test func upsertThenLoadRoundTrips() throws {
    let store = JSONStateStore(fileURL: tempFile())
    let r = sampleRecord()
    try store.upsert(r)
    let loaded = try store.load()
    #expect(loaded == [r])
}

@Test func upsertReplacesSameID() throws {
    let store = JSONStateStore(fileURL: tempFile())
    var r = sampleRecord()
    try store.upsert(r)
    r.status = .stopped
    try store.upsert(r)
    let loaded = try store.load()
    #expect(loaded.count == 1)
    #expect(loaded.first?.status == .stopped)
}

@Test func removeDeletesByID() throws {
    let store = JSONStateStore(fileURL: tempFile())
    let r = sampleRecord()
    try store.upsert(r)
    try store.remove(id: r.id)
    #expect(try store.load().isEmpty)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter JSONStateStoreTests`
Expected: FAIL — `WorkspaceRecord`/`JSONStateStore` not defined.

- [ ] **Step 3: Implement protocol + record**

`Sources/SproutEngine/State/StateStore.swift`:

```swift
import Foundation

public enum WorkspaceStatus: String, Codable, Sendable {
    case creating, running, crashed, stopped, tearingDown
}

public struct WorkspaceRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var branch: String
    public var base: String
    public var worktreePath: String
    public var port: Int
    public var dbName: String
    public var status: WorkspaceStatus
    public var serverPID: Int32?
    public var createdAt: Date

    public init(id: UUID, branch: String, base: String, worktreePath: String,
                port: Int, dbName: String, status: WorkspaceStatus,
                serverPID: Int32?, createdAt: Date) {
        self.id = id; self.branch = branch; self.base = base
        self.worktreePath = worktreePath; self.port = port; self.dbName = dbName
        self.status = status; self.serverPID = serverPID; self.createdAt = createdAt
    }
}

public protocol StateStore: Sendable {
    func load() throws -> [WorkspaceRecord]
    func upsert(_ record: WorkspaceRecord) throws
    func remove(id: UUID) throws
}
```

- [ ] **Step 4: Implement JSONStateStore**

`Sources/SproutEngine/State/JSONStateStore.swift`:

```swift
import Foundation

/// File-backed store. Serializes the whole record array on each write (atomic).
/// Single-process use (the CLI); a serial queue guards concurrent calls within the process.
public final class JSONStateStore: StateStore, @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "sprout.jsonstatestore")

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> [WorkspaceRecord] {
        try queue.sync { try readAll() }
    }

    public func upsert(_ record: WorkspaceRecord) throws {
        try queue.sync {
            var all = try readAll()
            if let i = all.firstIndex(where: { $0.id == record.id }) { all[i] = record }
            else { all.append(record) }
            try writeAll(all)
        }
    }

    public func remove(id: UUID) throws {
        try queue.sync {
            var all = try readAll()
            all.removeAll { $0.id == id }
            try writeAll(all)
        }
    }

    private func readAll() throws -> [WorkspaceRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode([WorkspaceRecord].self, from: data)
    }

    private func writeAll(_ records: [WorkspaceRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 5: Add a FakeStateStore for later engine tests**

`Tests/SproutEngineTests/Support/Fakes.swift`:

```swift
import Foundation
@testable import SproutEngine

final class FakeStateStore: StateStore, @unchecked Sendable {
    var records: [WorkspaceRecord] = []
    func load() throws -> [WorkspaceRecord] { records }
    func upsert(_ record: WorkspaceRecord) throws {
        if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = record }
        else { records.append(record) }
    }
    func remove(id: UUID) throws { records.removeAll { $0.id == id } }
}

final class FakeProcessTerminator: ProcessTerminator, @unchecked Sendable {
    private(set) var terminated: [Int32] = []
    func terminate(pid: Int32, graceSeconds: Double) async { terminated.append(pid) }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter JSONStateStoreTests`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/SproutEngine/State Tests
git commit -m "feat(engine): add StateStore protocol, WorkspaceRecord, JSON-backed store"
```

---

## Task 5: PortAllocator

Allocates first port in range that is (a) not held by an existing record and (b) confirmed free by a prober. `PortProber` is injected for deterministic tests; a POSIX bind-probe is the real impl.

**Files:**
- Create: `Sources/SproutEngine/Port/PortAllocator.swift`
- Create: `Tests/SproutEngineTests/PortAllocatorTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/SproutEngineTests/PortAllocatorTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

private struct StubProber: PortProber {
    let busy: Set<Int>
    func isFree(_ port: Int) -> Bool { !busy.contains(port) }
}

private func record(port: Int) -> WorkspaceRecord {
    WorkspaceRecord(id: UUID(), branch: "b", base: "main", worktreePath: "/x",
                    port: port, dbName: "d", status: .running,
                    serverPID: nil, createdAt: Date())
}

@Test func allocatesFirstFreePort() throws {
    let store = FakeStateStore()
    let alloc = PortAllocator(config: PortConfig(lower: 4000, upper: 4010),
                              store: store, prober: StubProber(busy: []))
    #expect(try alloc.allocate() == 4000)
}

@Test func skipsPortsHeldByRecords() throws {
    let store = FakeStateStore()
    store.records = [record(port: 4000), record(port: 4001)]
    let alloc = PortAllocator(config: PortConfig(lower: 4000, upper: 4010),
                              store: store, prober: StubProber(busy: []))
    #expect(try alloc.allocate() == 4002)
}

@Test func skipsPortsProberSaysBusy() throws {
    let store = FakeStateStore()
    let alloc = PortAllocator(config: PortConfig(lower: 4000, upper: 4010),
                              store: store, prober: StubProber(busy: [4000, 4001]))
    #expect(try alloc.allocate() == 4002)
}

@Test func throwsWhenRangeExhausted() {
    let store = FakeStateStore()
    store.records = [record(port: 4000)]
    let alloc = PortAllocator(config: PortConfig(lower: 4000, upper: 4000),
                              store: store, prober: StubProber(busy: []))
    #expect(throws: PortError.noFreePort) { _ = try alloc.allocate() }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PortAllocatorTests`
Expected: FAIL — `PortAllocator`/`PortProber`/`PortError` not defined.

- [ ] **Step 3: Implement**

`Sources/SproutEngine/Port/PortAllocator.swift`:

```swift
import Foundation

public enum PortError: Error, Equatable { case noFreePort }

public protocol PortProber: Sendable {
    func isFree(_ port: Int) -> Bool
}

/// Real prober: attempts to bind 127.0.0.1:<port>. If bind succeeds the port is free.
public struct BindPortProber: PortProber {
    public init() {}
    public func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}

public struct PortAllocator: Sendable {
    let config: PortConfig
    let store: StateStore
    let prober: PortProber

    public init(config: PortConfig, store: StateStore, prober: PortProber) {
        self.config = config; self.store = store; self.prober = prober
    }

    public func allocate() throws -> Int {
        let held = Set(try store.load().map(\.port))
        for port in config.lower...config.upper {
            if held.contains(port) { continue }
            if prober.isFree(port) { return port }
        }
        throw PortError.noFreePort
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter PortAllocatorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Port Tests/SproutEngineTests/PortAllocatorTests.swift
git commit -m "feat(engine): add PortAllocator with bind-probe + record-aware skipping"
```

---

## Task 6: GitService

Builds `git` command strings and runs them through `ShellRunner`. Tests assert the exact command and that a non-zero exit throws.

**Files:**
- Create: `Sources/SproutEngine/Git/GitService.swift`
- Create: `Tests/SproutEngineTests/GitServiceTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/SproutEngineTests/GitServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

private let repo = URL(fileURLWithPath: "/repo")
private let wt = URL(fileURLWithPath: "/wt/login")

@Test func worktreeAddBuildsExpectedCommand() async throws {
    let shell = FakeShellRunner()
    let git = GitService(shell: shell)
    try await git.worktreeAdd(repo: repo, path: "/wt/login", base: "main", branch: "feature/login")
    #expect(shell.calls.last?.command
            == "git worktree add -b 'feature/login' '/wt/login' 'main'")
    #expect(shell.calls.last?.cwd == "/repo")
}

@Test func pushBuildsExpectedCommand() async throws {
    let shell = FakeShellRunner()
    let git = GitService(shell: shell)
    try await git.push(worktree: wt, branch: "feature/login")
    #expect(shell.calls.last?.command == "git push -u origin 'feature/login'")
    #expect(shell.calls.last?.cwd == "/wt/login")
}

@Test func isDirtyTrueWhenStatusNonEmpty() async throws {
    let shell = FakeShellRunner()
    shell.runResults = [("status --porcelain",
                         ProcessResult(stdout: " M file.txt\n", stderr: "", exitCode: 0))]
    let git = GitService(shell: shell)
    #expect(try await git.isDirty(worktree: wt) == true)
}

@Test func isDirtyFalseWhenStatusEmpty() async throws {
    let shell = FakeShellRunner()
    shell.runResults = [("status --porcelain",
                         ProcessResult(stdout: "", stderr: "", exitCode: 0))]
    let git = GitService(shell: shell)
    #expect(try await git.isDirty(worktree: wt) == false)
}

@Test func branchesParsesAndStripsMarkers() async throws {
    let shell = FakeShellRunner()
    shell.runResults = [("branch -a",
        ProcessResult(stdout: "* main\n  develop\n  remotes/origin/feature/x\n",
                      stderr: "", exitCode: 0))]
    let git = GitService(shell: shell)
    let branches = try await git.branches(repo: repo)
    #expect(branches == ["main", "develop", "remotes/origin/feature/x"])
}

@Test func nonZeroExitThrows() async {
    let shell = FakeShellRunner()
    shell.runResults = [("push", ProcessResult(stdout: "", stderr: "rejected", exitCode: 1))]
    let git = GitService(shell: shell)
    await #expect(throws: GitError.self) {
        try await git.push(worktree: wt, branch: "x")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter GitServiceTests`
Expected: FAIL — `GitService`/`GitError` not defined.

- [ ] **Step 3: Implement**

`Sources/SproutEngine/Git/GitService.swift`:

```swift
import Foundation

public enum GitError: Error, Equatable {
    case commandFailed(command: String, exitCode: Int32, stderr: String)
}

public struct GitService: Sendable {
    let shell: ShellRunner
    public init(shell: ShellRunner) { self.shell = shell }

    /// Single-quote-escape an argument for the shell.
    private func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private func runChecked(_ command: String, cwd: URL) async throws -> ProcessResult {
        let r = try await shell.run(command, cwd: cwd, env: [:])
        guard r.succeeded else {
            throw GitError.commandFailed(command: command, exitCode: r.exitCode, stderr: r.stderr)
        }
        return r
    }

    public func fetch(repo: URL) async throws {
        try await runChecked("git fetch --all --prune", cwd: repo)
    }

    public func branches(repo: URL) async throws -> [String] {
        let r = try await runChecked("git branch -a", cwd: repo)
        return r.stdout
            .split(separator: "\n")
            .map { $0.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public func worktreeAdd(repo: URL, path: String, base: String, branch: String) async throws {
        try await runChecked("git worktree add -b \(q(branch)) \(q(path)) \(q(base))", cwd: repo)
    }

    public func worktreeRemove(repo: URL, path: String) async throws {
        try await runChecked("git worktree remove --force \(q(path))", cwd: repo)
    }

    public func isDirty(worktree: URL) async throws -> Bool {
        let r = try await runChecked("git status --porcelain", cwd: worktree)
        return !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func push(worktree: URL, branch: String) async throws {
        try await runChecked("git push -u origin \(q(branch))", cwd: worktree)
    }

    public func deleteBranch(repo: URL, branch: String) async throws {
        try await runChecked("git branch -D \(q(branch))", cwd: repo)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter GitServiceTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Git Tests/SproutEngineTests/GitServiceTests.swift
git commit -m "feat(engine): add GitService (worktree, fetch, push, dirty-check, branch ops)"
```

---

## Task 7: DatabaseService

Renders the configured create/drop commands and the `DATABASE_URL`, runs create/drop through the shell.

**Files:**
- Create: `Sources/SproutEngine/Database/DatabaseService.swift`
- Create: `Tests/SproutEngineTests/DatabaseServiceTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/SproutEngineTests/DatabaseServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

private let cwd = URL(fileURLWithPath: "/repo")
private func ctx() -> TemplateContext {
    TemplateContext(project: "shop", branch: "feature/login", port: 4001,
                    dbName: "shop_feature_login", worktree: "/wt/login")
}

@Test func createRendersAndRunsCommand() async throws {
    let shell = FakeShellRunner()
    let db = DatabaseService(shell: shell, renderer: TemplateRenderer())
    try await db.create(Fixtures.config().database, ctx: ctx(), cwd: cwd)
    #expect(shell.calls.last?.command == "createdb shop_feature_login")
}

@Test func dropRendersAndRunsCommand() async throws {
    let shell = FakeShellRunner()
    let db = DatabaseService(shell: shell, renderer: TemplateRenderer())
    try await db.drop(Fixtures.config().database, ctx: ctx(), cwd: cwd)
    #expect(shell.calls.last?.command == "dropdb --if-exists shop_feature_login")
}

@Test func databaseURLRenders() {
    let db = DatabaseService(shell: FakeShellRunner(), renderer: TemplateRenderer())
    #expect(db.databaseURL(Fixtures.config().database, ctx: ctx())
            == "postgres://localhost/shop_feature_login")
}

@Test func createThrowsOnNonZeroExit() async {
    let shell = FakeShellRunner()
    shell.runResults = [("createdb", ProcessResult(stdout: "", stderr: "exists", exitCode: 1))]
    let db = DatabaseService(shell: shell, renderer: TemplateRenderer())
    await #expect(throws: DatabaseError.self) {
        try await db.create(Fixtures.config().database, ctx: ctx(), cwd: cwd)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DatabaseServiceTests`
Expected: FAIL — `DatabaseService`/`DatabaseError` not defined.

- [ ] **Step 3: Implement**

`Sources/SproutEngine/Database/DatabaseService.swift`:

```swift
import Foundation

public enum DatabaseError: Error, Equatable {
    case commandFailed(command: String, exitCode: Int32, stderr: String)
}

public struct DatabaseService: Sendable {
    let shell: ShellRunner
    let renderer: TemplateRenderer
    public init(shell: ShellRunner, renderer: TemplateRenderer) {
        self.shell = shell; self.renderer = renderer
    }

    public func create(_ config: DatabaseConfig, ctx: TemplateContext, cwd: URL) async throws {
        try await runChecked(renderer.render(config.createCommand, ctx), cwd: cwd)
    }

    public func drop(_ config: DatabaseConfig, ctx: TemplateContext, cwd: URL) async throws {
        try await runChecked(renderer.render(config.dropCommand, ctx), cwd: cwd)
    }

    public func databaseURL(_ config: DatabaseConfig, ctx: TemplateContext) -> String {
        renderer.render(config.urlTemplate, ctx)
    }

    private func runChecked(_ command: String, cwd: URL) async throws {
        let r = try await shell.run(command, cwd: cwd, env: [:])
        guard r.succeeded else {
            throw DatabaseError.commandFailed(command: command, exitCode: r.exitCode, stderr: r.stderr)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter DatabaseServiceTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Database Tests/SproutEngineTests/DatabaseServiceTests.swift
git commit -m "feat(engine): add DatabaseService (create/drop/url rendering)"
```

---

## Task 8: EnvLinker

Symlinks shared env files from the primary repo into the worktree, and writes per-workspace overrides to the local env file. File ops go through a `FileSystem` protocol for deterministic tests.

**Files:**
- Create: `Sources/SproutEngine/Env/EnvLinker.swift`
- Create: `Tests/SproutEngineTests/EnvLinkerTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/SproutEngineTests/EnvLinkerTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

private let repo = URL(fileURLWithPath: "/repo")
private let wt = URL(fileURLWithPath: "/wt/login")

@Test func linkCreatesSymlinkPerSource() throws {
    let fs = FakeFileSystem()
    fs.existing = ["/repo/.env"]
    let linker = EnvLinker(fs: fs)
    try linker.link(sources: [".env"], primaryRepo: repo, worktree: wt)
    #expect(fs.symlinks == [.init(from: "/repo/.env", to: "/wt/login/.env")])
}

@Test func linkSkipsMissingSource() throws {
    let fs = FakeFileSystem()
    fs.existing = []
    let linker = EnvLinker(fs: fs)
    try linker.link(sources: [".env"], primaryRepo: repo, worktree: wt)
    #expect(fs.symlinks.isEmpty)
}

@Test func writeLocalWritesPortAndDatabaseURL() throws {
    let fs = FakeFileSystem()
    let linker = EnvLinker(fs: fs)
    try linker.writeLocal(file: ".env.local", worktree: wt,
                          port: 4001, databaseURL: "postgres://localhost/shop_x")
    #expect(fs.writes.count == 1)
    #expect(fs.writes.first?.path == "/wt/login/.env.local")
    #expect(fs.writes.first?.contents == "PORT=4001\nDATABASE_URL=postgres://localhost/shop_x\n")
}
```

- [ ] **Step 2: Add FakeFileSystem to Fakes.swift**

Append to `Tests/SproutEngineTests/Support/Fakes.swift`:

```swift
final class FakeFileSystem: FileSystem, @unchecked Sendable {
    struct Symlink: Equatable { let from: String; let to: String }
    struct WriteOp: Equatable { let contents: String; let path: String }

    var existing: Set<String> = []
    private(set) var symlinks: [Symlink] = []
    private(set) var writes: [WriteOp] = []
    private(set) var removed: [String] = []

    func symlink(from: URL, to: URL) throws {
        symlinks.append(.init(from: from.path, to: to.path))
    }
    func write(_ contents: String, to url: URL) throws {
        writes.append(.init(contents: contents, path: url.path))
    }
    func fileExists(_ url: URL) -> Bool { existing.contains(url.path) }
    func removeItem(_ url: URL) throws { removed.append(url.path) }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter EnvLinkerTests`
Expected: FAIL — `EnvLinker`/`FileSystem` not defined.

- [ ] **Step 4: Implement**

`Sources/SproutEngine/Env/EnvLinker.swift`:

```swift
import Foundation

public protocol FileSystem: Sendable {
    func symlink(from: URL, to: URL) throws
    func write(_ contents: String, to url: URL) throws
    func fileExists(_ url: URL) -> Bool
    func removeItem(_ url: URL) throws
}

/// Real impl backed by FileManager.
public struct RealFileSystem: FileSystem {
    public init() {}
    public func symlink(from: URL, to: URL) throws {
        if FileManager.default.fileExists(atPath: to.path) {
            try FileManager.default.removeItem(at: to)
        }
        try FileManager.default.createSymbolicLink(at: to, withDestinationURL: from)
    }
    public func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    public func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
    public func removeItem(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

public struct EnvLinker: Sendable {
    let fs: FileSystem
    public init(fs: FileSystem) { self.fs = fs }

    /// Symlink each existing source file from the primary repo into the worktree.
    public func link(sources: [String], primaryRepo: URL, worktree: URL) throws {
        for name in sources {
            let src = primaryRepo.appendingPathComponent(name)
            guard fs.fileExists(src) else { continue }
            let dst = worktree.appendingPathComponent(name)
            try fs.symlink(from: src, to: dst)
        }
    }

    /// Write per-workspace overrides (PORT, DATABASE_URL) to the local env file.
    public func writeLocal(file: String, worktree: URL, port: Int, databaseURL: String) throws {
        let contents = "PORT=\(port)\nDATABASE_URL=\(databaseURL)\n"
        try fs.write(contents, to: worktree.appendingPathComponent(file))
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter EnvLinkerTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutEngine/Env Tests
git commit -m "feat(engine): add EnvLinker (symlink shared env, write per-workspace overrides)"
```

---

## Task 9: SetupRunner

Runs `[setup]` steps in order via `shell.launch`, streams each step's logs to a callback, awaits exit, stops on the first non-zero exit and throws with the failing step index.

**Files:**
- Create: `Sources/SproutEngine/Setup/SetupRunner.swift`
- Create: `Tests/SproutEngineTests/SetupRunnerTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/SproutEngineTests/SetupRunnerTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

private let cwd = URL(fileURLWithPath: "/wt/login")
private func ctx() -> TemplateContext {
    TemplateContext(project: "shop", branch: "login", port: 4001,
                    dbName: "shop_login", worktree: "/wt/login")
}

@Test func runsAllStepsInOrderOnSuccess() async throws {
    let shell = FakeShellRunner()
    let runner = SetupRunner(shell: shell, renderer: TemplateRenderer())
    let steps = [SetupStep(name: "deps", command: "npm ci"),
                 SetupStep(name: "migrate", command: "npm run migrate")]
    try await runner.run(steps, ctx: ctx(), cwd: cwd, env: [:]) { _ in }
    #expect(shell.calls.map(\.command) == ["npm ci", "npm run migrate"])
}

@Test func streamsLogsToCallback() async throws {
    let shell = FakeShellRunner()
    shell.handles = [("npm ci", {
        FakeProcessHandle(pid: 1, exitCode: 0,
                          lines: [LogLine(source: .stdout, text: "installing")])
    })]
    let runner = SetupRunner(shell: shell, renderer: TemplateRenderer())
    var captured: [String] = []
    try await runner.run([SetupStep(name: "deps", command: "npm ci")],
                         ctx: ctx(), cwd: cwd, env: [:]) { captured.append($0.text) }
    #expect(captured == ["installing"])
}

@Test func stopsAndThrowsOnFailingStep() async {
    let shell = FakeShellRunner()
    shell.handles = [("npm run migrate", {
        FakeProcessHandle(pid: 2, exitCode: 1, lines: [])
    })]
    let runner = SetupRunner(shell: shell, renderer: TemplateRenderer())
    let steps = [SetupStep(name: "deps", command: "npm ci"),
                 SetupStep(name: "migrate", command: "npm run migrate"),
                 SetupStep(name: "seed", command: "npm run seed")]
    await #expect {
        try await runner.run(steps, ctx: ctx(), cwd: cwd, env: [:]) { _ in }
    } throws: { error in
        guard case let SetupError.stepFailed(index, name, code) = error else { return false }
        return index == 1 && name == "migrate" && code == 1
    }
    // "seed" must not have run
    #expect(!shell.calls.map(\.command).contains("npm run seed"))
}

@Test func rendersTemplatesInCommands() async throws {
    let shell = FakeShellRunner()
    let runner = SetupRunner(shell: shell, renderer: TemplateRenderer())
    try await runner.run([SetupStep(name: "echo", command: "echo {{db_name}}")],
                         ctx: ctx(), cwd: cwd, env: [:]) { _ in }
    #expect(shell.calls.last?.command == "echo shop_login")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SetupRunnerTests`
Expected: FAIL — `SetupRunner`/`SetupError` not defined.

- [ ] **Step 3: Implement**

`Sources/SproutEngine/Setup/SetupRunner.swift`:

```swift
import Foundation

public enum SetupError: Error, Equatable {
    case stepFailed(index: Int, name: String, exitCode: Int32)
}

public struct SetupRunner: Sendable {
    let shell: ShellRunner
    let renderer: TemplateRenderer
    public init(shell: ShellRunner, renderer: TemplateRenderer) {
        self.shell = shell; self.renderer = renderer
    }

    /// Runs steps sequentially. Streams logs to `onLog`. Throws on first non-zero exit.
    public func run(_ steps: [SetupStep], ctx: TemplateContext, cwd: URL,
                    env: [String: String],
                    onLog: @Sendable (LogLine) -> Void) async throws {
        for (index, step) in steps.enumerated() {
            let command = renderer.render(step.command, ctx)
            let handle = try shell.launch(command, cwd: cwd, env: env)
            for await line in handle.logs { onLog(line) }
            let code = await handle.waitForExit()
            guard code == 0 else {
                throw SetupError.stepFailed(index: index, name: step.name, exitCode: code)
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter SetupRunnerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Setup Tests/SproutEngineTests/SetupRunnerTests.swift
git commit -m "feat(engine): add SetupRunner (ordered steps, streamed logs, stop-on-fail)"
```

---

## Task 10: ServerSupervisor

An `actor` owning the long-running server process. Starts via `shell.launch`, tracks PID + status, detects unexpected exit (status → `crashed` if non-zero, `stopped` if it stopped it deliberately), supports restart and graceful stop.

**Files:**
- Create: `Sources/SproutEngine/Server/ServerSupervisor.swift`
- Create: `Tests/SproutEngineTests/ServerSupervisorTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/SproutEngineTests/ServerSupervisorTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

private let cwd = URL(fileURLWithPath: "/wt/login")
private func ctx() -> TemplateContext {
    TemplateContext(project: "shop", branch: "login", port: 4001,
                    dbName: "shop_login", worktree: "/wt/login")
}

@Test func startReturnsPidAndSetsRunning() async throws {
    let shell = FakeShellRunner()
    shell.handles = [("npm run dev", { FakeProcessHandle(pid: 555, exitCode: 0, lines: []) })]
    let sup = ServerSupervisor(shell: shell, renderer: TemplateRenderer())
    let pid = try await sup.start(command: "npm run dev", ctx: ctx(), cwd: cwd, env: [:]) { _ in }
    #expect(pid == 555)
    #expect(await sup.status == .running)
    #expect(await sup.pid == 555)
}

@Test func stopTerminatesAndSetsStopped() async throws {
    let shell = FakeShellRunner()
    let handle = FakeProcessHandle(pid: 1, exitCode: 0, lines: [])
    shell.handles = [("npm run dev", { handle })]
    let sup = ServerSupervisor(shell: shell, renderer: TemplateRenderer())
    _ = try await sup.start(command: "npm run dev", ctx: ctx(), cwd: cwd, env: [:]) { _ in }
    await sup.stop(graceSeconds: 0)
    #expect(await sup.status == .stopped)
    #expect(handle.terminated == true)
}

@Test func rendersServerCommandTemplate() async throws {
    let shell = FakeShellRunner()
    let sup = ServerSupervisor(shell: shell, renderer: TemplateRenderer())
    _ = try await sup.start(command: "serve --port {{port}}", ctx: ctx(), cwd: cwd, env: [:]) { _ in }
    #expect(shell.calls.last?.command == "serve --port 4001")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ServerSupervisorTests`
Expected: FAIL — `ServerSupervisor` not defined.

- [ ] **Step 3: Implement**

`Sources/SproutEngine/Server/ServerSupervisor.swift`:

```swift
import Foundation

public actor ServerSupervisor {
    public enum Status: Sendable, Equatable { case starting, running, crashed, stopped }

    private let shell: ShellRunner
    private let renderer: TemplateRenderer
    private var handle: ProcessHandle?
    private var stopping = false
    public private(set) var status: Status = .stopped

    public init(shell: ShellRunner, renderer: TemplateRenderer) {
        self.shell = shell; self.renderer = renderer
    }

    public var pid: Int32? { handle?.pid }

    /// Starts the server. Returns its PID. Logs stream to `onLog`. Exit is watched in the background.
    @discardableResult
    public func start(command: String, ctx: TemplateContext, cwd: URL,
                      env: [String: String],
                      onLog: @escaping @Sendable (LogLine) -> Void) async throws -> Int32 {
        status = .starting
        stopping = false
        let rendered = renderer.render(command, ctx)
        let h = try shell.launch(rendered, cwd: cwd, env: env)
        handle = h
        status = .running

        // Stream logs in the background.
        Task { for await line in h.logs { onLog(line) } }
        // Watch for exit and update status.
        Task { [weak self] in
            let code = await h.waitForExit()
            await self?.handleExit(code: code)
        }
        return h.pid
    }

    public func stop(graceSeconds: Double) async {
        stopping = true
        await handle?.terminate(graceSeconds: graceSeconds)
        handle = nil
        status = .stopped
    }

    @discardableResult
    public func restart(command: String, ctx: TemplateContext, cwd: URL,
                        env: [String: String],
                        onLog: @escaping @Sendable (LogLine) -> Void) async throws -> Int32 {
        await stop(graceSeconds: 5)
        return try await start(command: command, ctx: ctx, cwd: cwd, env: env, onLog: onLog)
    }

    private func handleExit(code: Int32) {
        guard !stopping else { return }   // expected shutdown already set .stopped
        status = (code == 0) ? .stopped : .crashed
        handle = nil
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ServerSupervisorTests`
Expected: PASS (3 tests).

> Note: `start` returns immediately after launch; the exit-watcher runs in a detached `Task`. In `stopTerminatesAndSetsStopped`, `stop` sets `.stopped` synchronously and `stopping` guards the watcher from overriding it.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Server Tests/SproutEngineTests/ServerSupervisorTests.swift
git commit -m "feat(engine): add ServerSupervisor actor (start/stop/restart, status tracking)"
```

---

## Task 11: WorkspaceManager — create flow + rollback

The orchestrator. This task covers `create` (and its rollback on failure). Teardown and reconcile follow in Tasks 11b/11c to keep each bite-sized.

`ProcessChecker` (PID liveness) is introduced here for reconcile use later; its real impl uses `kill(pid, 0)`.

**Files:**
- Create: `Sources/SproutEngine/Workspace/WorkspaceManager.swift`
- Create: `Tests/SproutEngineTests/WorkspaceManagerTests.swift`

- [ ] **Step 1: Write failing tests for create + rollback**

`Tests/SproutEngineTests/WorkspaceManagerTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

private let repo = URL(fileURLWithPath: "/repo")

private struct AliveChecker: ProcessChecker {
    let alive: Set<Int32>
    func isAlive(pid: Int32) -> Bool { alive.contains(pid) }
}

private func makeManager(shell: FakeShellRunner, store: FakeStateStore,
                         fs: FakeFileSystem = FakeFileSystem(),
                         prober: PortProber,
                         checker: ProcessChecker = AliveChecker(alive: []),
                         terminator: FakeProcessTerminator = FakeProcessTerminator())
                         -> WorkspaceManager {
    let renderer = TemplateRenderer()
    return WorkspaceManager(
        git: GitService(shell: shell),
        portAllocator: PortAllocator(config: PortConfig(lower: 4000, upper: 4010),
                                     store: store, prober: prober),
        database: DatabaseService(shell: shell, renderer: renderer),
        envLinker: EnvLinker(fs: fs), fs: fs,
        setupRunner: SetupRunner(shell: shell, renderer: renderer),
        store: store, checker: checker, terminator: terminator,
        renderer: renderer, shell: shell
    )
}

private struct FreeProber: PortProber { func isFree(_ port: Int) -> Bool { true } }

@Test func createPersistsRunningRecordWithPortAndDB() async throws {
    let shell = FakeShellRunner()
    shell.handles = [("npm run dev", { FakeProcessHandle(pid: 900, exitCode: 0, lines: []) })]
    let store = FakeStateStore()
    let fs = FakeFileSystem(); fs.existing = ["/repo/.env"]
    let mgr = makeManager(shell: shell, store: store, fs: fs, prober: FreeProber())

    let rec = try await mgr.create(config: Fixtures.config(), repo: repo,
                                   base: "main", branch: "feature/login") { _ in }

    #expect(rec.port == 4000)
    #expect(rec.dbName == "shop_feature_login")
    #expect(rec.status == .running)
    #expect(rec.serverPID == 900)
    #expect(store.records.count == 1)
    // worktree created under baseDir/branch_slug
    #expect(rec.worktreePath == "/wt/feature_login")
    // env.local written
    #expect(fs.writes.contains { $0.path == "/wt/feature_login/.env.local" })
}

@Test func createRollsBackWhenSetupFails() async throws {
    let shell = FakeShellRunner()
    // make the migrate step fail
    shell.handles = [("npm run migrate", { FakeProcessHandle(pid: 1, exitCode: 1, lines: []) })]
    let store = FakeStateStore()
    let mgr = makeManager(shell: shell, store: store, prober: FreeProber())

    await #expect(throws: SetupError.self) {
        _ = try await mgr.create(config: Fixtures.config(), repo: repo,
                                 base: "main", branch: "feature/login") { _ in }
    }
    // rollback: record removed, drop + worktree remove issued
    #expect(store.records.isEmpty)
    let cmds = shell.calls.map(\.command)
    #expect(cmds.contains("dropdb --if-exists shop_feature_login"))
    #expect(cmds.contains("git worktree remove --force '/wt/feature_login'"))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WorkspaceManagerTests`
Expected: FAIL — `WorkspaceManager`/`ProcessChecker` not defined.

- [ ] **Step 3: Implement WorkspaceManager (create + rollback) + ProcessChecker**

`Sources/SproutEngine/Workspace/WorkspaceManager.swift`:

```swift
import Foundation

public protocol ProcessChecker: Sendable {
    func isAlive(pid: Int32) -> Bool
}

public struct PosixProcessChecker: ProcessChecker {
    public init() {}
    public func isAlive(pid: Int32) -> Bool { kill(pid, 0) == 0 }
}

/// Terminates a running process (by PID) and its process group.
public protocol ProcessTerminator: Sendable {
    func terminate(pid: Int32, graceSeconds: Double) async
}

/// Real impl: SIGTERM the process group (-pid), wait the grace period, then SIGKILL.
public struct PosixProcessTerminator: ProcessTerminator {
    public init() {}
    public func terminate(pid: Int32, graceSeconds: Double) async {
        kill(-pid, SIGTERM)
        try? await Task.sleep(nanoseconds: UInt64(graceSeconds * 1_000_000_000))
        if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
    }
}

public struct WorkspaceManager: Sendable {
    let git: GitService
    let portAllocator: PortAllocator
    let database: DatabaseService
    let envLinker: EnvLinker
    let fs: FileSystem
    let setupRunner: SetupRunner
    let store: StateStore
    let checker: ProcessChecker
    let terminator: ProcessTerminator
    let renderer: TemplateRenderer
    let shell: ShellRunner

    public init(git: GitService, portAllocator: PortAllocator, database: DatabaseService,
                envLinker: EnvLinker, fs: FileSystem, setupRunner: SetupRunner,
                store: StateStore, checker: ProcessChecker, terminator: ProcessTerminator,
                renderer: TemplateRenderer, shell: ShellRunner) {
        self.git = git; self.portAllocator = portAllocator; self.database = database
        self.envLinker = envLinker; self.fs = fs; self.setupRunner = setupRunner
        self.store = store; self.checker = checker; self.terminator = terminator
        self.renderer = renderer; self.shell = shell
    }

    private func context(config: Config, branch: String, port: Int,
                         dbName: String, worktree: String) -> TemplateContext {
        TemplateContext(project: config.project.name, branch: branch,
                        port: port, dbName: dbName, worktree: worktree)
    }

    public func create(config: Config, repo: URL, base: String, branch: String,
                       onLog: @escaping @Sendable (LogLine) -> Void) async throws -> WorkspaceRecord {
        let slug = TemplateContext.slugify(branch)
        let worktreePath = "\(config.worktree.baseDir)/\(slug)"
        let worktreeURL = URL(fileURLWithPath: worktreePath)
        let dbName = "\(config.project.name)_\(slug)"

        // Track what to roll back, in reverse order.
        var didWorktree = false, didDB = false

        do {
            try await git.worktreeAdd(repo: repo, path: worktreePath, base: base, branch: branch)
            didWorktree = true

            let port = try portAllocator.allocate()
            let ctx = context(config: config, branch: branch, port: port,
                              dbName: dbName, worktree: worktreePath)

            try await database.create(config.database, ctx: ctx, cwd: repo)
            didDB = true

            try envLinker.link(sources: config.env.symlinkSources,
                               primaryRepo: repo, worktree: worktreeURL)
            let dbURL = database.databaseURL(config.database, ctx: ctx)
            try envLinker.writeLocal(file: config.env.localFile, worktree: worktreeURL,
                                     port: port, databaseURL: dbURL)

            var record = WorkspaceRecord(
                id: UUID(), branch: branch, base: base, worktreePath: worktreePath,
                port: port, dbName: dbName, status: .creating,
                serverPID: nil, createdAt: Date())
            try store.upsert(record)

            let childEnv = ["PORT": String(port), "DATABASE_URL": dbURL]
            try await setupRunner.run(config.setup, ctx: ctx, cwd: worktreeURL,
                                      env: childEnv, onLog: onLog)

            let supervisor = ServerSupervisor(shell: shell, renderer: renderer)
            let pid = try await supervisor.start(command: config.run.serverCommand, ctx: ctx,
                                                 cwd: worktreeURL, env: childEnv, onLog: onLog)
            record.serverPID = pid
            record.status = .running
            try store.upsert(record)
            return record
        } catch {
            await rollback(config: config, repo: repo, worktreePath: worktreePath,
                           dbName: dbName, branch: branch,
                           didWorktree: didWorktree, didDB: didDB)
            throw error
        }
    }

    private func rollback(config: Config, repo: URL, worktreePath: String, dbName: String,
                          branch: String, didWorktree: Bool, didDB: Bool) async {
        // remove any persisted record for this branch
        if let existing = try? store.load().first(where: { $0.branch == branch }) {
            try? store.remove(id: existing.id)
        }
        if didDB {
            let ctx = context(config: config, branch: branch, port: 0,
                              dbName: dbName, worktree: worktreePath)
            try? await database.drop(config.database, ctx: ctx, cwd: repo)
        }
        if didWorktree {
            try? await git.worktreeRemove(repo: repo, path: worktreePath)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter WorkspaceManagerTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Workspace Tests/SproutEngineTests/WorkspaceManagerTests.swift
git commit -m "feat(engine): add WorkspaceManager create flow with rollback + ProcessChecker"
```

---

## Task 11b: WorkspaceManager — teardown flow

`Done` = push then destroy; aborts if dirty (unless `force`) or push fails. `Discard` = destroy without push and skip dirty-check. Teardown order: pre-hook → (push) → stop server → drop DB → remove worktree → delete branch → post-hook → clear state.

**Files:**
- Modify: `Sources/SproutEngine/Workspace/WorkspaceManager.swift`
- Modify: `Tests/SproutEngineTests/WorkspaceManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `Tests/SproutEngineTests/WorkspaceManagerTests.swift`:

```swift
private func seedRecord(into store: FakeStateStore, pid: Int32? = 900) -> WorkspaceRecord {
    let r = WorkspaceRecord(
        id: UUID(), branch: "feature/login", base: "main",
        worktreePath: "/wt/feature_login", port: 4000, dbName: "shop_feature_login",
        status: .running, serverPID: pid, createdAt: Date())
    store.records = [r]
    return r
}

@Test func teardownWithPushRunsFullOrderAndClearsState() async throws {
    let shell = FakeShellRunner()
    shell.runResults = [("status --porcelain", ProcessResult(stdout: "", stderr: "", exitCode: 0))]
    let store = FakeStateStore()
    let term = FakeProcessTerminator()
    let r = seedRecord(into: store)
    let mgr = makeManager(shell: shell, store: store, prober: FreeProber(), terminator: term)

    try await mgr.teardown(id: r.id, config: Fixtures.config(), repo: repo,
                           push: true, force: false)

    let cmds = shell.calls.map(\.command)
    #expect(cmds.contains("git push -u origin 'feature/login'"))
    #expect(cmds.contains("dropdb --if-exists shop_feature_login"))
    #expect(cmds.contains("git worktree remove --force '/wt/feature_login'"))
    #expect(cmds.contains("git branch -D 'feature/login'"))
    #expect(term.terminated == [900])
    #expect(store.records.isEmpty)
}

@Test func teardownAbortsWhenDirtyAndNotForced() async {
    let shell = FakeShellRunner()
    shell.runResults = [("status --porcelain",
                         ProcessResult(stdout: " M f\n", stderr: "", exitCode: 0))]
    let store = FakeStateStore()
    let r = seedRecord(into: store)
    let mgr = makeManager(shell: shell, store: store, prober: FreeProber())

    await #expect(throws: TeardownError.self) {
        try await mgr.teardown(id: r.id, config: Fixtures.config(), repo: repo,
                               push: true, force: false)
    }
    // record still present, no destructive commands ran
    #expect(store.records.count == 1)
    #expect(!shell.calls.map(\.command).contains("git push -u origin 'feature/login'"))
}

@Test func discardSkipsPushAndDirtyCheck() async throws {
    let shell = FakeShellRunner()
    // dirty, but discard must ignore it
    shell.runResults = [("status --porcelain",
                         ProcessResult(stdout: " M f\n", stderr: "", exitCode: 0))]
    let store = FakeStateStore()
    let term = FakeProcessTerminator()
    let r = seedRecord(into: store)
    let mgr = makeManager(shell: shell, store: store, prober: FreeProber(), terminator: term)

    try await mgr.teardown(id: r.id, config: Fixtures.config(), repo: repo,
                           push: false, force: false)

    let cmds = shell.calls.map(\.command)
    #expect(!cmds.contains("git push -u origin 'feature/login'"))
    #expect(cmds.contains("dropdb --if-exists shop_feature_login"))
    #expect(store.records.isEmpty)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WorkspaceManagerTests`
Expected: FAIL — `teardown`/`TeardownError` not defined.

- [ ] **Step 3: Implement teardown**

Add to `WorkspaceManager` (and a new error enum at file top):

```swift
public enum TeardownError: Error, Equatable {
    case workspaceNotFound(UUID)
    case dirtyWorktree
}
```

```swift
public func teardown(id: UUID, config: Config, repo: URL,
                     push: Bool, force: Bool) async throws {
    guard let record = try store.load().first(where: { $0.id == id }) else {
        throw TeardownError.workspaceNotFound(id)
    }
    let worktreeURL = URL(fileURLWithPath: record.worktreePath)
    let ctx = context(config: config, branch: record.branch, port: record.port,
                      dbName: record.dbName, worktree: record.worktreePath)

    // pre-hook
    if let pre = config.hooks.preTeardown {
        _ = try? await shell.run(renderer.render(pre, ctx), cwd: worktreeURL, env: [:])
    }

    if push {
        if try await git.isDirty(worktree: worktreeURL), !force {
            throw TeardownError.dirtyWorktree
        }
        try await git.push(worktree: worktreeURL, branch: record.branch)
    }

    // stop server
    if let pid = record.serverPID {
        await terminator.terminate(pid: pid, graceSeconds: 5)
    }
    // drop DB
    try await database.drop(config.database, ctx: ctx, cwd: repo)
    // remove worktree
    try await git.worktreeRemove(repo: repo, path: record.worktreePath)
    // delete branch
    try await git.deleteBranch(repo: repo, branch: record.branch)

    // post-hook
    if let post = config.hooks.postTeardown {
        _ = try? await shell.run(renderer.render(post, ctx), cwd: repo, env: [:])
    }

    try store.remove(id: id)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter WorkspaceManagerTests`
Expected: PASS (5 tests total in this file).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Workspace Tests/SproutEngineTests/WorkspaceManagerTests.swift
git commit -m "feat(engine): add WorkspaceManager teardown (push/dirty-guard, ordered destroy)"
```

---

## Task 11c: WorkspaceManager — reconcile

On startup, reconcile persisted records against reality: a dead recorded PID → `stopped`; a live PID → keep `running`; a missing worktree directory → flagged orphaned. Worktree existence checked via the injected `FileSystem`.

**Files:**
- Modify: `Sources/SproutEngine/Workspace/WorkspaceManager.swift`
- Modify: `Tests/SproutEngineTests/WorkspaceManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `Tests/SproutEngineTests/WorkspaceManagerTests.swift`:

```swift
@Test func reconcileMarksDeadPidStopped() throws {
    let shell = FakeShellRunner()
    let store = FakeStateStore()
    let fs = FakeFileSystem(); fs.existing = ["/wt/feature_login"]
    _ = seedRecord(into: store, pid: 900)   // pid 900 not alive
    let mgr = makeManager(shell: shell, store: store, fs: fs, prober: FreeProber(),
                          checker: AliveChecker(alive: []))
    let result = try mgr.reconcile()
    #expect(result.first?.status == .stopped)
    #expect(store.records.first?.status == .stopped)
    #expect(result.first?.orphaned == false)
}

@Test func reconcileKeepsRunningWhenPidAlive() throws {
    let shell = FakeShellRunner()
    let store = FakeStateStore()
    let fs = FakeFileSystem(); fs.existing = ["/wt/feature_login"]
    _ = seedRecord(into: store, pid: 900)
    let mgr = makeManager(shell: shell, store: store, fs: fs, prober: FreeProber(),
                          checker: AliveChecker(alive: [900]))
    let result = try mgr.reconcile()
    #expect(result.first?.status == .running)
}

@Test func reconcileFlagsMissingWorktreeAsOrphaned() throws {
    let shell = FakeShellRunner()
    let store = FakeStateStore()
    let fs = FakeFileSystem(); fs.existing = []   // worktree gone
    _ = seedRecord(into: store, pid: nil)
    let mgr = makeManager(shell: shell, store: store, fs: fs, prober: FreeProber(),
                          checker: AliveChecker(alive: []))
    let result = try mgr.reconcile()
    #expect(result.first?.orphaned == true)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WorkspaceManagerTests`
Expected: FAIL — `reconcile`/`ReconciledWorkspace` not defined.

- [ ] **Step 3: Implement reconcile**

`WorkspaceManager` already holds the injected `fs: FileSystem` (wired in Task 11). Use it to check worktree existence. Add the result type + method:

```swift
public struct ReconciledWorkspace: Sendable, Equatable {
    public var record: WorkspaceRecord
    public var orphaned: Bool   // worktree directory no longer exists
    public var status: WorkspaceStatus { record.status }
}

public func reconcile() throws -> [ReconciledWorkspace] {
    var out: [ReconciledWorkspace] = []
    for var record in try store.load() {
        let alive = record.serverPID.map { checker.isAlive(pid: $0) } ?? false
        if !alive, record.status == .running {
            record.status = .stopped
            record.serverPID = nil
            try store.upsert(record)
        }
        let orphaned = !fs.fileExists(URL(fileURLWithPath: record.worktreePath))
        out.append(ReconciledWorkspace(record: record, orphaned: orphaned))
    }
    return out
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter WorkspaceManagerTests`
Expected: PASS (8 tests total).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Workspace Tests/SproutEngineTests/WorkspaceManagerTests.swift
git commit -m "feat(engine): add WorkspaceManager reconcile (PID liveness + orphan detection)"
```

---

## Task 12: LoginShellRunner (real ShellRunner impl)

The production `ShellRunner`. Solves the GUI-PATH problem by running every command through the user's **login shell** (`-l -c`), so `nvm`/`asdf`/`rbenv`/Homebrew PATH load. `launch` uses `posix_spawn` with a new session so the child is its own process-group leader — `PosixProcessTerminator` then signals `-pid` to kill the whole tree (e.g. `node` under `npm run dev`).

This task is verified by the gated integration tests in Task 15 (it touches real processes); no fake-based unit test here. Steps below build + a smoke check.

**Files:**
- Modify: `Sources/SproutEngine/Shell/LoginShellRunner.swift` (created empty in Task 0 area — create now)

- [ ] **Step 1: Implement `run` (one-shot via login shell)**

`Sources/SproutEngine/Shell/LoginShellRunner.swift`:

```swift
import Foundation

public struct LoginShellRunner: ShellRunner {
    private let shellPath: String

    public init(shellPath: String? = nil) {
        self.shellPath = shellPath ?? Self.resolveLoginShell()
    }

    /// $SHELL, else the passwd entry, else /bin/zsh.
    static func resolveLoginShell() -> String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    public func run(_ command: String, cwd: URL, env: [String: String]) async throws -> ProcessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shellPath)
        proc.arguments = ["-l", "-c", command]
        proc.currentDirectoryURL = cwd
        proc.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }

        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return ProcessResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: proc.terminationStatus)
    }
```

- [ ] **Step 2: Implement `launch` via posix_spawn (new session = own process group)**

Append to the struct:

```swift
    public func launch(_ command: String, cwd: URL, env: [String: String]) throws -> ProcessHandle {
        let merged = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        return try PosixSpawnedProcess(
            shellPath: shellPath, command: command, cwd: cwd.path, env: merged)
    }
}
```

Add the spawned-process handle (same file):

```swift
/// A child launched in its own session (setsid) so signaling -pid hits the whole group.
final class PosixSpawnedProcess: ProcessHandle, @unchecked Sendable {
    let pid: Int32
    let logs: AsyncStream<LogLine>

    init(shellPath: String, command: String, cwd: String, env: [String: String]) throws {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw ShellSpawnError.pipeFailed }

        var attr = posix_spawnattr_t()
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addclose(&actions, outPipe[0])
        posix_spawn_file_actions_addclose(&actions, errPipe[0])

        // chdir via a wrapper command (posix_spawn has no cwd before 10.15 API everywhere).
        let full = "cd \(cwd.shellQuoted) && \(command)"
        let argv: [String] = [shellPath, "-l", "-c", full]
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] =
            env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }

        var childPid: pid_t = 0
        let rc = posix_spawn(&childPid, shellPath, &actions, &attr, cArgs, cEnv)
        close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw ShellSpawnError.spawnFailed(rc)
        }
        self.pid = childPid

        let oFD = outPipe[0], eFD = errPipe[0]
        self.logs = AsyncStream { cont in
            let group = DispatchGroup()
            Self.pump(fd: oFD, source: .stdout, group: group, cont: cont)
            Self.pump(fd: eFD, source: .stderr, group: group, cont: cont)
            group.notify(queue: .global()) { cont.finish() }
        }
    }

    private static func pump(fd: Int32, source: LogLine.Source,
                             group: DispatchGroup, cont: AsyncStream<LogLine>.Continuation) {
        group.enter()
        DispatchQueue.global().async {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            while case let data = handle.availableData, !data.isEmpty {
                let text = String(decoding: data, as: UTF8.self)
                for line in text.split(separator: "\n", omittingEmptySubsequences: false)
                    where !line.isEmpty {
                    cont.yield(LogLine(source: source, text: String(line)))
                }
            }
            group.leave()
        }
    }

    func terminate(graceSeconds: Double) async {
        kill(-pid, SIGTERM)
        try? await Task.sleep(nanoseconds: UInt64(graceSeconds * 1_000_000_000))
        if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
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

enum ShellSpawnError: Error { case pipeFailed, spawnFailed(Int32) }

extension String {
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds (C interop compiles).

- [ ] **Step 4: Smoke-check `run` against the real shell (not gated — uses only `echo`)**

Add `Tests/SproutEngineTests/LoginShellRunnerTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

@Test func runEchoThroughLoginShellReturnsStdout() async throws {
    let runner = LoginShellRunner()
    let r = try await runner.run("echo sprout-ok", cwd: FileManager.default.temporaryDirectory, env: [:])
    #expect(r.exitCode == 0)
    #expect(r.stdout.contains("sprout-ok"))
}

@Test func launchStreamsLogsAndExits() async throws {
    let runner = LoginShellRunner()
    let handle = try runner.launch("echo line1; echo line2",
                                   cwd: FileManager.default.temporaryDirectory, env: [:])
    var lines: [String] = []
    for await l in handle.logs { lines.append(l.text) }
    let code = await handle.waitForExit()
    #expect(code == 0)
    #expect(lines.contains("line1"))
    #expect(lines.contains("line2"))
}
```

- [ ] **Step 5: Run**

Run: `swift test --filter LoginShellRunnerTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutEngine/Shell/LoginShellRunner.swift Tests/SproutEngineTests/LoginShellRunnerTests.swift
git commit -m "feat(engine): add LoginShellRunner (login-shell PATH, posix_spawn process groups)"
```

---

## Task 13: TOMLConfigLoader

Parses a committed `.sprout.toml` into a `Config`. This is the thin "config source" layer — the engine itself stays agnostic (Config is injected). Uses TOMLKit.

**Files:**
- Create: `Sources/SproutEngine/Config/TOMLConfigLoader.swift`
- Create: `Tests/SproutEngineTests/TOMLConfigLoaderTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/SproutEngineTests/TOMLConfigLoaderTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

private let sampleTOML = """
[project]
name = "shop"

[worktree]
base_dir = "/wt"
branch_prefix = "feature/"

[port]
lower = 4000
upper = 4010

[env]
symlink_sources = [".env"]
local_file = ".env.local"

[database]
create_command = "createdb {{db_name}}"
drop_command = "dropdb --if-exists {{db_name}}"
url_template = "postgres://localhost/{{db_name}}"

[[setup]]
name = "deps"
command = "npm ci"

[[setup]]
name = "migrate"
command = "npm run migrate"

[run]
server_command = "npm run dev"

[hooks]
post_teardown = "echo bye"
"""

@Test func parsesFullConfig() throws {
    let config = try TOMLConfigLoader.parse(sampleTOML)
    #expect(config.project.name == "shop")
    #expect(config.worktree.baseDir == "/wt")
    #expect(config.port.lower == 4000)
    #expect(config.port.upper == 4010)
    #expect(config.env.symlinkSources == [".env"])
    #expect(config.env.localFile == ".env.local")
    #expect(config.database.createCommand == "createdb {{db_name}}")
    #expect(config.setup.map(\.name) == ["deps", "migrate"])
    #expect(config.run.serverCommand == "npm run dev")
    #expect(config.hooks.postTeardown == "echo bye")
    #expect(config.hooks.preTeardown == nil)
}

@Test func missingRequiredKeyThrows() {
    let bad = """
    [project]
    name = "shop"
    """
    #expect(throws: ConfigError.self) { _ = try TOMLConfigLoader.parse(bad) }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TOMLConfigLoaderTests`
Expected: FAIL — `TOMLConfigLoader`/`ConfigError` not defined.

- [ ] **Step 3: Implement**

`Sources/SproutEngine/Config/TOMLConfigLoader.swift`:

```swift
import Foundation
import TOMLKit

public enum ConfigError: Error, Equatable {
    case missingKey(String)
    case parseFailed(String)
}

public enum TOMLConfigLoader {
    public static func load(path: URL) throws -> Config {
        let text: String
        do { text = try String(contentsOf: path, encoding: .utf8) }
        catch { throw ConfigError.parseFailed("cannot read \(path.path)") }
        return try parse(text)
    }

    public static func parse(_ toml: String) throws -> Config {
        let table: TOMLTable
        do { table = try TOMLTable(string: toml) }
        catch { throw ConfigError.parseFailed("\(error)") }

        func tbl(_ key: String) throws -> TOMLTable {
            guard let t = table[key]?.table else { throw ConfigError.missingKey(key) }
            return t
        }
        func str(_ t: TOMLTable, _ key: String, _ path: String) throws -> String {
            guard let v = t[key]?.string else { throw ConfigError.missingKey(path) }
            return v
        }
        func int(_ t: TOMLTable, _ key: String, _ path: String) throws -> Int {
            guard let v = t[key]?.int else { throw ConfigError.missingKey(path) }
            return v
        }

        let projectT = try tbl("project")
        let worktreeT = try tbl("worktree")
        let portT = try tbl("port")
        let envT = try tbl("env")
        let dbT = try tbl("database")
        let runT = try tbl("run")

        let sources: [String] = (envT["symlink_sources"]?.array?.compactMap { $0.string }) ?? []

        var steps: [SetupStep] = []
        if let arr = table["setup"]?.array {
            for entry in arr {
                guard let st = entry.table,
                      let name = st["name"]?.string,
                      let cmd = st["command"]?.string else {
                    throw ConfigError.missingKey("setup[].name/command")
                }
                steps.append(SetupStep(name: name, command: cmd))
            }
        }

        let hooksT = table["hooks"]?.table
        let hooks = HooksConfig(
            preTeardown: hooksT?["pre_teardown"]?.string,
            postTeardown: hooksT?["post_teardown"]?.string)

        return Config(
            project: ProjectConfig(name: try str(projectT, "name", "project.name")),
            worktree: WorktreeConfig(
                baseDir: try str(worktreeT, "base_dir", "worktree.base_dir"),
                branchPrefix: try str(worktreeT, "branch_prefix", "worktree.branch_prefix")),
            port: PortConfig(
                lower: try int(portT, "lower", "port.lower"),
                upper: try int(portT, "upper", "port.upper")),
            env: EnvConfig(
                symlinkSources: sources,
                localFile: try str(envT, "local_file", "env.local_file")),
            database: DatabaseConfig(
                createCommand: try str(dbT, "create_command", "database.create_command"),
                dropCommand: try str(dbT, "drop_command", "database.drop_command"),
                urlTemplate: try str(dbT, "url_template", "database.url_template")),
            setup: steps,
            run: RunConfig(serverCommand: try str(runT, "server_command", "run.server_command")),
            hooks: hooks)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter TOMLConfigLoaderTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Config/TOMLConfigLoader.swift Tests/SproutEngineTests/TOMLConfigLoaderTests.swift
git commit -m "feat(engine): add TOMLConfigLoader (.sprout.toml -> Config)"
```

---

## Task 14: DoctorService (toolchain check)

`sprout doctor` needs to verify required tools exist on the resolved (login-shell) PATH. The check logic lives in the engine and is unit-testable; the CLI just prints it.

**Files:**
- Create: `Sources/SproutEngine/Workspace/DoctorService.swift`
- Create: `Tests/SproutEngineTests/DoctorServiceTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/SproutEngineTests/DoctorServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

@Test func reportsFoundToolWithPath() async {
    let shell = FakeShellRunner()
    shell.runResults = [("command -v git",
                         ProcessResult(stdout: "/usr/bin/git\n", stderr: "", exitCode: 0))]
    let doctor = DoctorService(shell: shell)
    let checks = await doctor.check(tools: ["git"], cwd: URL(fileURLWithPath: "/tmp"))
    #expect(checks == [ToolCheck(tool: "git", found: true, path: "/usr/bin/git")])
}

@Test func reportsMissingToolOnNonZeroExit() async {
    let shell = FakeShellRunner()
    shell.runResults = [("command -v createdb",
                         ProcessResult(stdout: "", stderr: "", exitCode: 1))]
    let doctor = DoctorService(shell: shell)
    let checks = await doctor.check(tools: ["createdb"], cwd: URL(fileURLWithPath: "/tmp"))
    #expect(checks == [ToolCheck(tool: "createdb", found: false, path: nil)])
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DoctorServiceTests`
Expected: FAIL — `DoctorService`/`ToolCheck` not defined.

- [ ] **Step 3: Implement**

`Sources/SproutEngine/Workspace/DoctorService.swift`:

```swift
import Foundation

public struct ToolCheck: Equatable, Sendable {
    public let tool: String
    public let found: Bool
    public let path: String?
}

public struct DoctorService: Sendable {
    let shell: ShellRunner
    public init(shell: ShellRunner) { self.shell = shell }

    public func check(tools: [String], cwd: URL) async -> [ToolCheck] {
        var out: [ToolCheck] = []
        for tool in tools {
            let r = try? await shell.run("command -v \(tool)", cwd: cwd, env: [:])
            if let r, r.succeeded {
                let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(ToolCheck(tool: tool, found: true, path: path.isEmpty ? nil : path))
            } else {
                out.append(ToolCheck(tool: tool, found: false, path: nil))
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter DoctorServiceTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Workspace/DoctorService.swift Tests/SproutEngineTests/DoctorServiceTests.swift
git commit -m "feat(engine): add DoctorService (login-shell toolchain check)"
```

---

## Task 15: sprout-cli (thin driver)

Wires real engine impls together, loads `.sprout.toml` from cwd, persists state at `~/.sprout/state.json`, exposes the subcommands. Pure glue; no new logic, so no unit tests (engine logic already covered; end-to-end covered in Task 16).

**Files:**
- Modify: `Sources/sprout-cli/main.swift`

- [ ] **Step 1: Implement the CLI**

Replace `Sources/sprout-cli/main.swift`:

```swift
import Foundation
import ArgumentParser
import SproutEngine

// MARK: - Composition root

private func stateURL() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".sprout/state.json")
}

private func loadConfig() throws -> Config {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return try TOMLConfigLoader.load(path: cwd.appendingPathComponent(".sprout.toml"))
}

private func makeManager(config: Config, store: StateStore) -> WorkspaceManager {
    let shell = LoginShellRunner()
    let renderer = TemplateRenderer()
    return WorkspaceManager(
        git: GitService(shell: shell),
        portAllocator: PortAllocator(config: config.port, store: store, prober: BindPortProber()),
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

private func repoURL() -> URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }

@Sendable private func printLog(_ line: LogLine) {
    let prefix = line.source == .stderr ? "[err] " : ""
    print(prefix + line.text)
}

// MARK: - Commands

@main
struct Sprout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sprout",
        abstract: "Sprout isolated git-worktree workspaces.",
        subcommands: [Create.self, List.self, Server.self, Push.self,
                      Done.self, Discard.self, Doctor.self])
}

struct Create: AsyncParsableCommand {
    @Option(name: .long) var base: String
    @Option(name: .long) var branch: String
    func run() async throws {
        let config = try loadConfig()
        let store = JSONStateStore(fileURL: stateURL())
        let mgr = makeManager(config: config, store: store)
        let rec = try await mgr.create(config: config, repo: repoURL(),
                                       base: base, branch: branch, onLog: printLog)
        print("created \(rec.branch)  port=\(rec.port)  db=\(rec.dbName)  pid=\(rec.serverPID ?? -1)")
    }
}

struct List: AsyncParsableCommand {
    func run() async throws {
        let store = JSONStateStore(fileURL: stateURL())
        for r in try store.load() {
            print("\(r.id)  \(r.branch)  :\(r.port)  \(r.dbName)  \(r.status.rawValue)  pid=\(r.serverPID ?? -1)")
        }
    }
}

struct Server: AsyncParsableCommand {
    @Argument var id: String
    @Argument var action: String   // "stop" | "restart"
    func run() async throws {
        let config = try loadConfig()
        let store = JSONStateStore(fileURL: stateURL())
        guard let uuid = UUID(uuidString: id),
              var rec = try store.load().first(where: { $0.id == uuid }) else {
            throw ValidationError("workspace not found: \(id)")
        }
        let shell = LoginShellRunner()
        let sup = ServerSupervisor(shell: shell, renderer: TemplateRenderer())
        let ctx = TemplateContext(project: config.project.name, branch: rec.branch,
                                  port: rec.port, dbName: rec.dbName, worktree: rec.worktreePath)
        let wt = URL(fileURLWithPath: rec.worktreePath)
        let env = ["PORT": String(rec.port),
                   "DATABASE_URL": DatabaseService(shell: shell, renderer: TemplateRenderer())
                       .databaseURL(config.database, ctx: ctx)]
        // stop the old PID if any
        if let pid = rec.serverPID { await PosixProcessTerminator().terminate(pid: pid, graceSeconds: 5) }
        if action == "restart" {
            let pid = try await sup.start(command: config.run.serverCommand, ctx: ctx,
                                          cwd: wt, env: env, onLog: printLog)
            rec.serverPID = pid; rec.status = .running
        } else {
            rec.serverPID = nil; rec.status = .stopped
        }
        try store.upsert(rec)
        print("\(action) ok")
    }
}

struct Push: AsyncParsableCommand {
    @Argument var id: String
    func run() async throws {
        let store = JSONStateStore(fileURL: stateURL())
        guard let uuid = UUID(uuidString: id),
              let rec = try store.load().first(where: { $0.id == uuid }) else {
            throw ValidationError("workspace not found: \(id)")
        }
        try await GitService(shell: LoginShellRunner())
            .push(worktree: URL(fileURLWithPath: rec.worktreePath), branch: rec.branch)
        print("pushed \(rec.branch)")
    }
}

struct Done: AsyncParsableCommand {
    @Argument var id: String
    @Flag(name: .long) var force = false
    func run() async throws {
        try await teardown(id: id, push: true, force: force)
    }
}

struct Discard: AsyncParsableCommand {
    @Argument var id: String
    func run() async throws { try await teardown(id: id, push: false, force: true) }
}

private func teardown(id: String, push: Bool, force: Bool) async throws {
    guard let uuid = UUID(uuidString: id) else { throw ValidationError("bad id: \(id)") }
    let config = try loadConfig()
    let store = JSONStateStore(fileURL: stateURL())
    let mgr = makeManager(config: config, store: store)
    try await mgr.teardown(id: uuid, config: config, repo: repoURL(), push: push, force: force)
    print("torn down \(id)")
}

struct Doctor: AsyncParsableCommand {
    func run() async throws {
        let shell = LoginShellRunner()
        let checks = await DoctorService(shell: shell)
            .check(tools: ["git", "createdb", "dropdb", "node"], cwd: repoURL())
        for c in checks {
            print("\(c.found ? "ok " : "MISSING") \(c.tool)\(c.path.map { "  \($0)" } ?? "")")
        }
        // reconcile if a config + state exist
        if let config = try? loadConfig() {
            let store = JSONStateStore(fileURL: stateURL())
            let reconciled = try makeManager(config: config, store: store).reconcile()
            for r in reconciled {
                let flag = r.orphaned ? " (orphaned worktree)" : ""
                print("  \(r.record.branch)  \(r.record.status.rawValue)\(flag)")
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds the `sprout` executable.

- [ ] **Step 3: Smoke-run the help**

Run: `swift run sprout --help`
Expected: usage text listing subcommands (create/list/server/push/done/discard/doctor).

- [ ] **Step 4: Commit**

```bash
git add Sources/sprout-cli/main.swift
git commit -m "feat(cli): add thin sprout CLI driving the engine"
```

---

## Task 16: Gated integration tests

A few high-value end-to-end checks against real tools, skipped unless `SPROUT_INTEGRATION=1`. These verify the real `LoginShellRunner` + `GitService` against an actual git repo, and real process-group termination. Postgres tests are further gated on `createdb` being present.

**Files:**
- Create: `Tests/SproutEngineTests/IntegrationTests.swift`

- [ ] **Step 1: Write the gated tests**

`Tests/SproutEngineTests/IntegrationTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

private var integrationEnabled: Bool {
    ProcessInfo.processInfo.environment["SPROUT_INTEGRATION"] == "1"
}

private func sh(_ cmd: String, cwd: URL) async throws {
    let r = try await LoginShellRunner().run(cmd, cwd: cwd, env: [:])
    #expect(r.exitCode == 0, "command failed: \(cmd)\n\(r.stderr)")
}

@Test(.enabled(if: integrationEnabled))
func realGitWorktreeAddAndRemove() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("sprout-it-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let repo = tmp.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try await sh("git init -q && git commit -q --allow-empty -m init", cwd: repo)

    let git = GitService(shell: LoginShellRunner())
    let wtPath = tmp.appendingPathComponent("wt-login").path
    try await git.worktreeAdd(repo: repo, path: wtPath, base: "HEAD", branch: "feature/login")
    #expect(FileManager.default.fileExists(atPath: wtPath))

    try await git.worktreeRemove(repo: repo, path: wtPath)
    #expect(!FileManager.default.fileExists(atPath: wtPath))
}

@Test(.enabled(if: integrationEnabled))
func realProcessGroupTerminationKillsChildren() async throws {
    // Launch a shell that spawns a long-lived child; terminate must kill the group.
    let runner = LoginShellRunner()
    let handle = try runner.launch("sleep 600", cwd: FileManager.default.temporaryDirectory, env: [:])
    let pid = handle.pid
    #expect(kill(pid, 0) == 0)          // alive
    await handle.terminate(graceSeconds: 1)
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(kill(pid, 0) != 0)          // dead
}
```

- [ ] **Step 2: Verify they SKIP by default**

Run: `swift test --filter IntegrationTests`
Expected: tests skipped (no failures) because `SPROUT_INTEGRATION` is unset.

- [ ] **Step 3: Verify they PASS when enabled**

Run: `SPROUT_INTEGRATION=1 swift test --filter IntegrationTests`
Expected: PASS (real git worktree add/remove; real process-group kill).

- [ ] **Step 4: Commit**

```bash
git add Tests/SproutEngineTests/IntegrationTests.swift
git commit -m "test(engine): add gated integration tests (real git + process-group kill)"
```

---

## Task 17: Full suite + sample config

Final pass: confirm everything builds and the full unit suite is green, and commit a sample `.sprout.toml` for manual CLI driving.

**Files:**
- Create: `.sprout.toml` (repo root, example)

- [ ] **Step 1: Run the full unit suite**

Run: `swift test`
Expected: all unit tests PASS; integration tests skipped.

- [ ] **Step 2: Add a sample config**

`.sprout.toml`:

```toml
[project]
name = "shop"

[worktree]
base_dir = "../sprout-worktrees"
branch_prefix = "feature/"

[port]
lower = 4000
upper = 4050

[env]
symlink_sources = [".env"]
local_file = ".env.local"

[database]
create_command = "createdb {{db_name}}"
drop_command = "dropdb --if-exists {{db_name}}"
url_template = "postgres://localhost/{{db_name}}"

[[setup]]
name = "deps"
command = "npm ci"

[[setup]]
name = "migrate"
command = "npm run migrate"

[run]
server_command = "npm run dev"
```

- [ ] **Step 3: Commit**

```bash
git add .sprout.toml
git commit -m "docs: add sample .sprout.toml for manual CLI use"
```

---

## Self-Review (completed by plan author)

- **Spec coverage:** ShellRunner/login-shell (T1, T12) → spec §3.1; not-sandboxed real subprocesses (T12) → §3.2; supervision + SIGTERM→SIGKILL process groups (T10, T12, `PosixProcessTerminator`) → §4; reconcile (T11c) → §4 crash resilience; injected Config + TOML loader (T3, T13) → §6.1; per-worktree DB + port isolation (T5, T7, T11) → §6.3; env injection `.env.local` + symlink (T8, T11) → §6.4; teardown safety push/dirty-abort + ordering (T11b) → §6.5; StateStore persistence (T4) → §7 (SwiftData deferred); error cases (T11 rollback, T11b guards, T14 doctor) → §9; testing protocol-seam + gated integration (all tasks, T16) → §10.
- **Placeholder scan:** none — every code step is complete.
- **Type consistency:** `WorkspaceManager.init` includes `fs` and `terminator` from T11; `makeManager` matches; `ProcessHandle.logs` is `AsyncStream<LogLine>` everywhere; `reconcile` returns `[ReconciledWorkspace]`; CLI uses `config.port` (`PortConfig`) matching `PortAllocator.init`.
- **Scope:** single phase (headless engine + CLI); GUI/SwiftData/MySQL/SQLite/signing explicitly out of scope per design doc.

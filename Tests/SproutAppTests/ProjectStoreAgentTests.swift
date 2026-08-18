import Foundation
import SproutEngine
import Testing

@testable import SproutApp

private var integrationEnabled: Bool {
    ProcessInfo.processInfo.environment["SPROUT_INTEGRATION"] == "1"
}

/// Replays scripted hook deliveries so we can assert ProjectStore routing without
/// a real Claude Code session on the other end.
final class FakeHookReceiver: AgentHookReceiving, @unchecked Sendable {
    let deliveries: AsyncStream<HookDelivery>
    private let cont: AsyncStream<HookDelivery>.Continuation

    init() {
        var c: AsyncStream<HookDelivery>.Continuation!
        deliveries = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        cont = c
    }

    func start() async throws -> UInt16 { 12345 }
    func stop() { cont.finish() }
    func emit(_ delivery: HookDelivery) { cont.yield(delivery) }
}

@Suite struct ProjectStoreAgentTests {
    // Spawns a real PTY process for the agent, so it's gated like other
    // side-effecting tests. The hook side is faked.
    @Test(.enabled(if: integrationEnabled)) @MainActor
    func routesHookDeliveriesToMatchingAgent() async throws {
        let wt = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprout-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: wt) }

        let fake = FakeHookReceiver()
        let store = makeAgentStore(worktree: wt, receiver: fake, command: "sleep 600")
        let item = WorkspaceItem(
            record: makeAgentRecord(branch: "feature/x", worktree: wt.path), orphaned: false)

        await store.startAgent(item, name: "builder")
        #expect(store.agents.count == 1)
        let token = try #require(store.agents.first?.token)

        fake.emit(
            HookDelivery(
                token: token,
                event: AgentEvent(sessionID: "sess", kind: "PreToolUse", tool: "Edit")))
        try await waitUntil { store.agents.first?.state == .runningTool }
        #expect(store.agents.first?.currentTool == "Edit")
        #expect(store.agents.first?.sessionID == "sess")

        fake.emit(HookDelivery(token: token, event: AgentEvent(sessionID: "sess", kind: "Stop")))
        try await waitUntil { store.agents.first?.state == .done }

        await store.stopAgent(id: try #require(store.agents.first?.id))
    }
}

@MainActor
private func makeAgentStore(
    worktree: URL, receiver: AgentHookReceiving, command: String
) -> ProjectStore {
    let config = Config(
        project: ProjectConfig(name: "My Shop"),
        worktree: WorktreeConfig(baseDir: "../wt", branchPrefix: "feature/"),
        env: EnvConfig(symlinkSources: [], localFile: ".env.local"),
        database: DatabaseConfig(
            createCommand: "true", dropCommand: "true", urlTemplate: "unused"),
        setup: [],
        run: RunConfig(processes: []),
        hooks: HooksConfig(),
        agents: [AgentConfig(name: "builder", command: command)])
    return ProjectStore(
        rootURL: worktree.deletingLastPathComponent(), config: config,
        hookReceiver: receiver)
}

private func makeAgentRecord(branch: String, worktree: String) -> WorkspaceRecord {
    WorkspaceRecord(
        id: UUID(), branch: branch, base: "main",
        worktreePath: worktree, port: 3000, dbName: "db",
        status: .stopped, createdAt: Date(), processes: [], bindIP: "127.0.0.1")
}

/// Poll `condition` until true or a timeout elapses, letting the store's async
/// hook consumer run in between.
@MainActor
private func waitUntil(
    _ condition: @escaping () -> Bool, timeout: Duration = .seconds(2)
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), "condition not met within timeout")
}

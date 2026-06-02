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

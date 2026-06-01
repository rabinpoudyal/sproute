import Testing
import Foundation
@testable import SproutEngine

private let cwd = URL(fileURLWithPath: "/wt/login")
private func ctx() -> TemplateContext {
    TemplateContext(
        project: "shop", branch: "login", port: 4001,
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

@Test func crashingProcessReportsExitToCallback() async throws {
    let shell = FakeShellRunner()
    shell.handles = [("npm run dev", { FakeProcessHandle(pid: 909, exitCode: 1, lines: []) })]
    let sup = ServerSupervisor(shell: shell, renderer: TemplateRenderer())
    // start returns once the process is launched; the exit is reported asynchronously, so
    // await the callback before asserting.
    let reported = await withCheckedContinuation {
        (c: CheckedContinuation<(Int32, Int32), Never>) in
        Task {
            _ = try? await sup.start(
                command: "npm run dev", ctx: ctx(), cwd: cwd, env: [:],
                onLog: { _ in }, onExit: { pid, code in c.resume(returning: (pid, code)) })
        }
    }
    #expect(reported == (909, 1))
    #expect(await sup.status == .crashed)
}

@Test func rendersServerCommandTemplate() async throws {
    let shell = FakeShellRunner()
    let sup = ServerSupervisor(shell: shell, renderer: TemplateRenderer())
    _ = try await sup.start(command: "serve --port {{port}}", ctx: ctx(), cwd: cwd, env: [:]) { _ in
    }
    #expect(shell.calls.last?.command == "serve --port 4001")
}

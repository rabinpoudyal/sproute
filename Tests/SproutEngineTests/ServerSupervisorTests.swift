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

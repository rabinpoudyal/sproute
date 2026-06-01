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
    let captured = LogCollector()
    try await runner.run([SetupStep(name: "deps", command: "npm ci")],
                         ctx: ctx(), cwd: cwd, env: [:]) { captured.append($0.text) }
    #expect(captured.texts == ["installing"])
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

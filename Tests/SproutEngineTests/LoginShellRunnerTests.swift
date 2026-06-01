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

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

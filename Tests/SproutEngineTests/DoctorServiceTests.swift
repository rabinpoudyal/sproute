import Testing
import Foundation
@testable import SproutEngine

@Test func reportsFoundToolWithPath() async {
    let shell = FakeShellRunner()
    shell.runResults = [
        (
            "command -v git",
            ProcessResult(stdout: "/usr/bin/git\n", stderr: "", exitCode: 0)
        )
    ]
    let doctor = DoctorService(shell: shell)
    let checks = await doctor.check(tools: ["git"], cwd: URL(fileURLWithPath: "/tmp"))
    #expect(checks == [ToolCheck(tool: "git", found: true, path: "/usr/bin/git")])
}

@Test func reportsMissingToolOnNonZeroExit() async {
    let shell = FakeShellRunner()
    shell.runResults = [
        (
            "command -v createdb",
            ProcessResult(stdout: "", stderr: "", exitCode: 1)
        )
    ]
    let doctor = DoctorService(shell: shell)
    let checks = await doctor.check(tools: ["createdb"], cwd: URL(fileURLWithPath: "/tmp"))
    #expect(checks == [ToolCheck(tool: "createdb", found: false, path: nil)])
}

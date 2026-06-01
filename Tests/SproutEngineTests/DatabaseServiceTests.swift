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

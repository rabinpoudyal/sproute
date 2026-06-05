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
    #expect(
        r.render("port={{port}} db={{db_name}}", ctx)
            == "port=4011 db=shop_feature_add_login")
    #expect(r.render("{{worktree}}/.env", ctx) == "/wt/shop-login/.env")
    #expect(r.render("branch={{branch}}", ctx) == "branch=feature/Add-Login")
}

@Test func renderResolvesOwnAndSiblingPorts() {
    let ctx = TemplateContext(
        project: "shop", branch: "main", port: 4000,
        dbName: "shop", worktree: "/wt", ports: ["web": 4000, "vite": 4001])
    let r = TemplateRenderer()
    #expect(r.render("-p {{port}}", ctx) == "-p 4000")
    #expect(r.render("VITE={{port.vite}} WEB={{port.web}}", ctx) == "VITE=4001 WEB=4000")
}

@Test func renderResolvesHostWithDefaultLoopback() {
    let ctx = TemplateContext(
        project: "shop", branch: "main", port: 4000,
        dbName: "shop", worktree: "/wt")
    #expect(ctx.host == "127.0.0.1")
    #expect(TemplateRenderer().render("-b {{host}} -p {{port}}", ctx) == "-b 127.0.0.1 -p 4000")
}

@Test func renderUsesExplicitHost() {
    let ctx = TemplateContext(
        project: "shop", branch: "main", port: 3000,
        dbName: "shop", worktree: "/wt", ports: ["web": 3000], host: "127.0.10.7")

    #expect(
        TemplateRenderer().render("rails -b {{host}} -p {{port}}", ctx)
            == "rails -b 127.0.10.7 -p 3000")
}

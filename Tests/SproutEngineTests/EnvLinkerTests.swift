import Testing
import Foundation
@testable import SproutEngine

private let repo = URL(fileURLWithPath: "/repo")
private let wt = URL(fileURLWithPath: "/wt/login")

@Test func linkCreatesSymlinkPerSource() throws {
    let fs = FakeFileSystem()
    fs.existing = ["/repo/.env"]
    let linker = EnvLinker(fs: fs)
    try linker.link(sources: [".env"], primaryRepo: repo, worktree: wt)
    #expect(fs.symlinks == [.init(from: "/repo/.env", to: "/wt/login/.env")])
}

@Test func linkSkipsMissingSource() throws {
    let fs = FakeFileSystem()
    fs.existing = []
    let linker = EnvLinker(fs: fs)
    try linker.link(sources: [".env"], primaryRepo: repo, worktree: wt)
    #expect(fs.symlinks.isEmpty)
}

@Test func writeLocalWritesPortAndDatabaseURL() throws {
    let fs = FakeFileSystem()
    let linker = EnvLinker(fs: fs)
    try linker.writeLocal(
        file: ".env.local", worktree: wt,
        port: 4001, databaseURL: "postgres://localhost/shop_x")
    #expect(fs.writes.count == 1)
    #expect(fs.writes.first?.path == "/wt/login/.env.local")
    #expect(fs.writes.first?.contents == "PORT=4001\nDATABASE_URL=postgres://localhost/shop_x\n")
}

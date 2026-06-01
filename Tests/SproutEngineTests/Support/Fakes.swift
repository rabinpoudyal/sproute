import Foundation
@testable import SproutEngine

final class FakeStateStore: StateStore, @unchecked Sendable {
    var records: [WorkspaceRecord] = []
    func load() throws -> [WorkspaceRecord] { records }
    func upsert(_ record: WorkspaceRecord) throws {
        if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = record }
        else { records.append(record) }
    }
    func remove(id: UUID) throws { records.removeAll { $0.id == id } }
}

final class FakeFileSystem: FileSystem, @unchecked Sendable {
    struct Symlink: Equatable { let from: String; let to: String }
    struct WriteOp: Equatable { let contents: String; let path: String }

    var existing: Set<String> = []
    private(set) var symlinks: [Symlink] = []
    private(set) var writes: [WriteOp] = []
    private(set) var removed: [String] = []

    func symlink(from: URL, to: URL) throws {
        symlinks.append(.init(from: from.path, to: to.path))
    }
    func write(_ contents: String, to url: URL) throws {
        writes.append(.init(contents: contents, path: url.path))
    }
    func fileExists(_ url: URL) -> Bool { existing.contains(url.path) }
    func removeItem(_ url: URL) throws { removed.append(url.path) }
}

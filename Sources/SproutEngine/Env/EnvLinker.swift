import Foundation

public protocol FileSystem: Sendable {
    func symlink(from: URL, to: URL) throws
    func write(_ contents: String, to url: URL) throws
    func fileExists(_ url: URL) -> Bool
    func removeItem(_ url: URL) throws
}

/// Real impl backed by FileManager.
public struct RealFileSystem: FileSystem {
    public init() {}
    public func symlink(from: URL, to: URL) throws {
        if FileManager.default.fileExists(atPath: to.path) {
            try FileManager.default.removeItem(at: to)
        }
        try FileManager.default.createSymbolicLink(at: to, withDestinationURL: from)
    }
    public func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    public func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
    public func removeItem(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

public struct EnvLinker: Sendable {
    let fs: FileSystem
    public init(fs: FileSystem) { self.fs = fs }

    /// Symlink each existing source file from the primary repo into the worktree.
    public func link(sources: [String], primaryRepo: URL, worktree: URL) throws {
        for name in sources {
            let src = primaryRepo.appendingPathComponent(name)
            guard fs.fileExists(src) else { continue }
            let dst = worktree.appendingPathComponent(name)
            try fs.symlink(from: src, to: dst)
        }
    }

    /// Write per-workspace overrides (PORT, DATABASE_URL) to the local env file.
    public func writeLocal(file: String, worktree: URL, port: Int, databaseURL: String) throws {
        let contents = "PORT=\(port)\nDATABASE_URL=\(databaseURL)\n"
        try fs.write(contents, to: worktree.appendingPathComponent(file))
    }
}

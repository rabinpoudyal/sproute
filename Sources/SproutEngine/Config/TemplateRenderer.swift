import Foundation

public struct TemplateContext: Sendable {
    public var project: String
    public var branch: String
    public var port: Int
    public var dbName: String
    public var worktree: String
    public var ports: [String: Int]
    public var host: String

    public init(
        project: String, branch: String, port: Int, dbName: String,
        worktree: String, ports: [String: Int] = [:], host: String = "127.0.0.1"
    ) {
        self.project = project; self.branch = branch; self.port = port
        self.dbName = dbName; self.worktree = worktree; self.ports = ports
        self.host = host
    }

    public var branchSlug: String { Self.slugify(branch) }

    /// Lowercase, collapse runs of non-alphanumeric chars to a single `_`, trim leading/trailing `_`.
    public static func slugify(_ s: String) -> String {
        var out = ""
        var lastUnderscore = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastUnderscore = false
            } else if !lastUnderscore {
                out.append("_"); lastUnderscore = true
            }
        }
        while out.hasPrefix("_") { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        return out
    }
}

public struct TemplateRenderer: Sendable {
    public init() {}

    public func render(_ template: String, _ ctx: TemplateContext) -> String {
        var out = template
        let map: [String: String] = [
            "{{project}}": ctx.project,
            "{{branch}}": ctx.branch,
            "{{branch_slug}}": ctx.branchSlug,
            "{{port}}": String(ctx.port),
            "{{host}}": ctx.host,
            "{{db_name}}": ctx.dbName,
            "{{worktree}}": ctx.worktree,
        ]
        for (name, p) in ctx.ports {
            out = out.replacingOccurrences(of: "{{port.\(name)}}", with: String(p))
        }
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}

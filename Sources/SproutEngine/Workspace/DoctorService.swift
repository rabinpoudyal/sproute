import Foundation

public struct ToolCheck: Equatable, Sendable {
    public let tool: String
    public let found: Bool
    public let path: String?
}

public struct DoctorService: Sendable {
    let shell: ShellRunner
    public init(shell: ShellRunner) { self.shell = shell }

    public func check(tools: [String], cwd: URL) async -> [ToolCheck] {
        var out: [ToolCheck] = []
        for tool in tools {
            let r = try? await shell.run("command -v \(tool)", cwd: cwd, env: [:])
            if let r, r.succeeded {
                let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(ToolCheck(tool: tool, found: true, path: path.isEmpty ? nil : path))
            } else {
                out.append(ToolCheck(tool: tool, found: false, path: nil))
            }
        }
        return out
    }
}

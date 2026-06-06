import Foundation

/// Filesystem locations the app uses under `~/.sprout`.
enum SproutPaths {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sprout")
    }

    static var registryFile: URL {
        root.appendingPathComponent("projects.json")
    }

    /// Global loopback IP allocation table (127.0.10.N per project/branch).
    static var loopbackFile: URL {
        root.appendingPathComponent("loopback.json")
    }

    /// Per-project state file, scoped by a slug of the project name, so multiple
    /// projects do not share one state.json.
    static func stateFile(projectName: String) -> URL {
        let slug = slugify(projectName)
        return root.appendingPathComponent("state").appendingPathComponent("\(slug).json")
    }

    static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "project" : collapsed
    }
}

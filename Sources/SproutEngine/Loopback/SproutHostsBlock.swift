import Foundation

/// Pure editor for the single delimited block this tool manages inside an
/// `/etc/hosts`-shaped string. It never reads or writes the filesystem — the
/// privileged helper (Plan 2b) owns the atomic write. All user/foreign lines
/// outside the block are preserved verbatim across edits.
public enum SproutHostsBlock {
    public static let begin = "# BEGIN SPROUT (managed - do not edit)"
    public static let end = "# END SPROUT"

    /// One managed mapping: a loopback IP and the hostnames that resolve to it.
    struct Entry: Equatable {
        var ip: String
        var hosts: [String]
    }

    /// Split contents into the text before the block, the parsed entries, and
    /// the text after the block. When no well-formed block exists, everything is
    /// `head` and there are no entries (so a later render appends a fresh block).
    static func parse(_ contents: String) -> (head: String, entries: [Entry], tail: String) {
        let lines = contents.components(separatedBy: "\n")
        guard let b = lines.firstIndex(of: begin),
            let e = lines.firstIndex(of: end), e > b
        else {
            return (contents, [], "")
        }
        let head = lines[..<b].joined(separator: "\n")
        let tail = lines[(e + 1)...].joined(separator: "\n")
        var entries: [Entry] = []
        for line in lines[(b + 1)..<e] {
            let parts = line.split(separator: " ").map(String.init)
            guard let ip = parts.first else { continue }
            entries.append(Entry(ip: ip, hosts: Array(parts.dropFirst())))
        }
        return (head, entries, tail)
    }

    /// Reassemble contents. The block is emitted only when there are entries, so
    /// removing the last entry drops the markers entirely. Empty head/tail are
    /// skipped so we don't accumulate blank lines.
    static func render(head: String, entries: [Entry], tail: String) -> String {
        var sections: [String] = []
        if !head.isEmpty { sections.append(head) }
        if !entries.isEmpty {
            let block =
                [begin]
                + entries.map { "\($0.ip) \($0.hosts.joined(separator: " "))" }
                + [end]
            sections.append(block.joined(separator: "\n"))
        }
        if !tail.isEmpty { sections.append(tail) }
        return sections.joined(separator: "\n")
    }

    /// The loopback IPs currently present in the managed block, in file order.
    /// `[]` when there is no block. Used by the Plan 2b launch sweep.
    public static func managedIPs(contents: String) -> [String] {
        parse(contents).entries.map { $0.ip }
    }

    /// Remove the managed line for `ip` (no-op if absent). Drops the whole block
    /// when it becomes empty.
    public static func remove(contents: String, ip: String) -> String {
        let parsed = parse(contents)
        var entries = parsed.entries
        entries.removeAll { $0.ip == ip }
        return render(head: parsed.head, entries: entries, tail: parsed.tail)
    }

    /// Insert or replace the managed line for `ip`. An empty `hosts` array is
    /// treated as a removal (so a caller clearing a workspace can pass `[]`).
    /// Idempotent: re-upserting the same ip+hosts yields identical contents.
    public static func upsert(contents: String, ip: String, hosts: [String]) -> String {
        if hosts.isEmpty { return remove(contents: contents, ip: ip) }
        let parsed = parse(contents)
        var entries = parsed.entries
        if let i = entries.firstIndex(where: { $0.ip == ip }) {
            entries[i].hosts = hosts
        } else {
            entries.append(Entry(ip: ip, hosts: hosts))
        }
        return render(head: parsed.head, entries: entries, tail: parsed.tail)
    }
}

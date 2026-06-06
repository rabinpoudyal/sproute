import Foundation

/// Whitelist validators the privileged helper (Plan 2b) runs on every request
/// before touching `lo0` or `/etc/hosts`. Kept here, in the headless engine, so
/// they are unit-tested without root. Manual parsing (no regex) keeps the rules
/// explicit and platform-independent.

/// True iff `ip` is exactly `127.0.10.N` with `N` in `1...254`, in canonical
/// decimal form. Rejects the network (.0) and broadcast (.255) addresses, any
/// other prefix, leading zeros, and trailing characters.
public func isValidLoopbackIP(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4,
        parts[0] == "127", parts[1] == "0", parts[2] == "10"
    else { return false }
    guard let n = Int(parts[3]), String(n) == parts[3], (1...254).contains(n) else {
        return false
    }
    return true
}

/// True iff `host` is exactly `<label>.<label>.localhost`, where each of the two
/// leading labels is non-empty and composed only of lowercase letters, digits,
/// and hyphens. Mirrors `^[a-z0-9-]+\.[a-z0-9-]+\.localhost$`. Rejects anything
/// that could hijack a real domain in `/etc/hosts`.
public func isValidLoopbackHostname(_ host: String) -> Bool {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count == 3, labels[2] == "localhost" else { return false }
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    for label in labels.prefix(2) {
        guard !label.isEmpty, label.allSatisfy({ allowed.contains($0) }) else {
            return false
        }
    }
    return true
}

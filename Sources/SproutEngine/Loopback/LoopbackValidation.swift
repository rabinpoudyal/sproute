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

import Foundation

/// Pure diff for the crash-recovery sweep: any IP the helper still manages in
/// `/etc/hosts` that no longer has a live allocation is stale and should be
/// torn down (`-alias` + hosts removal). Preserves input order and de-dupes so
/// the caller can drive one teardown per unique stale IP.
public func staleManagedIPs(managed: [String], live: Set<String>) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for ip in managed where !live.contains(ip) && !seen.contains(ip) {
        seen.insert(ip)
        result.append(ip)
    }
    return result
}

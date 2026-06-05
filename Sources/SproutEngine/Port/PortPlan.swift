import Foundation

/// Maps each port-binding process to its fixed listen port. Processes with a
/// nil `port` are omitted. Used to render `{{port.<name>}}` and to display the
/// per-process port assignment.
public func portPlan(_ processes: [ProcessConfig]) -> [String: Int] {
    var plan: [String: Int] = [:]
    for p in processes { if let port = p.port { plan[p.name] = port } }
    return plan
}

/// The workspace's primary port: the first process that declares one, else 0.
/// Stored on `WorkspaceRecord.port` and used for the browser-open action and the
/// single `PORT` written into `.env.local`.
public func primaryPort(_ processes: [ProcessConfig]) -> Int {
    processes.first(where: { $0.port != nil })?.port ?? 0
}

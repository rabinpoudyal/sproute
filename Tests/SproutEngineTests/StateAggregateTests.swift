import Testing
import Foundation
@testable import SproutEngine

@Test func aggregateEmptyIsStopped() {
    #expect(aggregateStatus([]) == .stopped)
}

@Test func aggregateAllRunningIsRunning() {
    let ps = [
        ProcessState(name: "server", pid: 1, status: .running),
        ProcessState(name: "assets", pid: 2, status: .running),
    ]
    #expect(aggregateStatus(ps) == .running)
}

@Test func aggregateAnyCrashedIsCrashed() {
    let ps = [
        ProcessState(name: "server", pid: 1, status: .running),
        ProcessState(name: "assets", pid: nil, status: .crashed),
    ]
    #expect(aggregateStatus(ps) == .crashed)
}

@Test func aggregateMixedRunningStoppedIsStopped() {
    let ps = [
        ProcessState(name: "server", pid: 1, status: .running),
        ProcessState(name: "assets", pid: nil, status: .stopped),
    ]
    #expect(aggregateStatus(ps) == .stopped)
}

@Test func recordDecodesWithoutProcessesKey() throws {
    // Existing on-disk state has a legacy key and no processes key; both are tolerated.
    let json = """
        {"id":"00000000-0000-0000-0000-000000000000","branch":"b","base":"main",
         "worktreePath":"/wt/b","port":4000,"dbName":"d","status":"stopped",
         "serverPid":123,"createdAt":"1970-01-01T00:00:00Z"}
        """
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let rec = try dec.decode(WorkspaceRecord.self, from: Data(json.utf8))
    #expect(rec.processes.isEmpty)
    #expect(rec.branch == "b")
}

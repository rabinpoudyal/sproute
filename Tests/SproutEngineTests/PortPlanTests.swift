import Testing
import Foundation
@testable import SproutEngine

@Test func portPlanMapsOnlyBinders() {
    let procs = [
        ProcessConfig(name: "web", command: "a", port: 4000),
        ProcessConfig(name: "vite", command: "b", port: 4001),
        ProcessConfig(name: "worker", command: "c"),
    ]
    #expect(portPlan(procs) == ["web": 4000, "vite": 4001])
}

@Test func primaryPortIsFirstBinder() {
    let procs = [
        ProcessConfig(name: "worker", command: "c"),
        ProcessConfig(name: "web", command: "a", port: 4000),
        ProcessConfig(name: "vite", command: "b", port: 4001),
    ]
    #expect(primaryPort(procs) == 4000)
}

@Test func primaryPortZeroWhenNoBinders() {
    let procs = [ProcessConfig(name: "worker", command: "c")]
    #expect(primaryPort(procs) == 0)
    #expect(portPlan(procs).isEmpty)
}

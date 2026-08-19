import SproutEngine
import Testing

@testable import SproutApp

@Suite struct AgentRoomTests {
    @Test func mapsEveryStateToARoom() {
        #expect(AgentRoom.of(.thinking) == .desks)
        #expect(AgentRoom.of(.runningTool) == .desks)
        #expect(AgentRoom.of(.waitingApproval) == .waiting)
        #expect(AgentRoom.of(.error) == .waiting)
        #expect(AgentRoom.of(.idle) == .lounge)
        #expect(AgentRoom.of(.done) == .done)
        #expect(AgentRoom.of(.ended) == .offline)
    }
}

import Foundation
import Testing

@testable import SproutEngine

private var integrationEnabled: Bool {
    ProcessInfo.processInfo.environment["SPROUT_INTEGRATION"] == "1"
}

@Suite struct AgentHookReceiverTests {
    // Binds a real loopback socket, so it's gated with the other integration tests.
    @Test(.enabled(if: integrationEnabled))
    func roundTripsAPostedHook() async throws {
        let receiver = AgentHookReceiver()
        let port = try await receiver.start()
        defer { receiver.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook/tok")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"hook_event_name":"Stop","session_id":"s1"}"#.utf8)
        _ = try await URLSession.shared.data(for: request)

        var iterator = receiver.deliveries.makeAsyncIterator()
        let delivery = await iterator.next()
        #expect(delivery?.token == "tok")
        #expect(delivery?.event.kind == "Stop")
        #expect(delivery?.event.sessionID == "s1")
    }
}

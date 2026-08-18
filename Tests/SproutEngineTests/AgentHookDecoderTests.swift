import Foundation
import Testing

@testable import SproutEngine

@Suite struct AgentHookDecoderTests {
    @Test func decodesSessionKindAndTool() {
        let json = #"{"hook_event_name":"PreToolUse","session_id":"abc","tool_name":"Edit"}"#
        let e = AgentHookDecoder.decode(Data(json.utf8))
        #expect(e?.sessionID == "abc")
        #expect(e?.kind == "PreToolUse")
        #expect(e?.tool == "Edit")
    }

    @Test func decodesMessageFromLastAssistantMessage() {
        let json = #"{"hook_event_name":"Stop","session_id":"s","last_assistant_message":"done"}"#
        #expect(AgentHookDecoder.decode(Data(json.utf8))?.message == "done")
    }

    @Test func rejectsPayloadsMissingRequiredFields() {
        #expect(AgentHookDecoder.decode(Data(#"{"hook_event_name":"Stop"}"#.utf8)) == nil)
        #expect(AgentHookDecoder.decode(Data(#"{"session_id":"s"}"#.utf8)) == nil)
        #expect(AgentHookDecoder.decode(Data("not json".utf8)) == nil)
    }

    @Test func httpBodyHonorsContentLength() {
        let body = #"{"x":1}"#
        let raw =
            "POST /hook/tok HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)TRAILING"
        #expect(AgentHookDecoder.httpBody(Data(raw.utf8)) == Data(body.utf8))
    }

    @Test func httpBodyNilWithoutHeaderSeparator() {
        #expect(AgentHookDecoder.httpBody(Data("POST /hook/x HTTP/1.1\r\n".utf8)) == nil)
    }

    @Test func requestPathTokenParsesHookPath() {
        let raw = "POST /hook/abc123 HTTP/1.1\r\nHost: x\r\n\r\n"
        #expect(AgentHookDecoder.requestPathToken(Data(raw.utf8)) == "abc123")
        #expect(AgentHookDecoder.requestPathToken(Data("GET /other HTTP/1.1\r\n\r\n".utf8)) == nil)
    }
}

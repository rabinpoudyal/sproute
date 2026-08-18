import Foundation

/// Decodes the raw bytes a Claude Code hook POSTs to us. Two layers, split so the
/// HTTP framing can be unit-tested without opening a socket:
///   - `httpBody` extracts the body from a raw HTTP/1.1 request.
///   - `decode` turns a JSON hook payload into an `AgentEvent`.
public enum AgentHookDecoder {
    /// Extract the request body from a raw HTTP/1.1 request. Splits on the blank
    /// line after the headers and, when a `Content-Length` is present, returns
    /// exactly that many bytes. Returns nil if the header/body separator is absent.
    public static func httpBody(_ data: Data) -> Data? {
        let sep = Data([0x0d, 0x0a, 0x0d, 0x0a])  // CRLF CRLF
        guard let range = data.range(of: sep) else { return nil }
        let header = String(decoding: data[data.startIndex..<range.lowerBound], as: UTF8.self)
        var body = data[range.upperBound...]
        if let length = contentLength(header) {
            let end = body.index(
                body.startIndex, offsetBy: min(length, body.count))
            body = body[body.startIndex..<end]
        }
        return Data(body)
    }

    /// The `<token>` from an HTTP request line whose path is `/hook/<token>`.
    /// Returns nil for any other path or a malformed request line.
    public static func requestPathToken(_ data: Data) -> String? {
        let crlf = Data([0x0d, 0x0a])
        guard let end = data.range(of: crlf) else { return nil }
        let line = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let comps = parts[1].split(separator: "/")
        guard comps.count >= 2, comps[0] == "hook" else { return nil }
        return String(comps[1])
    }

    private static func contentLength(_ header: String) -> Int? {
        for line in header.split(separator: "\r\n")
        where line.lowercased().hasPrefix("content-length:") {
            let value = line.split(separator: ":", maxSplits: 1)[1]
            return Int(value.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Decode a hook JSON payload. Requires `hook_event_name` and `session_id`;
    /// every other field is optional so partial/newer payloads still decode.
    public static func decode(_ data: Data) -> AgentEvent? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = obj["hook_event_name"] as? String,
            let session = obj["session_id"] as? String
        else { return nil }
        return AgentEvent(
            sessionID: session,
            kind: kind,
            tool: obj["tool_name"] as? String,
            message: (obj["message"] as? String) ?? (obj["last_assistant_message"] as? String))
    }
}

import Foundation
import Network

/// One decoded hook, tagged with the per-agent token baked into its URL so the
/// app can route it to the right launched agent.
public struct HookDelivery: Sendable, Equatable {
    public let token: String
    public let event: AgentEvent
    public init(token: String, event: AgentEvent) {
        self.token = token
        self.event = event
    }
}

public enum AgentHookError: Error, Equatable {
    case bindFailed
}

/// Receives Claude Code hook callbacks. Behind a protocol so the app can inject a
/// fake that replays scripted deliveries in tests.
public protocol AgentHookReceiving: Sendable {
    /// Stream of hook deliveries, in arrival order. Single-consumer.
    var deliveries: AsyncStream<HookDelivery> { get }
    /// Bind on loopback and start accepting connections. Returns the bound TCP
    /// port so the caller can build hook URLs. Call once per receiver.
    func start() async throws -> UInt16
    func stop()
}

/// Loopback HTTP listener for Claude Code hooks. Each hook does a fire-and-forget
/// `curl` POST to `http://127.0.0.1:<port>/hook/<token>` with the event JSON as the
/// body; we parse the token + body and yield a `HookDelivery`. Bound to 127.0.0.1
/// only (never a routable interface); the per-agent token is the correlation key.
public final class AgentHookReceiver: AgentHookReceiving, @unchecked Sendable {
    public let deliveries: AsyncStream<HookDelivery>
    private let continuation: AsyncStream<HookDelivery>.Continuation
    private let queue = DispatchQueue(label: "com.sprout.agent-hooks")
    private var listener: NWListener?

    public init() {
        var cont: AsyncStream<HookDelivery>.Continuation!
        self.deliveries = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    public func start() async throws -> UInt16 {
        // Pick an ephemeral loopback port and retry on collision. Binding an
        // explicit host+port keeps us loopback-only (no LAN exposure).
        for _ in 0..<20 {
            let candidate = UInt16.random(in: 49152...65535)
            if let bound = try? await bind(port: candidate) { return bound }
        }
        throw AgentHookError.bindFailed
    }

    private func bind(port raw: UInt16) async throws -> UInt16 {
        guard let port = NWEndpoint.Port(rawValue: raw) else { throw AgentHookError.bindFailed }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        return try await withCheckedThrowingContinuation { cc in
            let resumer = OnceBox()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumer.run { cc.resume(returning: raw) }
                case .failed(let error):
                    resumer.run { cc.resume(throwing: error) }
                case .cancelled:
                    resumer.run { cc.resume(throwing: AgentHookError.bindFailed) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        continuation.finish()
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// Accumulate bytes until the JSON body parses (curl always sends a
    /// Content-Length), yield the delivery, then reply 204 and close.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let delivery = Self.delivery(from: buffer) {
                self.continuation.yield(delivery)
                self.close(conn)
                return
            }
            if isComplete || error != nil {
                self.close(conn)
                return
            }
            self.receive(conn, buffer: buffer)
        }
    }

    private static func delivery(from data: Data) -> HookDelivery? {
        guard
            let token = AgentHookDecoder.requestPathToken(data),
            let body = AgentHookDecoder.httpBody(data),
            let event = AgentHookDecoder.decode(body)
        else { return nil }
        return HookDelivery(token: token, event: event)
    }

    private func close(_ conn: NWConnection) {
        let response = Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n".utf8)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// Ensures a continuation is resumed exactly once across NWListener state
/// callbacks (ready-then-failed, etc.) that could otherwise resume twice.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

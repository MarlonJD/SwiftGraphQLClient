import Foundation
import SwiftGraphQLAppSync
import SwiftGraphQLClient
import XCTest

final class AppSyncRealtimeCodecTests: XCTestCase {
    func testClientStreamsGeneratedSubscriptionData() async throws {
        let socket = MockAppSyncWebSocketTask(messages: [
            .string(#"{"type":"connection_ack"}"#),
            .string(#"{"type":"start_ack","id":"sub-1"}"#),
            .string(#"{"type":"ka"}"#),
            .string(#"{"type":"data","id":"sub-1","payload":{"data":{"messageCreated":{"id":"message-1","requestId":"request-1"}}}}"#),
            .string(#"{"type":"complete","id":"sub-1"}"#)
        ])
        let connector = MockAppSyncConnector(socket: socket)
        let ready = expectation(description: "subscription ready")
        let client = AppSyncRealtimeClient(
            configuration: AppSyncRealtimeConfiguration(
                realtimeEndpointURL: URL(string: "wss://realtime.example.com/graphql")!,
                graphQLEndpointURL: URL(string: "https://api.example.com/graphql")!,
                authProvider: BearerTokenAuthProvider(token: "token-1")
            ),
            connector: connector
        )

        let stream = client.subscribe(
            MessageCreatedSubscription(requestId: "request-1"),
            id: "sub-1",
            onReady: { ready.fulfill() }
        )
        var iterator = stream.makeAsyncIterator()
        let data = try await iterator.next()

        XCTAssertEqual(data?.messageCreated.id, "message-1")
        XCTAssertEqual(data?.messageCreated.requestId, "request-1")
        let completed = try await iterator.next()
        XCTAssertNil(completed)
        await fulfillment(of: [ready], timeout: 1)

        let sent = await socket.sentStrings
        XCTAssertEqual(sent.first, #"{"type":"connection_init"}"#)
        XCTAssertTrue(sent.dropFirst().contains { $0.contains(#""type":"start""#) })
        XCTAssertEqual(connector.requests.count, 1)
        let didResume = await socket.didResume
        XCTAssertTrue(didResume)
    }

    func testWebSocketRequestCarriesBase64AuthorizationHeader() throws {
        let codec = makeCodec()
        let request = try codec.makeWebSocketRequest(headers: ["Authorization": "Bearer token"])

        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "graphql-ws")
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let header = try XCTUnwrap(components.queryItems?.first { $0.name == "header" }?.value)
        let decoded = try decodedObject(fromBase64: header)
        XCTAssertEqual(decoded["Authorization"] as? String, "Bearer token")
        XCTAssertEqual(decoded["host"] as? String, "api.example.com")
    }

    func testStartAndStopMessagesUseGeneratedSubscriptionDocument() throws {
        let codec = makeCodec()
        let start = try codec.startMessage(
            id: "sub-1",
            subscription: MessageCreatedSubscription(requestId: "request-1"),
            headers: ["x-api-key": "key-1"]
        )
        let startJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(start.utf8)) as? [String: Any])
        XCTAssertEqual(startJSON["type"] as? String, "start")
        XCTAssertEqual(startJSON["id"] as? String, "sub-1")

        let payload = try XCTUnwrap(startJSON["payload"] as? [String: Any])
        let operationData = Data(try XCTUnwrap(payload["data"] as? String).utf8)
        let operation = try XCTUnwrap(JSONSerialization.jsonObject(with: operationData) as? [String: Any])
        XCTAssertEqual(operation["operationName"] as? String, "MessageCreated")
        XCTAssertEqual(operation["query"] as? String, MessageCreatedSubscription.document)
        let variables = try XCTUnwrap(operation["variables"] as? [String: Any])
        XCTAssertEqual(variables["requestId"] as? String, "request-1")

        let extensions = try XCTUnwrap(payload["extensions"] as? [String: Any])
        let authorization = try XCTUnwrap(extensions["authorization"] as? [String: Any])
        XCTAssertEqual(authorization["x-api-key"] as? String, "key-1")
        XCTAssertEqual(authorization["host"] as? String, "api.example.com")

        let stop = try codec.stopMessage(id: "sub-1")
        let stopJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stop.utf8)) as? [String: Any])
        XCTAssertEqual(stopJSON["type"] as? String, "stop")
        XCTAssertEqual(stopJSON["id"] as? String, "sub-1")
    }

    func testDecodeEvents() throws {
        let codec = makeCodec()

        if case .connectionAck = try codec.decodeEvent(text: #"{"type":"connection_ack"}"#, expectedID: "sub-1", as: MessageCreatedSubscription.Data.self) {
        } else {
            XCTFail("Expected connection ack.")
        }

        if case .startAck = try codec.decodeEvent(text: #"{"type":"start_ack","id":"sub-1"}"#, expectedID: "sub-1", as: MessageCreatedSubscription.Data.self) {
        } else {
            XCTFail("Expected start ack.")
        }

        if case .keepAlive = try codec.decodeEvent(text: #"{"type":"ka"}"#, expectedID: "sub-1", as: MessageCreatedSubscription.Data.self) {
        } else {
            XCTFail("Expected keepalive.")
        }

        let dataMessage = """
        {"type":"data","id":"sub-1","payload":{"data":{"messageCreated":{"id":"message-1","requestId":"request-1"}}}}
        """
        switch try codec.decodeEvent(text: dataMessage, expectedID: "sub-1", as: MessageCreatedSubscription.Data.self) {
        case .data(let data):
            XCTAssertEqual(data.messageCreated.id, "message-1")
            XCTAssertEqual(data.messageCreated.requestId, "request-1")
        default:
            XCTFail("Expected data event.")
        }

        if case .ignored = try codec.decodeEvent(text: dataMessage, expectedID: "other", as: MessageCreatedSubscription.Data.self) {
        } else {
            XCTFail("Expected ignored event for a different subscription id.")
        }
    }

    private func makeCodec() -> AppSyncRealtimeCodec {
        AppSyncRealtimeCodec(configuration: AppSyncRealtimeConfiguration(
            realtimeEndpointURL: URL(string: "wss://realtime.example.com/graphql")!,
            graphQLEndpointURL: URL(string: "https://api.example.com/graphql")!
        ))
    }

    private func decodedObject(fromBase64 text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(Data(base64Encoded: text))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct MessageCreatedSubscription: GraphQLSubscription {
    struct Variables: Encodable, Sendable {
        let requestId: GraphQLID
    }

    struct Data: Codable, Sendable, Equatable {
        struct MessageCreated: Codable, Sendable, Equatable {
            let id: GraphQLID
            let requestId: GraphQLID
        }

        let messageCreated: MessageCreated
    }

    static let operationName = "MessageCreated"
    static let document = "subscription MessageCreated($requestId: ID!) { messageCreated(requestId: $requestId) { id requestId } }"

    let requestId: GraphQLID

    var variables: Variables {
        Variables(requestId: requestId)
    }
}

private final class MockAppSyncConnector: AppSyncWebSocketConnecting, @unchecked Sendable {
    private let socket: MockAppSyncWebSocketTask
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    init(socket: MockAppSyncWebSocketTask) {
        self.socket = socket
    }

    func appSyncWebSocketTask(with request: URLRequest) -> any AppSyncWebSocketTask {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
        return socket
    }
}

private final class MockAppSyncWebSocketTask: AppSyncWebSocketTask, @unchecked Sendable {
    private let state: MockAppSyncWebSocketTaskState

    var sentStrings: [String] {
        get async {
            await state.sentStrings
        }
    }

    var didResume: Bool {
        get async {
            await state.didResume
        }
    }

    init(messages: [URLSessionWebSocketTask.Message]) {
        self.state = MockAppSyncWebSocketTaskState(messages: messages)
    }

    func resume() {
        Task {
            await state.resume()
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        await state.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await state.receive()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
}

private actor MockAppSyncWebSocketTaskState {
    private var messages: [URLSessionWebSocketTask.Message]
    private var storedSentStrings: [String] = []
    private var resumed = false

    var sentStrings: [String] {
        storedSentStrings
    }

    var didResume: Bool {
        resumed
    }

    init(messages: [URLSessionWebSocketTask.Message]) {
        self.messages = messages
    }

    func resume() {
        resumed = true
    }

    func send(_ message: URLSessionWebSocketTask.Message) {
        if case .string(let text) = message {
            storedSentStrings.append(text)
        }
    }

    func receive() throws -> URLSessionWebSocketTask.Message {
        guard !messages.isEmpty else {
            throw AppSyncRealtimeError.unsupportedMessage
        }
        return messages.removeFirst()
    }
}

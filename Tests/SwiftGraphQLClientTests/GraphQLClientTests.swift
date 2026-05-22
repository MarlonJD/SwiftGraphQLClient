import Foundation
import XCTest
@testable import SwiftGraphQLClient
import SwiftGraphQLUpload

final class GraphQLClientTests: XCTestCase {
    func testFetchBuildsGraphQLHTTPPost() async throws {
        let session = RecordingSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/graphql-response+json, application/json;q=0.9")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Fingerprint"), "device-1")

            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["operationName"] as? String, "Viewer")
            XCTAssertEqual(json["query"] as? String, ViewerQuery.document)
            let variables = try XCTUnwrap(json["variables"] as? [String: Any])
            XCTAssertEqual(variables["id"] as? String, "user-1")

            return Self.response(
                statusCode: 200,
                body: #"{"data":{"viewer":{"id":"user-1","name":"Marlon"}}}"#
            )
        }

        let client = GraphQLClient(
            configuration: GraphQLClientConfiguration(
                endpointURL: URL(string: "https://example.com/graphql")!,
                authProvider: BearerTokenAuthProvider(token: "token-1"),
                deviceFingerprint: "device-1"
            ),
            session: session
        )

        let data = try await client.fetch(ViewerQuery(id: "user-1"))
        XCTAssertEqual(data.viewer.id, "user-1")
        XCTAssertEqual(data.viewer.name, "Marlon")
    }

    func testGraphQLErrorsAreThrownByFetch() async throws {
        let session = RecordingSession { _ in
            Self.response(
                statusCode: 200,
                body: #"{"errors":[{"message":"Nope","extensions":{"code":"UNAUTHORIZED","status":401}}]}"#
            )
        }
        let client = GraphQLClient(
            configuration: GraphQLClientConfiguration(endpointURL: URL(string: "https://example.com/graphql")!),
            session: session
        )

        do {
            _ = try await client.fetch(ViewerQuery(id: "user-1"))
            XCTFail("Expected GraphQL errors.")
        } catch let error as GraphQLClientError {
            XCTAssertTrue(error.isUnauthorized)
        }
    }

    func testRefreshesOnceOnHTTP401() async throws {
        let refresher = RecordingRefresher()
        let session = SequencedSession(responses: [
            Self.response(statusCode: 401, body: #"{"errors":[{"message":"expired"}]}"#),
            Self.response(statusCode: 200, body: #"{"data":{"viewer":{"id":"user-1","name":"Fresh"}}}"#)
        ])
        let client = GraphQLClient(
            configuration: GraphQLClientConfiguration(
                endpointURL: URL(string: "https://example.com/graphql")!,
                sessionRefresher: refresher
            ),
            session: session
        )

        let data = try await client.fetch(ViewerQuery(id: "user-1"))
        XCTAssertEqual(data.viewer.name, "Fresh")
        let refreshCount = await refresher.count
        let requestCount = await session.count
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(requestCount, 2)
    }

    func testSubscribeUsesConfiguredSubscriptionTransport() async throws {
        let client = GraphQLClient(configuration: GraphQLClientConfiguration(
            endpointURL: URL(string: "https://example.com/graphql")!,
            subscriptionTransport: ImmediateSubscriptionTransport()
        ))

        var iterator = client.subscribe(MessageSubscription()).makeAsyncIterator()
        let data = try await iterator.next()

        XCTAssertEqual(data?.message.text, "hello")
    }

    func testSubscribeThrowsWhenNoTransportIsConfigured() async throws {
        let client = GraphQLClient(configuration: GraphQLClientConfiguration(
            endpointURL: URL(string: "https://example.com/graphql")!
        ))

        var iterator = client.subscribe(MessageSubscription()).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected unsupported subscription error.")
        } catch let error as GraphQLClientError {
            guard case .unsupportedSubscriptions = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSingleResponseFormatConstraintCompiles() async throws {
        let client = ImmediateCompatibilityClient()
        let data = try await client.fetch(CompatibilityQuery())

        XCTAssertEqual(data.value, "compat")
    }

    func testGraphQLNullableVariableBuilderOmitsNoneAndKeepsNull() throws {
        var builder = GraphQLVariableBuilder()
        try builder.set("omitted", GraphQLNullable<String>.none)
        try builder.set("null", GraphQLNullable<String>.null)
        try builder.set("some", GraphQLNullable.some("value"))
        let fields = builder.build()

        XCTAssertNil(fields["omitted"])
        XCTAssertEqual(fields["null"], .null)
        XCTAssertEqual(fields["some"], .string("value"))
    }

    func testMultipartBuilderEmitsSpecParts() throws {
        let upload = GraphQLUpload(data: Data("abc".utf8), filename: "a.txt", contentType: "text/plain")
        let body = try GraphQLMultipartBuilder.build(
            operations: .object(["query": .string("mutation Upload { upload }")]),
            fileMap: ["0": ["variables.file"]],
            files: [GraphQLMultipartFile(fieldName: "0", upload: upload)],
            boundary: "Boundary"
        )

        let text = String(decoding: body.body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"operations\""))
        XCTAssertTrue(text.contains("name=\"map\""))
        XCTAssertTrue(text.contains("name=\"0\"; filename=\"a.txt\""))
        XCTAssertTrue(text.contains("abc"))
    }

    func testUploadVariableEncoderBuildsMultipartOperationPayload() throws {
        let mutation = UploadMutation(
            file: GraphQLUpload(data: Data("one".utf8), filename: "one.txt", contentType: "text/plain"),
            files: [GraphQLUpload(data: Data("two".utf8), filename: "two.txt", contentType: "text/plain")],
            avatar: .some(GraphQLUpload(data: Data("avatar".utf8), filename: "avatar.png", contentType: "image/png"))
        )

        let payload = try GraphQLUploadVariableEncoder.operationPayload(for: mutation)

        XCTAssertEqual(payload.fileMap["0"], ["variables.file"])
        XCTAssertEqual(payload.fileMap["1"], ["variables.files.0"])
        XCTAssertEqual(payload.fileMap["2"], ["variables.avatar"])
        XCTAssertEqual(payload.files.map(\.upload.filename), ["one.txt", "two.txt", "avatar.png"])

        guard case .object(let operations) = payload.operations,
              case .object(let variables)? = operations["variables"] else {
            return XCTFail("Expected variables in multipart operations payload.")
        }
        XCTAssertEqual(variables["file"], .null)
        XCTAssertEqual(variables["files"], .array([.null]))
        XCTAssertEqual(variables["avatar"], .null)
    }

    func testUploadRequestEncoderSwitchesClientToMultipartRequest() async throws {
        let session = RecordingSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/graphql-response+json, application/json;q=0.9")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=Boundary")

            let body = try XCTUnwrap(request.httpBody)
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"operations\""))
            XCTAssertTrue(text.contains(#""operationName":"Upload""#))
            XCTAssertTrue(text.contains("variables.file"))
            XCTAssertTrue(text.contains("variables.files.0"))
            XCTAssertTrue(text.contains("variables.avatar"))
            XCTAssertTrue(text.contains("name=\"0\"; filename=\"one.txt\""))
            XCTAssertTrue(text.contains("name=\"1\"; filename=\"two.txt\""))
            XCTAssertTrue(text.contains("name=\"2\"; filename=\"avatar.png\""))

            return Self.response(statusCode: 200, body: #"{"data":{"upload":{"ok":true}}}"#)
        }
        let client = GraphQLClient(
            configuration: GraphQLClientConfiguration(
                endpointURL: URL(string: "https://example.com/graphql")!,
                multipartRequestEncoder: GraphQLUploadRequestEncoder(boundary: "Boundary")
            ),
            session: session
        )

        let data = try await client.perform(UploadMutation(
            file: GraphQLUpload(data: Data("one".utf8), filename: "one.txt", contentType: "text/plain"),
            files: [GraphQLUpload(data: Data("two".utf8), filename: "two.txt", contentType: "text/plain")],
            avatar: .some(GraphQLUpload(data: Data("avatar".utf8), filename: "avatar.png", contentType: "image/png"))
        ))

        XCTAssertTrue(data.upload.ok)
    }

    private static func response(statusCode: Int, body: String) -> (Data, URLResponse) {
        let url = URL(string: "https://example.com/graphql")!
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private struct ViewerQuery: GraphQLQuery {
    static let operationName = "Viewer"
    static let document = "query Viewer($id: ID!) { viewer(id: $id) { id name } }"

    struct Variables: Encodable, Sendable {
        let id: GraphQLID
    }

    struct Data: Decodable, Sendable, Equatable {
        struct Viewer: Decodable, Sendable, Equatable {
            let id: String
            let name: String
        }

        let viewer: Viewer
    }

    let id: GraphQLID

    var variables: Variables {
        Variables(id: id)
    }
}

private protocol CompatibilityGraphQLClient {
    func fetch<Query: GraphQLQuery>(
        _ query: Query,
        cachePolicy: CachePolicy.Query.SingleResponse
    ) async throws -> Query.Data where Query.ResponseFormat == SingleResponseFormat
}

private extension CompatibilityGraphQLClient {
    func fetch<Query: GraphQLQuery>(
        _ query: Query
    ) async throws -> Query.Data where Query.ResponseFormat == SingleResponseFormat {
        try await fetch(query, cachePolicy: .networkOnly)
    }
}

private struct ImmediateCompatibilityClient: CompatibilityGraphQLClient {
    func fetch<Query: GraphQLQuery>(
        _ query: Query,
        cachePolicy: CachePolicy.Query.SingleResponse
    ) async throws -> Query.Data where Query.ResponseFormat == SingleResponseFormat {
        if let data = CompatibilityQuery.Data(value: "compat") as? Query.Data {
            return data
        }
        throw GraphQLClientError.invalidResponse
    }
}

private struct CompatibilityQuery: GraphQLQuery {
    static let operationName = "Compatibility"
    static let document = "query Compatibility { value }"

    struct Data: Decodable, Sendable, Equatable {
        let value: String
    }
}

private struct MessageSubscription: GraphQLSubscription {
    static let operationName = "Message"
    static let document = "subscription Message { message { text } }"

    struct Data: Decodable, Sendable, Equatable {
        struct Message: Decodable, Sendable, Equatable {
            let text: String
        }

        let message: Message
    }
}

private struct UploadMutation: GraphQLMutation {
    static let operationName = "Upload"
    static let document = "mutation Upload($file: Upload!, $files: [Upload!]!, $avatar: Upload) { upload(file: $file, files: $files, avatar: $avatar) { ok } }"

    struct Variables: Encodable, Sendable, GraphQLVariableMapConvertible {
        let file: GraphQLUpload
        let files: [GraphQLUpload]
        let avatar: GraphQLNullable<GraphQLUpload>

        func graphQLVariableMap() throws -> [String: GraphQLJSONValue] {
            var builder = GraphQLVariableBuilder()
            try builder.set("file", file)
            try builder.set("files", files)
            try builder.set("avatar", avatar)
            return builder.build()
        }
    }

    struct Data: Decodable, Sendable, Equatable {
        struct Upload: Decodable, Sendable, Equatable {
            let ok: Bool
        }

        let upload: Upload
    }

    let file: GraphQLUpload
    let files: [GraphQLUpload]
    let avatar: GraphQLNullable<GraphQLUpload>

    var variables: Variables {
        Variables(file: file, files: files, avatar: avatar)
    }
}

private struct ImmediateSubscriptionTransport: GraphQLSubscriptionTransport {
    func subscribe<Subscription: GraphQLSubscription>(
        _ subscription: Subscription
    ) -> AsyncThrowingStream<Subscription.Data, Error> {
        AsyncThrowingStream { continuation in
            if let data = MessageSubscription.Data(message: .init(text: "hello")) as? Subscription.Data {
                continuation.yield(data)
                continuation.finish()
            } else {
                continuation.finish(throwing: GraphQLClientError.invalidResponse)
            }
        }
    }
}

private final class RecordingSession: GraphQLURLSession, @unchecked Sendable {
    private let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

private actor SequencedSession: GraphQLURLSession {
    private var responses: [(Data, URLResponse)]
    private(set) var count = 0

    init(responses: [(Data, URLResponse)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        return responses.removeFirst()
    }
}

private actor RecordingRefresher: GraphQLSessionRefresher {
    private(set) var count = 0

    func refreshSession() async throws -> Bool {
        count += 1
        return true
    }
}

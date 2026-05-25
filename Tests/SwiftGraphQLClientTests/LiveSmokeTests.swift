import Foundation
import SwiftGraphQLAppSync
import SwiftGraphQLClient
import SwiftGraphQLCodegenCore
import XCTest

final class LiveSmokeTests: XCTestCase {
    func testLiveHTTPGraphQLSmokeWhenConfigured() async throws {
        guard let endpoint = URL(string: environment["SWIFT_GRAPHQL_LIVE_HTTP_ENDPOINT"] ?? "") else {
            throw XCTSkip("Set SWIFT_GRAPHQL_LIVE_HTTP_ENDPOINT to run the live HTTP GraphQL smoke test.")
        }

        let client = GraphQLClient(configuration: GraphQLClientConfiguration(
            endpointURL: endpoint,
            additionalHeaders: try liveHeaders(prefix: "SWIFT_GRAPHQL_LIVE_HTTP")
        ))

        let data = try await client.fetch(LiveSmokeQuery(
            variables: try inputObject(fromJSONEnvironmentKey: "SWIFT_GRAPHQL_LIVE_HTTP_VARIABLES_JSON")
        ))

        XCTAssertNotNil(data.objectValue)
    }

    func testLiveAppSyncRealtimeReadySmokeWhenConfigured() async throws {
        guard let realtimeEndpoint = URL(string: environment["SWIFT_GRAPHQL_LIVE_APPSYNC_REALTIME_ENDPOINT"] ?? ""),
              let graphQLEndpoint = URL(string: environment["SWIFT_GRAPHQL_LIVE_APPSYNC_GRAPHQL_ENDPOINT"] ?? "") else {
            throw XCTSkip("Set SWIFT_GRAPHQL_LIVE_APPSYNC_REALTIME_ENDPOINT and SWIFT_GRAPHQL_LIVE_APPSYNC_GRAPHQL_ENDPOINT to run the live AppSync smoke test.")
        }
        guard environment["SWIFT_GRAPHQL_LIVE_APPSYNC_SUBSCRIPTION"] != nil else {
            throw XCTSkip("Set SWIFT_GRAPHQL_LIVE_APPSYNC_SUBSCRIPTION to run the live AppSync smoke test.")
        }

        let client = AppSyncRealtimeClient(configuration: AppSyncRealtimeConfiguration(
            realtimeEndpointURL: realtimeEndpoint,
            graphQLEndpointURL: graphQLEndpoint,
            authProvider: CustomHeadersAuthProvider(headers: try liveHeaders(prefix: "SWIFT_GRAPHQL_LIVE_APPSYNC")),
            keepAliveTimeout: 20
        ))
        let ready = expectation(description: "AppSync subscription reached start_ack")
        let stream = client.subscribe(
            LiveAppSyncSubscription(
                variables: try inputObject(fromJSONEnvironmentKey: "SWIFT_GRAPHQL_LIVE_APPSYNC_VARIABLES_JSON")
            ),
            id: "live-smoke",
            onReady: { ready.fulfill() }
        )
        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
        }

        await fulfillment(of: [ready], timeout: 20)
        consumer.cancel()
    }

    func testLiveOperationManifestPublishSmokeWhenConfigured() throws {
        guard let endpoint = URL(string: environment["SWIFT_GRAPHQL_LIVE_MANIFEST_ENDPOINT"] ?? "") else {
            throw XCTSkip("Set SWIFT_GRAPHQL_LIVE_MANIFEST_ENDPOINT to run the live operation manifest publish smoke test.")
        }

        let manifestURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-graphql-live-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestURL) }
        let manifest = environment["SWIFT_GRAPHQL_LIVE_MANIFEST_JSON"] ?? """
        {
          "format": "apollo-persisted-query-manifest",
          "version": 1,
          "operations": []
        }
        """
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        let statusCode = try CodegenRunner.publishOperationManifest(
            manifestURL: manifestURL,
            endpointURL: endpoint,
            headers: try liveHeaders(prefix: "SWIFT_GRAPHQL_LIVE_MANIFEST")
        )

        XCTAssertTrue((200...299).contains(statusCode))
    }

    private var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    private func liveHeaders(prefix: String) throws -> [String: String] {
        var headers = try headers(fromJSONEnvironmentKey: "\(prefix)_HEADERS_JSON")
        if let authorization = environment["\(prefix)_AUTHORIZATION"], !authorization.isEmpty {
            headers["Authorization"] = authorization
        }
        if let apiKey = environment["\(prefix)_API_KEY"], !apiKey.isEmpty {
            headers["x-api-key"] = apiKey
        }
        return headers
    }

    private func headers(fromJSONEnvironmentKey key: String) throws -> [String: String] {
        guard let text = environment[key], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        guard let fields = object as? [String: String] else {
            throw CodegenError.invalidConfiguration("\(key) must be a JSON object of string headers.")
        }
        return fields
    }

    private func inputObject(fromJSONEnvironmentKey key: String) throws -> GraphQLInputObject {
        guard let text = environment[key], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return GraphQLInputObject()
        }
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        guard case .object(let fields) = try GraphQLJSONValue(jsonObject: object) else {
            throw CodegenError.invalidConfiguration("\(key) must be a JSON object.")
        }
        return GraphQLInputObject(fields: fields)
    }
}

private struct LiveSmokeQuery: GraphQLQuery {
    static var operationName: String {
        ProcessInfo.processInfo.environment["SWIFT_GRAPHQL_LIVE_HTTP_OPERATION_NAME"] ?? "SwiftGraphQLClientLiveSmoke"
    }

    static var document: String {
        ProcessInfo.processInfo.environment["SWIFT_GRAPHQL_LIVE_HTTP_QUERY"] ?? "query SwiftGraphQLClientLiveSmoke { __typename }"
    }

    typealias Variables = GraphQLInputObject
    typealias Data = GraphQLJSONValue

    var variables: GraphQLInputObject
}

private struct LiveAppSyncSubscription: GraphQLSubscription {
    static var operationName: String {
        ProcessInfo.processInfo.environment["SWIFT_GRAPHQL_LIVE_APPSYNC_OPERATION_NAME"] ?? "SwiftGraphQLClientLiveAppSyncSmoke"
    }

    static var document: String {
        ProcessInfo.processInfo.environment["SWIFT_GRAPHQL_LIVE_APPSYNC_SUBSCRIPTION"] ?? "subscription SwiftGraphQLClientLiveAppSyncSmoke { __typename }"
    }

    typealias Variables = GraphQLInputObject
    typealias Data = GraphQLJSONValue

    var variables: GraphQLInputObject
}

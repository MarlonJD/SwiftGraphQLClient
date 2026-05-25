import Foundation
import SwiftGraphQLCodegenCore
import XCTest

final class CodegenTests: XCTestCase {
    func testGenerateWritesOperationShellsAndInputObjects() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftGraphQLCodegenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let schemaURL = root.appendingPathComponent("schema.graphqls")
        let operationsDirectory = root.appendingPathComponent("Operations")
        try FileManager.default.createDirectory(at: operationsDirectory, withIntermediateDirectories: true)
        try """
        scalar AWSDateTime
        scalar AWSJSON
        scalar Upload
        input LoginInput {
          email: String!
          deviceId: String
        }
        enum MessagePageDirection {
          forward
          older
        }
        type Query {
          messages(input: MessagePageInput): MessageConnection!
          viewer: Viewer!
        }
        type Mutation {
          login(input: LoginInput!): AuthPayload!
        }
        type Viewer {
          subscription: SubscriptionEntitlement!
        }
        type SubscriptionEntitlement {
          active: Boolean!
        }
        type AuthPayload {
          token: String!
        }
        type MessageConnection {
          messages: [Message!]!
          nextCursor: String
        }
        type Message {
          id: ID!
        }
        input MessagePageInput {
          limit: Int!
          direction: MessagePageDirection
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        try """
        mutation Login($input: LoginInput!) {
          login(input: $input)
        }

        query ViewerSubscription {
          viewer {
            subscription {
              active
            }
          }
        }

        query Messages($limit: Int! = 25, $direction: MessagePageDirection) {
          messages(input: { limit: $limit, direction: $direction }) {
            messages {
              ...MessageName
            }
            nextCursor
          }
        }

        fragment MessageName on Message {
          id
        }
        """.write(to: operationsDirectory.appendingPathComponent("Auth.graphql"), atomically: true, encoding: .utf8)

        let configURL = root.appendingPathComponent("swift-graphql-codegen.yml")
        try """
        namespace: KindredAPI
        schema:
          - schema.graphqls
        operations:
          - Operations/**/*.graphql
        output: GeneratedGraphQL
        operationManifest:
          path: operation-manifest.json
        scalars:
          AWSDateTime: Date
          AWSJSON: GraphQLJSON
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let outputURL = try CodegenRunner.generate(configURL: configURL)
        let output = try String(contentsOf: outputURL)

        XCTAssertTrue(output.contains("public enum KindredAPI"))
        XCTAssertTrue(output.contains("import SwiftGraphQLUpload"))
        XCTAssertTrue(output.contains("public typealias Upload = GraphQLUpload"))
        XCTAssertTrue(output.contains("public typealias AWSDateTime = Date"))
        XCTAssertTrue(output.contains("public typealias AWSJSON = GraphQLJSON"))
        XCTAssertTrue(output.contains("struct LoginInput"))
        XCTAssertTrue(output.contains("deviceId: GraphQLNullable<String> = .none"))
        XCTAssertTrue(output.contains("enum MessagePageDirection"))
        XCTAssertTrue(output.contains("struct LoginMutation: GraphQLMutation"))
        XCTAssertTrue(output.contains("public static let operationIdentifier = \""))
        XCTAssertTrue(output.contains("struct MessagesQuery: GraphQLQuery"))
        XCTAssertTrue(output.contains("struct ViewerSubscriptionQuery: GraphQLQuery"))
        XCTAssertTrue(output.contains("public static let selections: [SwiftGraphQLClient.GraphQLSelection]"))
        XCTAssertTrue(output.contains("public static let fragments: [String: [SwiftGraphQLClient.GraphQLSelection]]"))
        XCTAssertTrue(output.contains(#""MessageName": ["#))
        XCTAssertTrue(output.contains(#".field(name: "messages", responseName: "messages""#))
        XCTAssertTrue(output.contains(#".fragmentSpread("MessageName")"#))
        XCTAssertTrue(output.contains("fragment MessageName on Message"))
        XCTAssertTrue(output.contains("limit: Int32 = 25"))
        XCTAssertTrue(output.contains("direction: GraphQLNullable<GraphQLEnum<MessagePageDirection>> = .none"))
        XCTAssertTrue(output.contains("public struct Data: Codable, Sendable, Equatable"))
        XCTAssertTrue(output.contains("public var messages: Messages"))
        XCTAssertTrue(output.contains("public struct Message: Codable, Sendable, Equatable"))
        XCTAssertTrue(output.contains("public var messageName: MessageName"))
        XCTAssertTrue(output.contains("public var active: Bool"))

        let manifestURL = root.appendingPathComponent("operation-manifest.json")
        let manifest = try String(contentsOf: manifestURL)
        XCTAssertTrue(manifest.contains(#""format" : "apollo-persisted-query-manifest""#))
        XCTAssertTrue(manifest.contains(#""name" : "Messages""#))
        XCTAssertTrue(manifest.contains("fragment MessageName on Message"))
    }

    func testGenerateModelsAbstractTypeInlineFragmentsAndLocalCacheMutations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftGraphQLCodegenAbstractTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let schemaURL = root.appendingPathComponent("schema.graphqls")
        let operationsDirectory = root.appendingPathComponent("Operations")
        try FileManager.default.createDirectory(at: operationsDirectory, withIntermediateDirectories: true)
        try """
        schema {
          query: RootQuery
        }
        interface Node {
          id: ID!
        }
        type User implements Node {
          id: ID!
          name: String!
        }
        type Message implements Node {
          id: ID!
          text: String!
        }
        union SearchResult = User | Message
        type RootQuery {
          search: [SearchResult!]!
          node: Node
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        try """
        query Search {
          search {
            __typename
            ... on User {
              id
              name
            }
            ... on Message {
              id
              text
            }
          }
          node {
            __typename
            id
            ... on User {
              name
            }
          }
        }
        """.write(to: operationsDirectory.appendingPathComponent("Search.graphql"), atomically: true, encoding: .utf8)

        let configURL = root.appendingPathComponent("swift-graphql-codegen.yml")
        try """
        namespace: SearchAPI
        schema:
          - schema.graphqls
        operations:
          - Operations/**/*.graphql
        output: GeneratedGraphQL
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let outputURL = try CodegenRunner.generate(configURL: configURL)
        let output = try String(contentsOf: outputURL)

        XCTAssertTrue(output.contains("struct SearchQuery: GraphQLQuery"))
        XCTAssertTrue(output.contains("public var asUser: AsUser?"))
        XCTAssertTrue(output.contains("public var asMessage: AsMessage?"))
        XCTAssertTrue(output.contains("GraphQLResponseCodingKey(\"__typename\")"))
        XCTAssertTrue(output.contains(#"["Message"].contains($0)"#))
        XCTAssertTrue(output.contains(#"["User"].contains($0)"#))
        XCTAssertTrue(output.contains("public struct LocalCacheMutation: GraphQLLocalCacheMutation"))
        XCTAssertTrue(output.contains("public func localCacheMutation(data: SearchQuery.Data) -> LocalCacheMutation"))
    }

    func testOperationManifestPublisherBuildsJSONPostRequest() throws {
        let manifest = Data(#"{"format":"apollo-persisted-query-manifest"}"#.utf8)
        let request = OperationManifestPublisher.request(
            manifestData: manifest,
            endpointURL: URL(string: "https://example.com/pql")!,
            headers: ["Authorization": "Bearer token"]
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(request.httpBody, manifest)
    }

    func testIntrospectionJSONPrintsSDL() throws {
        let fixture = """
        {
          "data": {
            "__schema": {
              "queryType": { "name": "RootQuery" },
              "mutationType": { "name": "Mutation" },
              "subscriptionType": null,
              "directives": [
                {
                  "name": "auth",
                  "locations": ["OBJECT", "FIELD_DEFINITION"],
                  "isRepeatable": false,
                  "args": [
                    {
                      "name": "role",
                      "type": { "kind": "SCALAR", "name": "String", "ofType": null },
                      "defaultValue": "\\"user\\""
                    }
                  ]
                }
              ],
              "types": [
                { "kind": "SCALAR", "name": "String" },
                { "kind": "SCALAR", "name": "Int" },
                { "kind": "SCALAR", "name": "ID" },
                { "kind": "SCALAR", "name": "AWSDateTime" },
                {
                  "kind": "ENUM",
                  "name": "Role",
                  "enumValues": [
                    { "name": "ADMIN" },
                    { "name": "USER" }
                  ]
                },
                {
                  "kind": "INPUT_OBJECT",
                  "name": "LoginInput",
                  "inputFields": [
                    {
                      "name": "email",
                      "type": {
                        "kind": "NON_NULL",
                        "name": null,
                        "ofType": { "kind": "SCALAR", "name": "String", "ofType": null }
                      },
                      "defaultValue": null
                    },
                    {
                      "name": "role",
                      "type": { "kind": "ENUM", "name": "Role", "ofType": null },
                      "defaultValue": "USER"
                    }
                  ]
                },
                {
                  "kind": "INTERFACE",
                  "name": "Node",
                  "fields": [
                    {
                      "name": "id",
                      "args": [],
                      "type": {
                        "kind": "NON_NULL",
                        "name": null,
                        "ofType": { "kind": "SCALAR", "name": "ID", "ofType": null }
                      }
                    }
                  ]
                },
                {
                  "kind": "UNION",
                  "name": "SearchResult",
                  "possibleTypes": [
                    { "kind": "OBJECT", "name": "Viewer", "ofType": null }
                  ]
                },
                {
                  "kind": "OBJECT",
                  "name": "RootQuery",
                  "interfaces": [],
                  "fields": [
                    {
                      "name": "viewer",
                      "args": [],
                      "type": {
                        "kind": "NON_NULL",
                        "name": null,
                        "ofType": { "kind": "OBJECT", "name": "Viewer", "ofType": null }
                      }
                    },
                    {
                      "name": "search",
                      "args": [
                        {
                          "name": "limit",
                          "type": { "kind": "SCALAR", "name": "Int", "ofType": null },
                          "defaultValue": "10"
                        }
                      ],
                      "type": {
                        "kind": "LIST",
                        "name": null,
                        "ofType": { "kind": "UNION", "name": "SearchResult", "ofType": null }
                      }
                    }
                  ]
                },
                {
                  "kind": "OBJECT",
                  "name": "Mutation",
                  "interfaces": [],
                  "fields": [
                    {
                      "name": "login",
                      "args": [
                        {
                          "name": "input",
                          "type": {
                            "kind": "NON_NULL",
                            "name": null,
                            "ofType": { "kind": "INPUT_OBJECT", "name": "LoginInput", "ofType": null }
                          },
                          "defaultValue": null
                        }
                      ],
                      "type": { "kind": "SCALAR", "name": "String", "ofType": null }
                    }
                  ]
                },
                {
                  "kind": "OBJECT",
                  "name": "Viewer",
                  "interfaces": [
                    { "kind": "INTERFACE", "name": "Node", "ofType": null }
                  ],
                  "fields": [
                    {
                      "name": "id",
                      "args": [],
                      "type": {
                        "kind": "NON_NULL",
                        "name": null,
                        "ofType": { "kind": "SCALAR", "name": "ID", "ofType": null }
                      }
                    },
                    {
                      "name": "createdAt",
                      "args": [],
                      "type": { "kind": "SCALAR", "name": "AWSDateTime", "ofType": null }
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let sdl = try GraphQLIntrospection.schemaSDL(from: Data(fixture.utf8))

        XCTAssertTrue(sdl.contains("schema {\n  query: RootQuery\n}"))
        XCTAssertTrue(sdl.contains("directive @auth(role: String = \"user\") on FIELD_DEFINITION | OBJECT"))
        XCTAssertTrue(sdl.contains("scalar AWSDateTime"))
        XCTAssertTrue(sdl.contains("enum Role {\n  ADMIN\n  USER\n}"))
        XCTAssertTrue(sdl.contains("input LoginInput {\n  email: String!\n  role: Role = USER\n}"))
        XCTAssertTrue(sdl.contains("interface Node {\n  id: ID!\n}"))
        XCTAssertTrue(sdl.contains("union SearchResult = Viewer"))
        XCTAssertTrue(sdl.contains("type RootQuery {\n  viewer: Viewer!\n  search(limit: Int = 10): [SearchResult]\n}"))
        XCTAssertTrue(sdl.contains("type Viewer implements Node {\n  id: ID!\n  createdAt: AWSDateTime\n}"))
    }
}

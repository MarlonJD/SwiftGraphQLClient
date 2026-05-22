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
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let outputURL = try CodegenRunner.generate(configURL: configURL)
        let output = try String(contentsOf: outputURL)

        XCTAssertTrue(output.contains("public enum KindredAPI"))
        XCTAssertTrue(output.contains("import SwiftGraphQLUpload"))
        XCTAssertTrue(output.contains("public typealias Upload = GraphQLUpload"))
        XCTAssertTrue(output.contains("struct LoginInput"))
        XCTAssertTrue(output.contains("deviceId: GraphQLNullable<String> = .none"))
        XCTAssertTrue(output.contains("enum MessagePageDirection"))
        XCTAssertTrue(output.contains("struct LoginMutation: GraphQLMutation"))
        XCTAssertTrue(output.contains("struct MessagesQuery: GraphQLQuery"))
        XCTAssertTrue(output.contains("struct ViewerSubscriptionQuery: GraphQLQuery"))
        XCTAssertTrue(output.contains("fragment MessageName on Message"))
        XCTAssertTrue(output.contains("limit: Int32 = 25"))
        XCTAssertTrue(output.contains("direction: GraphQLNullable<GraphQLEnum<MessagePageDirection>> = .none"))
        XCTAssertTrue(output.contains("public struct Data: Codable, Sendable, Equatable"))
        XCTAssertTrue(output.contains("public var messages: Messages"))
        XCTAssertTrue(output.contains("public struct Message: Codable, Sendable, Equatable"))
        XCTAssertTrue(output.contains("public var messageName: MessageName"))
        XCTAssertTrue(output.contains("public var active: Bool"))
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

import SwiftGraphQLClient
import SwiftGraphQLPagination
import SwiftGraphQLTestSupport
import XCTest

final class PaginationAndTestSupportTests: XCTestCase {
    func testQueryPagerFetchesForwardPagesAndTracksNodes() async throws {
        let pager = GraphQLQueryPager<String, String>(pageSize: 2) { request in
            XCTAssertEqual(request.limit, 2)
            if request.cursor == nil {
                return GraphQLPage(
                    nodes: ["one", "two"],
                    endCursor: "cursor-2",
                    hasNextPage: true
                )
            }
            return GraphQLPage(
                nodes: ["three"],
                startCursor: "cursor-3",
                endCursor: "cursor-3",
                hasNextPage: false
            )
        }

        _ = try await pager.fetchNext()
        _ = try await pager.fetchNext()

        let nodes = await pager.nodes
        XCTAssertEqual(nodes, ["one", "two", "three"])
    }

    func testMockClientReturnsQueuedOperationData() async throws {
        let client = GraphQLMockClient()
        await client.enqueue(MockQuery.self, data: MockQuery.Data(value: "ok"))

        let data = try await client.fetch(MockQuery())
        let names = await client.executedOperationNames

        XCTAssertEqual(data.value, "ok")
        XCTAssertEqual(names, ["Mock"])
    }
}

private struct MockQuery: GraphQLQuery {
    static let operationName = "Mock"
    static let document = "query Mock { value }"

    struct Data: Codable, Sendable, Equatable {
        let value: String
    }
}

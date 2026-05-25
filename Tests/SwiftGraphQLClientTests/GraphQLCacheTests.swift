import SwiftGraphQLCache
import SwiftGraphQLClient
import XCTest

final class GraphQLCacheTests: XCTestCase {
    func testWriteReadMergeAndPartialDetection() async {
        let store = GraphQLMemoryStore()
        let id = GraphQLRecordID(typename: "User", id: "1")

        await store.write(GraphQLRecord(id: id, fields: ["name": .string("Marlon")]))
        await store.write(GraphQLRecord(id: id, fields: ["city": .string("Istanbul")]))

        let record = await store.read(id)
        XCTAssertEqual(record?.fields["name"], .string("Marlon"))
        XCTAssertEqual(record?.fields["city"], .string("Istanbul"))

        let result = await store.read(id, requiredFields: ["name", "city", "email"])
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.missingFields, ["email"])
    }

    func testWatchYieldsCurrentChangesAndEviction() async throws {
        let store = GraphQLMemoryStore()
        let id = GraphQLRecordID(typename: "User", id: "1")
        let stream = await store.watch(id)
        var iterator = stream.makeAsyncIterator()

        let initial = await iterator.next()
        guard let initial else {
            return XCTFail("Expected initial cache value.")
        }
        XCTAssertNil(initial)

        await store.write(GraphQLRecord(id: id, fields: ["name": .string("A")]))
        let changed = await iterator.next()
        XCTAssertEqual(changed??.fields["name"], .string("A"))

        await store.evict(id)
        let evicted = await iterator.next()
        guard let evicted else {
            return XCTFail("Expected eviction cache value.")
        }
        XCTAssertNil(evicted)
    }

    func testOptimisticLayerRollbackAndCommit() async {
        let store = GraphQLMemoryStore()
        let id = GraphQLRecordID(typename: "User", id: "1")
        await store.write(GraphQLRecord(id: id, fields: ["name": .string("Base")]))

        let rollbackLayer = await store.beginOptimisticLayer(id: GraphQLOptimisticLayerID(rawValue: "rollback"))
        await store.writeOptimistic(GraphQLRecord(id: id, fields: ["name": .string("Temp")]), layerID: rollbackLayer)
        let optimistic = await store.read(id)
        XCTAssertEqual(optimistic?.fields["name"], .string("Temp"))

        await store.rollbackOptimisticLayer(id: rollbackLayer)
        let rolledBack = await store.read(id)
        XCTAssertEqual(rolledBack?.fields["name"], .string("Base"))

        let commitLayer = await store.beginOptimisticLayer(id: GraphQLOptimisticLayerID(rawValue: "commit"))
        await store.writeOptimistic(GraphQLRecord(id: id, fields: ["city": .string("Istanbul")]), layerID: commitLayer)
        await store.commitOptimisticLayer(id: commitLayer)

        let committed = await store.read(id)
        XCTAssertEqual(committed?.fields["name"], .string("Base"))
        XCTAssertEqual(committed?.fields["city"], .string("Istanbul"))
    }

    func testAppendReferencesDeduplicatesCursorLists() async {
        let store = GraphQLMemoryStore()
        let connectionID = GraphQLRecordID(rawValue: "Query:messages")
        let first = GraphQLRecordID(typename: "Message", id: "1")
        let second = GraphQLRecordID(typename: "Message", id: "2")

        await store.write(GraphQLRecord(id: connectionID, fields: [:]))
        await store.appendReferences(to: connectionID, field: "messages", references: [first, second])
        await store.appendReferences(to: connectionID, field: "messages", references: [second])

        guard case .array(let values) = await store.read(connectionID)?.fields["messages"] else {
            return XCTFail("Expected message references.")
        }
        XCTAssertEqual(values, [
            GraphQLRecord.referenceValue(first),
            GraphQLRecord.referenceValue(second)
        ])
    }

    func testNormalizedCacheStoresEntitiesAndPathFallbackObjects() async throws {
        let cache = GraphQLNormalizedCache(configuration: GraphQLNormalizationConfiguration(
            customKeyFields: ["Viewer": ["slug"]]
        ))
        let query = CacheViewerQuery(slug: "marlon")

        try await cache.write(query, data: .object([
            "viewer": .object([
                "__typename": .string("Viewer"),
                "slug": .string("marlon"),
                "name": .string("Marlon"),
                "settings": .object([
                    "theme": .string("dark")
                ])
            ])
        ]))

        let response = try await cache.read(query)
        XCTAssertFalse(response.isPartial)
        XCTAssertEqual(response.data, .object([
            "viewer": .object([
                "__typename": .string("Viewer"),
                "slug": .string("marlon"),
                "name": .string("Marlon"),
                "settings": .object([
                    "theme": .string("dark")
                ])
            ])
        ]))
    }

    func testNormalizedCacheReportsPartialRootReads() async throws {
        let cache = GraphQLNormalizedCache()
        let response = try await cache.read(CacheViewerQuery(slug: "missing"))

        XCTAssertTrue(response.isPartial)
        XCTAssertNil(response.data)
        XCTAssertEqual(response.missingFields, ["viewer"])
    }

    func testNormalizedCacheReportsPartialNestedReads() async throws {
        let cache = GraphQLNormalizedCache()
        let query = CacheViewerQuery(slug: "marlon")

        try await cache.write(query, data: .object([
            "viewer": .object([
                "__typename": .string("Viewer"),
                "slug": .string("marlon"),
                "name": .string("Marlon")
            ])
        ]))

        let response = try await cache.read(query)

        XCTAssertTrue(response.isPartial)
        XCTAssertEqual(response.missingFields, ["viewer.settings"])
    }

    func testProgrammaticCacheKeyResolverTakesPrecedence() async throws {
        let store = GraphQLMemoryStore()
        let cache = GraphQLNormalizedCache(
            store: store,
            configuration: GraphQLNormalizationConfiguration(
                programmaticCacheKeyResolver: SlugCacheKeyResolver()
            )
        )

        try await cache.write(CacheViewerQuery(slug: "marlon"), data: .object([
            "viewer": .object([
                "__typename": .string("Viewer"),
                "slug": .string("marlon"),
                "name": .string("Marlon"),
                "settings": .object(["theme": .string("dark")])
            ])
        ]))

        let record = await store.read(GraphQLRecordID(rawValue: "ViewerSlug:marlon"))

        XCTAssertEqual(record?.fields["name"], .string("Marlon"))
    }

    func testTrimEvictsOldestRecords() async {
        let store = GraphQLMemoryStore()
        let first = GraphQLRecordID(typename: "Message", id: "1")
        let second = GraphQLRecordID(typename: "Message", id: "2")
        let third = GraphQLRecordID(typename: "Message", id: "3")

        await store.write(GraphQLRecord(id: first, fields: ["text": .string("one")]))
        await store.write(GraphQLRecord(id: second, fields: ["text": .string("two")]))
        await store.write(GraphQLRecord(id: third, fields: ["text": .string("three")]))

        let evicted = await store.trim(maxRecordCount: 2)
        let ids = await store.recordIDs()

        XCTAssertEqual(evicted, [first])
        XCTAssertEqual(ids, [second, third])
    }

    func testOperationCacheStoreUpdatesQueryDataTransactionally() async throws {
        let cache = GraphQLNormalizedCache()
        let store = GraphQLOperationCacheStore(cache: cache)
        let query = CounterQuery()

        try await cache.write(query, data: .object(["counter": .object(["value": .int(1)])]))
        let value = try await store.withinReadWriteTransaction { transaction in
            try await transaction.update(query) { data in
                data.counter.value += 1
            }
            return try await transaction.read(query).counter.value
        }

        XCTAssertEqual(value, 2)
    }
}

private struct CacheViewerQuery: GraphQLQuery {
    static let operationName = "CacheViewer"
    static let document = "query CacheViewer($slug: String!) { viewer(slug: $slug) { __typename slug name settings { theme } } }"
    static let selections: [GraphQLSelection] = [
        .field(name: "viewer", responseName: "viewer", selections: [
            .fragmentSpread("ViewerFields"),
            .field(name: "settings", responseName: "settings", selections: [
                .field(name: "theme", responseName: "theme", selections: [])
            ])
        ])
    ]
    static let fragments: [String: [GraphQLSelection]] = [
        "ViewerFields": [
            .field(name: "__typename", responseName: "__typename", selections: []),
            .field(name: "slug", responseName: "slug", selections: []),
            .field(name: "name", responseName: "name", selections: [])
        ]
    ]

    struct Variables: Encodable, Sendable {
        let slug: String
    }

    struct Data: Codable, Sendable, Equatable {
        struct Viewer: Codable, Sendable, Equatable {
            struct Settings: Codable, Sendable, Equatable {
                let theme: String
            }

            let slug: String
            let name: String
            let settings: Settings
        }

        let viewer: Viewer
    }

    let slug: String

    var variables: Variables {
        Variables(slug: slug)
    }
}

private struct SlugCacheKeyResolver: GraphQLProgrammaticCacheKeyResolver {
    func cacheKey(
        forTypename typename: String,
        object: [String: GraphQLJSONValue]
    ) -> GraphQLRecordID? {
        guard typename == "Viewer", let slug = object["slug"]?.stringValue else { return nil }
        return GraphQLRecordID(rawValue: "ViewerSlug:\(slug)")
    }
}

private struct CounterQuery: GraphQLQuery {
    static let operationName = "Counter"
    static let document = "query Counter { counter { value } }"
    static let selections: [GraphQLSelection] = [
        .field(name: "counter", responseName: "counter", selections: [
            .field(name: "value", responseName: "value", selections: [])
        ])
    ]

    struct Data: Codable, Sendable, Equatable {
        struct Counter: Codable, Sendable, Equatable {
            var value: Int
        }

        var counter: Counter
    }
}

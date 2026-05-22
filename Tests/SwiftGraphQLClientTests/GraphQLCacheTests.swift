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
}

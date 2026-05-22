import SwiftGraphQLCache
import SwiftGraphQLClient
import SwiftGraphQLSQLiteStore
import XCTest

final class SQLiteNormalizedStoreTests: XCTestCase {
    func testPersistsRecordsAcrossStoreInstances() async throws {
        let fileURL = temporaryDatabaseURL()
        let id = GraphQLRecordID(typename: "User", id: "1")

        let firstStore = try SQLiteNormalizedStore(configuration: SQLiteNormalizedStoreConfiguration(fileURL: fileURL))
        try await firstStore.write(GraphQLRecord(id: id, fields: ["name": .string("Marlon")]))

        let secondStore = try SQLiteNormalizedStore(configuration: SQLiteNormalizedStoreConfiguration(fileURL: fileURL))
        let record = try await secondStore.read(id)

        XCTAssertEqual(record?.fields["name"], .string("Marlon"))
    }

    func testMergeWritePartialReadEvictAndClear() async throws {
        let store = try SQLiteNormalizedStore(configuration: SQLiteNormalizedStoreConfiguration(fileURL: temporaryDatabaseURL()))
        let first = GraphQLRecordID(typename: "User", id: "1")
        let second = GraphQLRecordID(typename: "User", id: "2")

        try await store.write(GraphQLRecord(id: first, fields: ["name": .string("Marlon")]))
        try await store.write(GraphQLRecord(id: first, fields: ["city": .string("Istanbul")]))

        let result = try await store.read(first, requiredFields: ["name", "city", "email"])
        XCTAssertEqual(result.record?.fields["name"], .string("Marlon"))
        XCTAssertEqual(result.record?.fields["city"], .string("Istanbul"))
        XCTAssertEqual(result.missingFields, ["email"])

        try await store.write([
            GraphQLRecord(id: second, fields: ["name": .string("Aylin")])
        ])
        let secondRecord = try await store.read(second)
        XCTAssertEqual(secondRecord?.fields["name"], .string("Aylin"))

        try await store.evict(first)
        let evicted = try await store.read(first)
        XCTAssertNil(evicted)

        try await store.clear()
        let cleared = try await store.read(second)
        XCTAssertNil(cleared)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftGraphQLSQLiteStoreTests-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }
}

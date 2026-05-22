import Foundation
import SwiftGraphQLClient

public struct GraphQLRecordID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(typename: String, id: String) {
        self.rawValue = "\(typename):\(id)"
    }

    public var description: String { rawValue }
}

public struct GraphQLRecord: Equatable, Sendable, Codable {
    public var id: GraphQLRecordID
    public var fields: [String: GraphQLJSONValue]

    public init(id: GraphQLRecordID, fields: [String: GraphQLJSONValue]) {
        self.id = id
        self.fields = fields
    }

    public var referenceValue: GraphQLJSONValue {
        Self.referenceValue(id)
    }

    public static func referenceValue(_ id: GraphQLRecordID) -> GraphQLJSONValue {
        .object(["$ref": .string(id.rawValue)])
    }

    public func merging(_ other: GraphQLRecord) -> GraphQLRecord {
        var merged = self
        for (key, value) in other.fields {
            merged.fields[key] = value
        }
        return merged
    }
}

public struct GraphQLCacheReadResult: Equatable, Sendable {
    public var record: GraphQLRecord?
    public var missingFields: Set<String>

    public init(record: GraphQLRecord?, missingFields: Set<String>) {
        self.record = record
        self.missingFields = missingFields
    }

    public var isPartial: Bool {
        !missingFields.isEmpty
    }
}

public struct GraphQLOptimisticLayerID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public actor GraphQLMemoryStore {
    private enum LayerChange: Sendable, Equatable {
        case record(GraphQLRecord)
        case evicted
    }

    private struct OptimisticLayer: Sendable, Equatable {
        var id: GraphQLOptimisticLayerID
        var changes: [GraphQLRecordID: LayerChange]
    }

    private var records: [GraphQLRecordID: GraphQLRecord] = [:]
    private var optimisticLayers: [OptimisticLayer] = []
    private var continuations: [UUID: (id: GraphQLRecordID, continuation: AsyncStream<GraphQLRecord?>.Continuation)] = [:]

    public init(records: [GraphQLRecord] = []) {
        for record in records {
            self.records[record.id] = record
        }
    }

    public func read(_ id: GraphQLRecordID) -> GraphQLRecord? {
        effectiveRecord(id)
    }

    public func read(_ id: GraphQLRecordID, requiredFields: Set<String>) -> GraphQLCacheReadResult {
        let record = effectiveRecord(id)
        let fields = Set(record.map { Array($0.fields.keys) } ?? [])
        return GraphQLCacheReadResult(
            record: record,
            missingFields: requiredFields.subtracting(fields)
        )
    }

    public func write(_ record: GraphQLRecord, merge: Bool = true) {
        records[record.id] = mergedRecord(existing: records[record.id], incoming: record, merge: merge)
        notify(id: record.id)
    }

    public func write(_ records: [GraphQLRecord], merge: Bool = true) {
        let changedIDs = Set(records.map(\.id))
        for record in records {
            self.records[record.id] = mergedRecord(existing: self.records[record.id], incoming: record, merge: merge)
        }
        notify(ids: changedIDs)
    }

    public func modify(_ id: GraphQLRecordID, _ update: (inout GraphQLRecord) -> Void) {
        guard var record = records[id] else { return }
        update(&record)
        records[id] = record
        notify(id: id)
    }

    public func appendReferences(
        to id: GraphQLRecordID,
        field: String,
        references: [GraphQLRecordID],
        deduplicate: Bool = true
    ) {
        guard var record = records[id] else { return }
        let existingValues: [GraphQLJSONValue]
        if case .array(let values) = record.fields[field] {
            existingValues = values
        } else {
            existingValues = []
        }

        var values = existingValues
        var seen = Set(existingValues.compactMap(Self.referenceID))
        for reference in references {
            if deduplicate, seen.contains(reference) {
                continue
            }
            values.append(GraphQLRecord.referenceValue(reference))
            seen.insert(reference)
        }
        record.fields[field] = .array(values)
        records[id] = record
        notify(id: id)
    }

    @discardableResult
    public func beginOptimisticLayer(id: GraphQLOptimisticLayerID = GraphQLOptimisticLayerID()) -> GraphQLOptimisticLayerID {
        if !optimisticLayers.contains(where: { $0.id == id }) {
            optimisticLayers.append(OptimisticLayer(id: id, changes: [:]))
        }
        return id
    }

    public func writeOptimistic(_ record: GraphQLRecord, layerID: GraphQLOptimisticLayerID, merge: Bool = true) {
        let index = indexOfLayer(layerID, createIfMissing: true)
        let existing: GraphQLRecord?
        if case .record(let record) = optimisticLayers[index].changes[record.id] {
            existing = record
        } else {
            existing = effectiveRecord(record.id)
        }
        optimisticLayers[index].changes[record.id] = .record(mergedRecord(existing: existing, incoming: record, merge: merge))
        notify(id: record.id)
    }

    public func evict(_ id: GraphQLRecordID) {
        records.removeValue(forKey: id)
        notify(id: id)
    }

    public func evictOptimistic(_ id: GraphQLRecordID, layerID: GraphQLOptimisticLayerID) {
        let index = indexOfLayer(layerID, createIfMissing: true)
        optimisticLayers[index].changes[id] = .evicted
        notify(id: id)
    }

    public func rollbackOptimisticLayer(id: GraphQLOptimisticLayerID) {
        guard let index = optimisticLayers.firstIndex(where: { $0.id == id }) else { return }
        let changedIDs = Set(optimisticLayers[index].changes.keys)
        optimisticLayers.remove(at: index)
        notify(ids: changedIDs)
    }

    public func commitOptimisticLayer(id: GraphQLOptimisticLayerID) {
        guard let index = optimisticLayers.firstIndex(where: { $0.id == id }) else { return }
        let layer = optimisticLayers.remove(at: index)
        for (id, change) in layer.changes {
            switch change {
            case .record(let record):
                records[id] = record
            case .evicted:
                records.removeValue(forKey: id)
            }
        }
        notify(ids: Set(layer.changes.keys))
    }

    public func clear() {
        let ids = Set(records.keys).union(optimisticLayers.flatMap { $0.changes.keys })
        records.removeAll()
        optimisticLayers.removeAll()
        notify(ids: ids)
    }

    public func watch(_ id: GraphQLRecordID) -> AsyncStream<GraphQLRecord?> {
        AsyncStream { continuation in
            let key = UUID()
            continuations[key] = (id, continuation)
            continuation.yield(effectiveRecord(id))
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(key) }
            }
        }
    }

    private func removeContinuation(_ key: UUID) {
        continuations.removeValue(forKey: key)
    }

    private func notify(id: GraphQLRecordID) {
        let value = effectiveRecord(id)
        for watcher in continuations.values where watcher.id == id {
            watcher.continuation.yield(value)
        }
    }

    private func notify(ids: Set<GraphQLRecordID>) {
        for id in ids {
            notify(id: id)
        }
    }

    private func effectiveRecord(_ id: GraphQLRecordID) -> GraphQLRecord? {
        var record = records[id]
        for layer in optimisticLayers {
            guard let change = layer.changes[id] else { continue }
            switch change {
            case .record(let layerRecord):
                record = layerRecord
            case .evicted:
                record = nil
            }
        }
        return record
    }

    private func mergedRecord(existing: GraphQLRecord?, incoming: GraphQLRecord, merge: Bool) -> GraphQLRecord {
        guard merge, let existing else { return incoming }
        return existing.merging(incoming)
    }

    private func indexOfLayer(_ id: GraphQLOptimisticLayerID, createIfMissing: Bool) -> Int {
        if let index = optimisticLayers.firstIndex(where: { $0.id == id }) {
            return index
        }
        precondition(createIfMissing, "Missing optimistic layer \(id.rawValue)")
        optimisticLayers.append(OptimisticLayer(id: id, changes: [:]))
        return optimisticLayers.count - 1
    }

    private static func referenceID(_ value: GraphQLJSONValue) -> GraphQLRecordID? {
        guard case .object(let object) = value,
              case .string(let rawValue) = object["$ref"] else {
            return nil
        }
        return GraphQLRecordID(rawValue: rawValue)
    }
}

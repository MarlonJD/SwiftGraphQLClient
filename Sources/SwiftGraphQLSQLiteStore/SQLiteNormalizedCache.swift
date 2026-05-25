import Foundation
import SwiftGraphQLCache
import SwiftGraphQLClient

public actor SQLiteNormalizedCache: GraphQLOperationCache {
    public let store: SQLiteNormalizedStore
    public let configuration: GraphQLNormalizationConfiguration

    public init(
        store: SQLiteNormalizedStore,
        configuration: GraphQLNormalizationConfiguration = GraphQLNormalizationConfiguration()
    ) {
        self.store = store
        self.configuration = configuration
    }

    public init(
        configuration storeConfiguration: SQLiteNormalizedStoreConfiguration,
        normalizationConfiguration: GraphQLNormalizationConfiguration = GraphQLNormalizationConfiguration()
    ) throws {
        self.store = try SQLiteNormalizedStore(configuration: storeConfiguration)
        self.configuration = normalizationConfiguration
    }

    public func read<Operation: GraphQLOperation>(_ operation: Operation) async throws -> GraphQLCachedResponse {
        let rootID = try rootRecordID(for: operation)
        let requiredFields = rootRequiredFields(from: Operation.selections, fragments: Operation.fragments)
        let result = try await store.read(rootID, requiredFields: requiredFields)
        guard let record = result.record else {
            return GraphQLCachedResponse(
                data: nil,
                isPartial: true,
                missingFields: Array(requiredFields).sorted()
            )
        }

        var missingFields = result.missingFields.map { $0 }.sorted()
        var visited: Set<GraphQLRecordID> = []
        let data = try await denormalizeRecord(record, missingFields: &missingFields, visited: &visited)
        missingFields.append(contentsOf: selectionMissingFields(
            in: data,
            selections: Operation.selections,
            fragments: Operation.fragments,
            path: []
        ))
        missingFields = Array(Set(missingFields)).sorted()
        return GraphQLCachedResponse(
            data: data,
            isPartial: !missingFields.isEmpty,
            missingFields: missingFields
        )
    }

    public func write<Operation: GraphQLOperation>(_ operation: Operation, data: GraphQLJSONValue) async throws {
        let rootID = try rootRecordID(for: operation)
        var records: [GraphQLRecord] = []
        let rootFields: [String: GraphQLJSONValue]

        if case .object(let object) = data {
            rootFields = normalizeFields(object, path: ["ROOT"], records: &records)
        } else {
            rootFields = ["data": data]
        }

        records.append(GraphQLRecord(id: rootID, fields: rootFields))
        try await store.write(records)
    }

    private func rootRecordID<Operation: GraphQLOperation>(for operation: Operation) throws -> GraphQLRecordID {
        GraphQLRecordID(rawValue: "\(configuration.rootRecordPrefix):\(try GraphQLOperationCacheKey.key(for: operation))")
    }

    private func normalizeFields(
        _ fields: [String: GraphQLJSONValue],
        path: [String],
        records: inout [GraphQLRecord]
    ) -> [String: GraphQLJSONValue] {
        var normalized: [String: GraphQLJSONValue] = [:]
        normalized.reserveCapacity(fields.count)

        for (field, value) in fields {
            normalized[field] = normalize(value, path: path + [field], records: &records)
        }
        return normalized
    }

    private func normalize(
        _ value: GraphQLJSONValue,
        path: [String],
        records: inout [GraphQLRecord]
    ) -> GraphQLJSONValue {
        switch value {
        case .array(let values):
            return .array(values.enumerated().map { index, value in
                normalize(value, path: path + [String(index)], records: &records)
            })
        case .object(let object):
            let fields = normalizeFields(object, path: path, records: &records)
            guard let id = recordID(for: fields, path: path) else {
                return .object(fields)
            }
            records.append(GraphQLRecord(id: id, fields: fields))
            return GraphQLRecord.referenceValue(id)
        case .null, .bool, .int, .double, .string:
            return value
        }
    }

    private func recordID(for object: [String: GraphQLJSONValue], path: [String]) -> GraphQLRecordID? {
        let typename = object["__typename"]?.stringValue
        if let typename {
            if let fields = configuration.customKeyFields[typename],
               let key = compositeKey(fields: fields, object: object) {
                return GraphQLRecordID(rawValue: "\(typename):\(key)")
            }

            for field in configuration.objectIDFields {
                if let value = cacheKeyScalar(object[field]) {
                    return GraphQLRecordID(typename: typename, id: value)
                }
            }
        }

        guard configuration.usesPathFallbackForUnkeyedObjects else { return nil }
        let pathKey = path.joined(separator: ".")
        if let typename {
            return GraphQLRecordID(rawValue: "\(typename):$path:\(pathKey)")
        }
        return GraphQLRecordID(rawValue: "$path:\(pathKey)")
    }

    private func compositeKey(fields: [String], object: [String: GraphQLJSONValue]) -> String? {
        let values = fields.compactMap { field in
            cacheKeyScalar(object[field]).map { "\(field)=\($0)" }
        }
        guard values.count == fields.count else { return nil }
        return values.joined(separator: ",")
    }

    private func denormalizeRecord(
        _ record: GraphQLRecord,
        missingFields: inout [String],
        visited: inout Set<GraphQLRecordID>
    ) async throws -> GraphQLJSONValue {
        if visited.contains(record.id) {
            return GraphQLRecord.referenceValue(record.id)
        }
        visited.insert(record.id)
        var fields: [String: GraphQLJSONValue] = [:]
        fields.reserveCapacity(record.fields.count)
        for (field, value) in record.fields {
            fields[field] = try await denormalize(value, path: field, missingFields: &missingFields, visited: &visited)
        }
        visited.remove(record.id)
        return .object(fields)
    }

    private func denormalize(
        _ value: GraphQLJSONValue,
        path: String,
        missingFields: inout [String],
        visited: inout Set<GraphQLRecordID>
    ) async throws -> GraphQLJSONValue {
        switch value {
        case .array(let values):
            var denormalized: [GraphQLJSONValue] = []
            denormalized.reserveCapacity(values.count)
            for (index, value) in values.enumerated() {
                denormalized.append(try await denormalize(
                    value,
                    path: "\(path).\(index)",
                    missingFields: &missingFields,
                    visited: &visited
                ))
            }
            return .array(denormalized)
        case .object(let object):
            if let reference = Self.referenceID(value) {
                guard let record = try await store.read(reference) else {
                    missingFields.append(path)
                    return .null
                }
                return try await denormalizeRecord(record, missingFields: &missingFields, visited: &visited)
            }

            var fields: [String: GraphQLJSONValue] = [:]
            fields.reserveCapacity(object.count)
            for (field, value) in object {
                fields[field] = try await denormalize(
                    value,
                    path: "\(path).\(field)",
                    missingFields: &missingFields,
                    visited: &visited
                )
            }
            return .object(fields)
        case .null, .bool, .int, .double, .string:
            return value
        }
    }

    private static func referenceID(_ value: GraphQLJSONValue) -> GraphQLRecordID? {
        guard case .object(let object) = value,
              case .string(let rawValue) = object["$ref"] else {
            return nil
        }
        return GraphQLRecordID(rawValue: rawValue)
    }

    private func rootRequiredFields(
        from selections: [GraphQLSelection],
        fragments: [String: [GraphQLSelection]]
    ) -> Set<String> {
        var fields: Set<String> = []
        for selection in selections {
            switch selection {
            case .field(_, let responseName, _):
                fields.insert(responseName)
            case .inlineFragment(_, let selections):
                fields.formUnion(rootRequiredFields(from: selections, fragments: fragments))
            case .fragmentSpread(let name):
                fields.formUnion(rootRequiredFields(from: fragments[name] ?? [], fragments: fragments))
            }
        }
        return fields
    }

    private func selectionMissingFields(
        in value: GraphQLJSONValue,
        selections: [GraphQLSelection],
        fragments: [String: [GraphQLSelection]],
        path: [String]
    ) -> [String] {
        guard !selections.isEmpty else { return [] }
        switch value {
        case .object(let object):
            var missing: [String] = []
            for selection in selections {
                switch selection {
                case .field(_, let responseName, let nestedSelections):
                    let fieldPath = path + [responseName]
                    guard let fieldValue = object[responseName] else {
                        missing.append(fieldPath.joined(separator: "."))
                        continue
                    }
                    missing.append(contentsOf: selectionMissingFields(
                        in: fieldValue,
                        selections: nestedSelections,
                        fragments: fragments,
                        path: fieldPath
                    ))
                case .inlineFragment(_, let nestedSelections):
                    missing.append(contentsOf: selectionMissingFields(
                        in: value,
                        selections: nestedSelections,
                        fragments: fragments,
                        path: path
                    ))
                case .fragmentSpread(let name):
                    missing.append(contentsOf: selectionMissingFields(
                        in: value,
                        selections: fragments[name] ?? [],
                        fragments: fragments,
                        path: path
                    ))
                }
            }
            return missing
        case .array(let values):
            return values.enumerated().flatMap { index, value in
                selectionMissingFields(in: value, selections: selections, fragments: fragments, path: path + [String(index)])
            }
        case .null, .bool, .int, .double, .string:
            guard selections.isEmpty else {
                return [path.joined(separator: ".")]
            }
            return []
        }
    }

    private func cacheKeyScalar(_ value: GraphQLJSONValue?) -> String? {
        switch value {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null, .array, .object, .none:
            return nil
        }
    }
}

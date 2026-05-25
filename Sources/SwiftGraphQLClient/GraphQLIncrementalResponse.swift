import Foundation

public struct GraphQLIncrementalPatch: Sendable, Equatable {
    public var label: String?
    public var path: [GraphQLError.PathComponent]?
    public var data: GraphQLJSONValue?
    public var items: [GraphQLJSONValue]?
    public var errors: [GraphQLError]

    public init(
        label: String? = nil,
        path: [GraphQLError.PathComponent]? = nil,
        data: GraphQLJSONValue? = nil,
        items: [GraphQLJSONValue]? = nil,
        errors: [GraphQLError] = []
    ) {
        self.label = label
        self.path = path
        self.data = data
        self.items = items
        self.errors = errors
    }
}

public struct GraphQLIncrementalResult<Data: Sendable>: Sendable {
    public var data: Data?
    public var errors: [GraphQLError]
    public var patches: [GraphQLIncrementalPatch]
    public var hasNext: Bool?

    public init(
        data: Data?,
        errors: [GraphQLError] = [],
        patches: [GraphQLIncrementalPatch] = [],
        hasNext: Bool? = nil
    ) {
        self.data = data
        self.errors = errors
        self.patches = patches
        self.hasNext = hasNext
    }
}

public enum GraphQLHTTPMultipartResponseParser {
    public static func responseParts(data: Data, contentType: String?) -> [Data] {
        guard let boundary = boundary(from: contentType) else {
            return data.isEmpty ? [] : [data]
        }
        let text = String(decoding: data, as: UTF8.self)
        return text
            .components(separatedBy: "--\(boundary)")
            .compactMap { part -> Data? in
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != "--" else { return nil }
                let withoutClosing = trimmed.hasSuffix("--") ? String(trimmed.dropLast(2)) : trimmed
                let separators = ["\r\n\r\n", "\n\n"]
                let body: String
                if let separator = separators.first(where: { withoutClosing.contains($0) }),
                   let range = withoutClosing.range(of: separator) {
                    body = String(withoutClosing[range.upperBound...])
                } else {
                    body = withoutClosing
                }
                let bodyText = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return bodyText.isEmpty ? nil : Data(bodyText.utf8)
            }
    }

    private static func boundary(from contentType: String?) -> String? {
        guard let contentType else { return nil }
        for rawPart in contentType.components(separatedBy: ";") {
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard part.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(part.dropFirst("boundary=".count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return nil
    }
}

public enum GraphQLIncrementalMergeError: LocalizedError, Sendable, Equatable {
    case missingBaseResponse
    case invalidPath([GraphQLError.PathComponent])
    case expectedObject(path: [GraphQLError.PathComponent])
    case expectedArray(path: [GraphQLError.PathComponent])

    public var errorDescription: String? {
        switch self {
        case .missingBaseResponse:
            return "Cannot apply an incremental GraphQL patch before a base response exists."
        case .invalidPath(let path):
            return "The incremental GraphQL patch path is invalid: \(path.description)."
        case .expectedObject(let path):
            return "The incremental GraphQL patch expected an object at path: \(path.description)."
        case .expectedArray(let path):
            return "The incremental GraphQL patch expected an array at path: \(path.description)."
        }
    }
}

public enum GraphQLIncrementalPatchMerger {
    public static func applying(
        patches: [GraphQLIncrementalPatch],
        to base: GraphQLJSONValue?
    ) throws -> GraphQLJSONValue {
        guard var base else {
            if patches.isEmpty {
                throw GraphQLIncrementalMergeError.missingBaseResponse
            }
            throw GraphQLIncrementalMergeError.missingBaseResponse
        }
        try apply(patches: patches, to: &base)
        return base
    }

    public static func apply(
        patches: [GraphQLIncrementalPatch],
        to base: inout GraphQLJSONValue
    ) throws {
        for patch in patches {
            try apply(patch, to: &base)
        }
    }

    public static func apply(
        _ patch: GraphQLIncrementalPatch,
        to base: inout GraphQLJSONValue
    ) throws {
        let path = patch.path ?? []
        if let data = patch.data {
            try merge(data, into: &base, at: path)
        }
        if let items = patch.items {
            try insert(items: items, into: &base, at: path)
        }
    }

    private static func merge(
        _ data: GraphQLJSONValue,
        into value: inout GraphQLJSONValue,
        at path: [GraphQLError.PathComponent]
    ) throws {
        guard let head = path.first else {
            value = value.mergingObjectFields(from: data)
            return
        }
        switch head {
        case .string(let key):
            guard case .object(var object) = value else {
                throw GraphQLIncrementalMergeError.expectedObject(path: path)
            }
            if object[key] == nil {
                object[key] = .null
            }
            try merge(data, into: &object[key]!, at: Array(path.dropFirst()))
            value = .object(object)
        case .int(let index):
            guard case .array(var array) = value, array.indices.contains(index) else {
                throw GraphQLIncrementalMergeError.expectedArray(path: path)
            }
            try merge(data, into: &array[index], at: Array(path.dropFirst()))
            value = .array(array)
        }
    }

    private static func insert(
        items: [GraphQLJSONValue],
        into value: inout GraphQLJSONValue,
        at path: [GraphQLError.PathComponent]
    ) throws {
        if let last = path.last, case .int(let index) = last {
            var parentPath = path
            parentPath.removeLast()
            try insert(items: items, into: &value, arrayPath: parentPath, index: index)
        } else {
            try insert(items: items, into: &value, arrayPath: path, index: nil)
        }
    }

    private static func insert(
        items: [GraphQLJSONValue],
        into value: inout GraphQLJSONValue,
        arrayPath: [GraphQLError.PathComponent],
        index: Int?
    ) throws {
        guard let head = arrayPath.first else {
            guard case .array(var array) = value else {
                throw GraphQLIncrementalMergeError.expectedArray(path: arrayPath)
            }
            let insertionIndex = min(max(index ?? array.count, 0), array.count)
            array.insert(contentsOf: items, at: insertionIndex)
            value = .array(array)
            return
        }
        switch head {
        case .string(let key):
            guard case .object(var object) = value else {
                throw GraphQLIncrementalMergeError.expectedObject(path: arrayPath)
            }
            guard var nested = object[key] else {
                throw GraphQLIncrementalMergeError.invalidPath(arrayPath)
            }
            try insert(items: items, into: &nested, arrayPath: Array(arrayPath.dropFirst()), index: index)
            object[key] = nested
            value = .object(object)
        case .int(let elementIndex):
            guard case .array(var array) = value, array.indices.contains(elementIndex) else {
                throw GraphQLIncrementalMergeError.expectedArray(path: arrayPath)
            }
            try insert(items: items, into: &array[elementIndex], arrayPath: Array(arrayPath.dropFirst()), index: index)
            value = .array(array)
        }
    }
}

struct GraphQLRawResponseEnvelope: Decodable {
    let data: GraphQLJSONValue?
    let errors: [GraphQLError]?
    let incremental: [GraphQLRawIncrementalPatch]?
    let hasNext: Bool?
}

struct GraphQLRawIncrementalPatch: Decodable {
    let label: String?
    let path: [GraphQLError.PathComponent]?
    let data: GraphQLJSONValue?
    let items: [GraphQLJSONValue]?
    let errors: [GraphQLError]?

    var patch: GraphQLIncrementalPatch {
        GraphQLIncrementalPatch(
            label: label,
            path: path,
            data: data,
            items: items,
            errors: errors ?? []
        )
    }
}

private extension GraphQLJSONValue {
    func mergingObjectFields(from other: GraphQLJSONValue) -> GraphQLJSONValue {
        guard case .object(var object) = self,
              case .object(let incoming) = other else {
            return other
        }
        for (key, value) in incoming {
            object[key] = object[key]?.mergingObjectFields(from: value) ?? value
        }
        return .object(object)
    }
}

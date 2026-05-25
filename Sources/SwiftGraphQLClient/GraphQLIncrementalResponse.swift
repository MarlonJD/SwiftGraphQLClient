import Foundation

public struct GraphQLIncrementalPatch: Sendable, Equatable {
    public var label: String?
    public var path: [GraphQLError.PathComponent]?
    public var data: GraphQLJSONValue?
    public var errors: [GraphQLError]

    public init(
        label: String? = nil,
        path: [GraphQLError.PathComponent]? = nil,
        data: GraphQLJSONValue? = nil,
        errors: [GraphQLError] = []
    ) {
        self.label = label
        self.path = path
        self.data = data
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
    let errors: [GraphQLError]?

    var patch: GraphQLIncrementalPatch {
        GraphQLIncrementalPatch(
            label: label,
            path: path,
            data: data,
            errors: errors ?? []
        )
    }
}

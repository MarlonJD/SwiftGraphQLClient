import Foundation
import SwiftGraphQLClient

public struct GraphQLUpload: Sendable, Equatable {
    public var data: Data
    public var filename: String
    public var contentType: String

    public init(data: Data, filename: String, contentType: String = "application/octet-stream") {
        self.data = data
        self.filename = filename
        self.contentType = contentType
    }
}

extension GraphQLUpload: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

public struct GraphQLMultipartFile: Sendable, Equatable {
    public var fieldName: String
    public var upload: GraphQLUpload

    public init(fieldName: String, upload: GraphQLUpload) {
        self.fieldName = fieldName
        self.upload = upload
    }
}

public struct GraphQLMultipartOperationPayload: Sendable, Equatable {
    public var operations: GraphQLJSONValue
    public var fileMap: [String: [String]]
    public var files: [GraphQLMultipartFile]

    public var hasUploads: Bool {
        !files.isEmpty
    }

    public init(
        operations: GraphQLJSONValue,
        fileMap: [String: [String]],
        files: [GraphQLMultipartFile]
    ) {
        self.operations = operations
        self.fileMap = fileMap
        self.files = files
    }
}

public struct GraphQLUploadRequestEncoder: GraphQLMultipartRequestEncoding {
    public var boundary: String?

    public init(boundary: String? = nil) {
        self.boundary = boundary
    }

    public func multipartRequestBody<Operation: GraphQLOperation>(
        for operation: Operation
    ) throws -> GraphQLMultipartRequestBody? {
        let payload = try GraphQLUploadVariableEncoder.operationPayload(for: operation)
        guard payload.hasUploads else { return nil }

        let multipart: GraphQLMultipartBody
        if let boundary {
            multipart = try GraphQLMultipartBuilder.build(
                operations: payload.operations,
                fileMap: payload.fileMap,
                files: payload.files,
                boundary: boundary
            )
        } else {
            multipart = try GraphQLMultipartBuilder.build(
                operations: payload.operations,
                fileMap: payload.fileMap,
                files: payload.files
            )
        }
        return GraphQLMultipartRequestBody(body: multipart.body, contentType: multipart.contentType)
    }
}

public enum GraphQLUploadVariableEncoder {
    public static func operationPayload<Operation: GraphQLOperation>(
        for operation: Operation
    ) throws -> GraphQLMultipartOperationPayload {
        let variables = try GraphQLJSONEncoder.variableObject(from: operation.variables)
        var operations: [String: GraphQLJSONValue] = [
            "query": .string(Operation.document),
            "operationName": .string(Operation.operationName)
        ]
        if let variables {
            operations["variables"] = variables
        }

        var collector = GraphQLUploadCollector()
        collector.collect(operation.variables, path: "variables")

        var fileMap: [String: [String]] = [:]
        var files: [GraphQLMultipartFile] = []
        for (index, match) in collector.matches.enumerated() {
            let fieldName = String(index)
            fileMap[fieldName] = [match.path]
            files.append(GraphQLMultipartFile(fieldName: fieldName, upload: match.upload))
        }

        return GraphQLMultipartOperationPayload(
            operations: .object(operations),
            fileMap: fileMap,
            files: files
        )
    }
}

public struct GraphQLMultipartBody: Sendable, Equatable {
    public var boundary: String
    public var body: Data
    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public init(boundary: String, body: Data) {
        self.boundary = boundary
        self.body = body
    }
}

public enum GraphQLMultipartBuilder {
    public static func build(
        operations: GraphQLJSONValue,
        fileMap: [String: [String]],
        files: [GraphQLMultipartFile],
        boundary: String = "SwiftGraphQLClient-\(UUID().uuidString)"
    ) throws -> GraphQLMultipartBody {
        var body = Data()
        try appendJSONPart(name: "operations", value: operations, boundary: boundary, to: &body)
        try appendJSONPart(name: "map", value: .object(fileMap.mapValues { .array($0.map(GraphQLJSONValue.string)) }), boundary: boundary, to: &body)
        for file in files {
            appendFilePart(file, boundary: boundary, to: &body)
        }
        append("--\(boundary)--\r\n", to: &body)
        return GraphQLMultipartBody(boundary: boundary, body: body)
    }

    private static func appendJSONPart(name: String, value: GraphQLJSONValue, boundary: String, to body: inout Data) throws {
        append("--\(boundary)\r\n", to: &body)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n", to: &body)
        append("Content-Type: application/json\r\n\r\n", to: &body)
        body.append(try JSONEncoder().encode(value))
        append("\r\n", to: &body)
    }

    private static func appendFilePart(_ file: GraphQLMultipartFile, boundary: String, to body: inout Data) {
        append("--\(boundary)\r\n", to: &body)
        append("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.upload.filename)\"\r\n", to: &body)
        append("Content-Type: \(file.upload.contentType)\r\n\r\n", to: &body)
        body.append(file.upload.data)
        append("\r\n", to: &body)
    }

    private static func append(_ string: String, to body: inout Data) {
        body.append(Data(string.utf8))
    }
}

private struct GraphQLUploadMatch {
    var path: String
    var upload: GraphQLUpload
}

private struct GraphQLUploadCollector {
    private(set) var matches: [GraphQLUploadMatch] = []

    mutating func collect(_ value: Any, path: String) {
        if let upload = value as? GraphQLUpload {
            matches.append(GraphQLUploadMatch(path: path, upload: upload))
            return
        }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first else { return }
            collect(wrapped.value, path: path)
            return
        }

        if isGraphQLNullable(value) {
            guard let wrapped = mirror.children.first, wrapped.label == "some" else { return }
            collect(wrapped.value, path: path)
            return
        }

        if isScalarLike(value) {
            return
        }

        switch mirror.displayStyle {
        case .collection, .set:
            for (index, child) in mirror.children.enumerated() {
                collect(child.value, path: "\(path).\(index)")
            }
        case .dictionary:
            collectDictionary(mirror, path: path)
        case .struct, .class, .tuple:
            for child in mirror.children {
                guard let label = child.label else { continue }
                collect(child.value, path: "\(path).\(cleanLabel(label))")
            }
        default:
            return
        }
    }

    private mutating func collectDictionary(_ mirror: Mirror, path: String) {
        for child in mirror.children {
            let pair = Mirror(reflecting: child.value)
            var key: String?
            var value: Any?
            for element in pair.children {
                switch element.label {
                case "key":
                    key = element.value as? String
                case "value":
                    value = element.value
                default:
                    break
                }
            }
            if let key, let value {
                collect(value, path: "\(path).\(key)")
            }
        }
    }

    private func cleanLabel(_ label: String) -> String {
        label.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func isGraphQLNullable(_ value: Any) -> Bool {
        String(reflecting: type(of: value)).contains("GraphQLNullable<")
    }

    private func isScalarLike(_ value: Any) -> Bool {
        value is String ||
            value is Bool ||
            value is Int ||
            value is Int8 ||
            value is Int16 ||
            value is Int32 ||
            value is Int64 ||
            value is UInt ||
            value is UInt8 ||
            value is UInt16 ||
            value is UInt32 ||
            value is UInt64 ||
            value is Float ||
            value is Double ||
            value is Decimal ||
            value is Data ||
            value is Date ||
            value is URL ||
            value is GraphQLID ||
            value is GraphQLJSONValue
    }
}

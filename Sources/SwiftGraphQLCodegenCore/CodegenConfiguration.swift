import Foundation

public struct CodegenConfiguration: Equatable, Sendable {
    public var namespace: String
    public var schemaSearchPaths: [String]
    public var operationSearchPaths: [String]
    public var outputPath: String
    public var scalarMappings: [String: String]

    public init(
        namespace: String,
        schemaSearchPaths: [String],
        operationSearchPaths: [String],
        outputPath: String,
        scalarMappings: [String: String] = [:]
    ) {
        self.namespace = namespace
        self.schemaSearchPaths = schemaSearchPaths
        self.operationSearchPaths = operationSearchPaths
        self.outputPath = outputPath
        self.scalarMappings = scalarMappings
    }

    public static func load(from url: URL) throws -> CodegenConfiguration {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "json" {
            return try loadLegacyJSON(from: data)
        }
        let text = String(decoding: data, as: UTF8.self)
        return try loadYAMLSubset(from: text)
    }

    private static func loadLegacyJSON(from data: Data) throws -> CodegenConfiguration {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodegenError.invalidConfiguration("Expected a JSON object.")
        }
        let namespace = object["schemaNamespace"] as? String ?? "GraphQLAPI"
        let input = object["input"] as? [String: Any]
        let output = object["output"] as? [String: Any]
        let schemaTypes = output?["schemaTypes"] as? [String: Any]
        return CodegenConfiguration(
            namespace: namespace,
            schemaSearchPaths: input?["schemaSearchPaths"] as? [String] ?? [],
            operationSearchPaths: input?["operationSearchPaths"] as? [String] ?? [],
            outputPath: schemaTypes?["path"] as? String ?? "./GeneratedGraphQL",
            scalarMappings: object["scalarMappings"] as? [String: String] ?? object["scalars"] as? [String: String] ?? [:]
        )
    }

    private static func loadYAMLSubset(from text: String) throws -> CodegenConfiguration {
        var namespace = "GraphQLAPI"
        var schemaSearchPaths: [String] = []
        var operationSearchPaths: [String] = []
        var outputPath: String?
        var scalarMappings: [String: String] = [:]
        var listKey: String?
        var sectionStack: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard !withoutComment.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indent = withoutComment.prefix { $0 == " " }.count
            let line = withoutComment.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("- ") {
                let value = cleanScalar(String(line.dropFirst(2)))
                switch listKey {
                case "schema", "schemas", "schemaSearchPaths":
                    schemaSearchPaths.append(value)
                case "operations", "operationSearchPaths":
                    operationSearchPaths.append(value)
                default:
                    break
                }
                continue
            }

            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon])
                let value = cleanScalar(String(line[line.index(after: colon)...]))
                if indent > 0,
                   sectionStack.contains("scalars") || sectionStack.contains("scalarMappings") || sectionStack.contains("customScalars") {
                    if !value.isEmpty {
                        scalarMappings[key] = value
                    }
                    listKey = nil
                    continue
                }

                if indent == 0 {
                    sectionStack = [key]
                } else {
                    while sectionStack.count > indent / 2 + 1 {
                        sectionStack.removeLast()
                    }
                    sectionStack.append(key)
                }

                switch key {
                case "namespace", "schemaNamespace":
                    if !value.isEmpty { namespace = value }
                    listKey = nil
                case "schema", "schemas", "schemaSearchPaths", "operations", "operationSearchPaths":
                    if value.isEmpty {
                        listKey = key
                    } else if key.contains("operation") || key == "operations" {
                        operationSearchPaths.append(value)
                        listKey = nil
                    } else {
                        schemaSearchPaths.append(value)
                        listKey = nil
                    }
                case "output":
                    if !value.isEmpty { outputPath = value }
                    listKey = nil
                case "scalars", "scalarMappings", "customScalars":
                    listKey = nil
                case "path":
                    if sectionStack.contains("output") || sectionStack.contains("schemaTypes") {
                        outputPath = value
                    }
                    listKey = nil
                default:
                    listKey = nil
                }
            }
        }

        guard !schemaSearchPaths.isEmpty else {
            throw CodegenError.invalidConfiguration("Missing schema search paths.")
        }
        guard !operationSearchPaths.isEmpty else {
            throw CodegenError.invalidConfiguration("Missing operation search paths.")
        }

        return CodegenConfiguration(
            namespace: namespace,
            schemaSearchPaths: schemaSearchPaths,
            operationSearchPaths: operationSearchPaths,
            outputPath: outputPath ?? "./GeneratedGraphQL",
            scalarMappings: scalarMappings
        )
    }

    private static func cleanScalar(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }
}

public enum CodegenError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case invalidSchema(String)
    case invalidOperation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .invalidSchema(let message), .invalidOperation(let message):
            return message
        }
    }
}

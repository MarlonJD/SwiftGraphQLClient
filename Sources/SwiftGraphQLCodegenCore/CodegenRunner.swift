import Foundation
import SwiftGraphQLClient

public enum CodegenRunner {
    public static func generate(configURL: URL) throws -> URL {
        try generate(configURL: configURL, outputOverride: nil)
    }

    public static func generate(configURL: URL, outputOverride: String?) throws -> URL {
        let configuration = try CodegenConfiguration.load(from: configURL)
        let baseURL = configURL.deletingLastPathComponent()
        let schemaURLs = try FileSystemSearch.resolve(patterns: configuration.schemaSearchPaths, relativeTo: baseURL)
        let operationURLs = try FileSystemSearch.resolve(patterns: configuration.operationSearchPaths, relativeTo: baseURL)

        let schemaText = try schemaURLs.map { try String(contentsOf: $0) }.joined(separator: "\n")
        let operationTexts = try operationURLs.map { try String(contentsOf: $0) }
        let schema = try GraphQLSchemaParser.parse(schemaText)
        let documents = try GraphQLOperationParser.parseDocuments(operationTexts)
        let swift = try SwiftCodeGenerator().generate(
            namespace: configuration.namespace,
            schema: schema,
            documents: documents,
            scalarMappings: configuration.scalarMappings
        )

        let outputURL: URL
        let outputPath = outputOverride ?? configuration.outputPath
        if outputPath.hasPrefix("/") {
            outputURL = URL(fileURLWithPath: outputPath)
        } else {
            outputURL = baseURL.appendingPathComponent(outputPath)
        }
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let fileURL = outputURL.appendingPathComponent("\(configuration.namespace).graphql.swift")
        try swift.write(to: fileURL, atomically: true, encoding: .utf8)
        if let manifestPath = configuration.operationManifestPath {
            _ = try generateOperationManifest(configURL: configURL, outputOverride: manifestPath)
        }
        return fileURL
    }

    public static func generateOperationManifest(
        configURL: URL,
        outputOverride: String? = nil
    ) throws -> URL {
        let configuration = try CodegenConfiguration.load(from: configURL)
        let baseURL = configURL.deletingLastPathComponent()
        let operationURLs = try FileSystemSearch.resolve(patterns: configuration.operationSearchPaths, relativeTo: baseURL)
        let operationTexts = try operationURLs.map { try String(contentsOf: $0) }
        let documents = try GraphQLOperationParser.parseDocuments(operationTexts)
        let manifest = OperationManifest(
            operations: documents.operations
                .sorted { $0.name < $1.name }
                .map { operation in
                    let body = documentSource(for: operation, fragments: documents.fragments)
                    return OperationManifest.Operation(
                        id: GraphQLOperationDocumentHasher.sha256(body),
                        body: body,
                        name: operation.name,
                        type: operation.kind.rawValue
                    )
                }
        )
        let outputPath = outputOverride ?? configuration.operationManifestPath ?? "operation-manifest.json"
        let outputURL = outputPath.hasPrefix("/")
            ? URL(fileURLWithPath: outputPath)
            : baseURL.appendingPathComponent(outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: outputURL)
        return outputURL
    }

    private static func documentSource(
        for operation: GraphQLOperationDefinition,
        fragments: [String: GraphQLFragmentDefinition]
    ) -> String {
        var emitted = Set<String>()
        var sources = [operation.source]
        func appendFragments(_ names: Set<String>) {
            for name in names.sorted() where !emitted.contains(name) {
                guard let fragment = fragments[name] else { continue }
                emitted.insert(name)
                sources.append(fragment.source)
                appendFragments(fragment.fragmentSpreads)
            }
        }
        appendFragments(operation.fragmentSpreads)
        return sources.joined(separator: "\n\n")
    }
}

private struct OperationManifest: Encodable {
    struct Operation: Encodable {
        let id: String
        let body: String
        let name: String
        let type: String
    }

    let format = "apollo-persisted-query-manifest"
    let version = 1
    let operations: [Operation]
}

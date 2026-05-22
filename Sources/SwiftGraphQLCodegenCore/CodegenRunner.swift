import Foundation

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
            documents: documents
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
        return fileURL
    }
}

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

    @discardableResult
    public static func publishOperationManifest(
        manifestURL: URL,
        endpointURL: URL,
        headers: [String: String] = [:]
    ) throws -> Int {
        try OperationManifestPublisher.publish(
            manifestURL: manifestURL,
            endpointURL: endpointURL,
            headers: headers
        )
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

public enum OperationManifestPublisher {
    public static func request(
        manifestData: Data,
        endpointURL: URL,
        headers: [String: String] = [:]
    ) -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = manifestData
        return request
    }

    @discardableResult
    public static func publish(
        manifestURL: URL,
        endpointURL: URL,
        headers: [String: String] = [:]
    ) throws -> Int {
        let manifestData = try Data(contentsOf: manifestURL)
        let request = request(manifestData: manifestData, endpointURL: endpointURL, headers: headers)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Int, Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                result = .failure(CodegenError.invalidConfiguration("Operation manifest endpoint returned an invalid response."))
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                result = .failure(CodegenError.invalidConfiguration("Operation manifest endpoint returned HTTP \(httpResponse.statusCode). \(body)"))
                return
            }
            result = .success(httpResponse.statusCode)
        }.resume()
        semaphore.wait()
        return try result?.get() ?? 0
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

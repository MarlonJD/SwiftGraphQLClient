import Foundation
import SwiftGraphQLCodegenCore

enum SwiftGraphQLCodegenCLI {
    static func main(arguments: [String]) -> Int32 {
        guard let command = arguments.dropFirst().first else {
            printHelp()
            return 0
        }

        switch command {
        case "generate":
            guard let configPath = value(after: "--config", in: arguments) else {
                fputs("Missing --config path.\n", stderr)
                return 64
            }
            do {
                let outputURL = try CodegenRunner.generate(
                    configURL: URL(fileURLWithPath: configPath),
                    outputOverride: value(after: "--output", in: arguments)
                )
                print("Generated \(outputURL.path)")
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }
        case "generate-operation-manifest":
            guard let configPath = value(after: "--config", in: arguments) else {
                fputs("Missing --config path.\n", stderr)
                return 64
            }
            do {
                let outputURL = try CodegenRunner.generateOperationManifest(
                    configURL: URL(fileURLWithPath: configPath),
                    outputOverride: value(after: "--output", in: arguments)
                )
                print("Generated \(outputURL.path)")
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }
        case "introspect":
            guard let endpoint = value(after: "--endpoint", in: arguments) else {
                fputs("Missing --endpoint URL.\n", stderr)
                return 64
            }
            guard let outputPath = value(after: "--output", in: arguments) else {
                fputs("Missing --output path.\n", stderr)
                return 64
            }
            do {
                guard let endpointURL = URL(string: endpoint) else {
                    throw CodegenError.invalidConfiguration("Invalid --endpoint URL.")
                }
                let headers = try parseHeaders(values(after: "--header", in: arguments))
                let data = try fetchIntrospection(endpointURL: endpointURL, headers: headers)
                let schema = try GraphQLIntrospection.schemaSDL(from: data)
                let outputURL = URL(fileURLWithPath: outputPath)
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try schema.write(to: outputURL, atomically: true, encoding: .utf8)
                print("Wrote \(outputURL.path)")
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }
        case "--help", "-h", "help":
            printHelp()
            return 0
        default:
            fputs("Unknown command: \(command)\n", stderr)
            printHelp()
            return 64
        }
    }

    private static func printHelp() {
        print("""
        OVERVIEW: SwiftGraphQLClient code generation tool

        USAGE:
          swift-graphql introspect --endpoint URL [--header "Name: Value"] --output schema.graphqls
          swift-graphql generate --config swift-graphql-codegen.yml [--output GeneratedGraphQL]
          swift-graphql generate-operation-manifest --config swift-graphql-codegen.yml [--output operation-manifest.json]

        The swift-graphql-codegen executable remains available as a compatibility alias.
        """)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let nextIndex = arguments.index(after: index)
        guard nextIndex < arguments.endIndex else { return nil }
        return arguments[nextIndex]
    }

    private static func values(after flag: String, in arguments: [String]) -> [String] {
        var values: [String] = []
        for index in arguments.indices where arguments[index] == flag {
            let nextIndex = arguments.index(after: index)
            if nextIndex < arguments.endIndex {
                values.append(arguments[nextIndex])
            }
        }
        return values
    }

    private static func parseHeaders(_ values: [String]) throws -> [String: String] {
        var headers: [String: String] = [:]
        for value in values {
            guard let colon = value.firstIndex(of: ":") else {
                throw CodegenError.invalidConfiguration("Invalid --header value. Use \"Name: Value\".")
            }
            let name = String(value[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let headerValue = String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw CodegenError.invalidConfiguration("Invalid --header value. Header name cannot be empty.")
            }
            headers[name] = headerValue
        }
        return headers
    }

    private static func fetchIntrospection(endpointURL: URL, headers: [String: String]) throws -> Data {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/graphql-response+json, application/json;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(IntrospectionRequestBody(query: GraphQLIntrospection.query))

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                result = .failure(CodegenError.invalidConfiguration("Introspection endpoint returned HTTP \(httpResponse.statusCode)."))
                return
            }
            guard let data else {
                result = .failure(CodegenError.invalidConfiguration("Introspection endpoint returned no data."))
                return
            }
            result = .success(data)
        }.resume()
        semaphore.wait()
        return try result?.get() ?? Data()
    }
}

private struct IntrospectionRequestBody: Encodable {
    let query: String
}

exit(SwiftGraphQLCodegenCLI.main(arguments: CommandLine.arguments))

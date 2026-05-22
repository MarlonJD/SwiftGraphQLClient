import Foundation
import PackagePlugin

@main
struct SwiftGraphQLCodegenPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let config = firstExistingConfig(context: context, target: target) else {
            return []
        }

        let tool = try context.tool(named: "swift-graphql-codegen")
        let outputDirectory = context.pluginWorkDirectory.appending("GeneratedGraphQL-\(target.name)")
        return [
            .prebuildCommand(
                displayName: "Generate GraphQL Swift for \(target.name)",
                executable: tool.path,
                arguments: [
                    "generate",
                    "--config",
                    config.string,
                    "--output",
                    outputDirectory.string
                ],
                outputFilesDirectory: outputDirectory
            )
        ]
    }

    private func firstExistingConfig(context: PluginContext, target: Target) -> Path? {
        [
            target.directory.appending("swift-graphql-codegen.yml"),
            target.directory.appending("swift-graphql-codegen.yaml"),
            context.package.directory.appending("swift-graphql-codegen.yml"),
            context.package.directory.appending("swift-graphql-codegen.yaml")
        ].first { FileManager.default.fileExists(atPath: $0.string) }
    }
}

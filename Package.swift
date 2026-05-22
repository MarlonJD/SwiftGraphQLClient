// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SwiftGraphQLClient",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "SwiftGraphQLClient", targets: ["SwiftGraphQLClient"]),
        .library(name: "SwiftGraphQLCache", targets: ["SwiftGraphQLCache"]),
        .library(name: "SwiftGraphQLSQLiteStore", targets: ["SwiftGraphQLSQLiteStore"]),
        .library(name: "SwiftGraphQLUpload", targets: ["SwiftGraphQLUpload"]),
        .library(name: "SwiftGraphQLWebSocket", targets: ["SwiftGraphQLWebSocket"]),
        .library(name: "SwiftGraphQLAppSync", targets: ["SwiftGraphQLAppSync"]),
        .executable(name: "swift-graphql-codegen", targets: ["swift-graphql-codegen"]),
        .plugin(name: "SwiftGraphQLCodegenPlugin", targets: ["SwiftGraphQLCodegenPlugin"])
    ],
    targets: [
        .target(name: "SwiftGraphQLClient"),
        .target(
            name: "SwiftGraphQLCache",
            dependencies: ["SwiftGraphQLClient"]
        ),
        .target(
            name: "SwiftGraphQLSQLiteStore",
            dependencies: ["SwiftGraphQLCache", "SwiftGraphQLClient"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "SwiftGraphQLUpload",
            dependencies: ["SwiftGraphQLClient"]
        ),
        .target(
            name: "SwiftGraphQLWebSocket",
            dependencies: ["SwiftGraphQLClient"]
        ),
        .target(
            name: "SwiftGraphQLAppSync",
            dependencies: ["SwiftGraphQLClient", "SwiftGraphQLWebSocket"]
        ),
        .target(
            name: "SwiftGraphQLCodegenCore",
            dependencies: ["SwiftGraphQLClient"]
        ),
        .executableTarget(
            name: "swift-graphql-codegen",
            dependencies: ["SwiftGraphQLCodegenCore"]
        ),
        .plugin(
            name: "SwiftGraphQLCodegenPlugin",
            capability: .buildTool(),
            dependencies: ["swift-graphql-codegen"]
        ),
        .testTarget(
            name: "SwiftGraphQLClientTests",
            dependencies: ["SwiftGraphQLClient", "SwiftGraphQLCodegenCore", "SwiftGraphQLUpload", "SwiftGraphQLWebSocket", "SwiftGraphQLAppSync", "SwiftGraphQLCache", "SwiftGraphQLSQLiteStore"]
        )
    ]
)

# SwiftGraphQLClient

SwiftGraphQLClient is a SwiftPM GraphQL toolkit built as Kindred's typed GraphQL runtime and codegen stack.

Current status: first runtime and Kindred-focused codegen milestones are in place and tested. The package has product scaffolding for the intended modules, while the implemented surface is concentrated on the core HTTP client, GraphQL input/runtime types, auth headers, GraphQL error parsing, refresh retry coordination, normalized cache integration, multipart upload requests, subscription transports, introspection SDL export, and native Swift operation generation.

The codegen CLI now has an MVP `generate` command. It can read the current YAML config or a legacy JSON config, parse schema scalars/enums/input objects/object fields plus operation and fragment selections, and emit operation structs, input objects, fragments, scalar aliases, and nested `Codable` response `Data` models under the configured namespace.

## Products

- `SwiftGraphQLClient`: typed operation protocols, HTTP runtime, auth providers, errors, scalars.
- `SwiftGraphQLCache`: in-memory normalized record store with watchers, partial-read detection, optimistic layers, and cursor-list reference helpers.
- `SwiftGraphQLSQLiteStore`: SQLite normalized record persistence.
- `SwiftGraphQLUpload`: `GraphQLUpload`, multipart request body builder, and upload-aware request encoder.
- `SwiftGraphQLWebSocket`: `graphql-transport-ws` subscription transport.
- `SwiftGraphQLAppSync`: AppSync realtime request/message codec.
- `swift-graphql`: CLI for introspection SDL export and Swift generation.
- `swift-graphql-codegen`: compatibility CLI alias for existing generation scripts.
- `SwiftGraphQLCodegenPlugin`: SwiftPM build tool plugin that runs generation from `swift-graphql-codegen.yml`.

## Core Runtime Example

```swift
let client = GraphQLClient(configuration: .init(
    endpointURL: URL(string: "https://example.com/graphql")!,
    authProvider: BearerTokenAuthProvider(token: "token")
))

let data = try await client.fetch(KindredAPI.HomeQuery(...))
let result = try await client.perform(KindredAPI.SendMessageMutation(...))
let stream = client.subscribe(KindredAPI.MessageCreatedSubscription(...))
```

## Implemented Runtime Pieces

- GraphQL-over-HTTP `POST`.
- `Accept: application/graphql-response+json, application/json;q=0.9`.
- `GraphQLOperation`, `GraphQLQuery`, `GraphQLMutation`, `GraphQLSubscription`.
- `GraphQLNullable.none/null/some`.
- `GraphQLEnum`.
- `GraphQLID`.
- `GraphQLJSON`.
- `GraphQLResult`, `GraphQLError`, `GraphQLClientError`.
- `GraphQLSubscriptionTransport` plus `GraphQLClient.subscribe`.
- `GraphQLOperationCache` plus `GraphQLClient.fetch(..., cachePolicy:)` support for `networkOnly`, `cacheFirst`, `cacheOnly`, `cacheAndNetwork`, and `noCache`.
- Bearer token, API key, and custom header auth providers.
- Device fingerprint and custom headers.
- Single coordinated refresh-on-401 retry.
- GraphQL variable builder with omitted-vs-null support.
- Multipart upload body builder plus `GraphQLUploadRequestEncoder` for auto-switching configured clients to multipart when upload variables are present.
- Fragment projection helper for generated `.fragments.foo` accessors.
- Standard `graphql-transport-ws` transport for connection init, subscribe, ping/pong, next/error/complete message decoding, reconnect, keepalive timeout, fresh auth headers per reconnect, and generated subscription streams.
- AppSync realtime transport for `graphql-ws` connection init, start, stop, ack/keepalive/data/error/complete message decoding, reconnect, keepalive timeout, fresh auth headers per reconnect, and generated subscription streams.
- Introspection JSON to SDL conversion plus `swift-graphql-codegen introspect --endpoint ... --output ...`.
- Codegen emits `Upload = GraphQLUpload` and imports `SwiftGraphQLUpload` when the schema declares `scalar Upload`.
- Codegen supports scalar mappings via `scalars`, `scalarMappings`, or `customScalars` in `swift-graphql-codegen.yml`.
- SwiftPM build tool plugin discovers `swift-graphql-codegen.yml`/`.yaml` in the target or package root and emits generated sources into the plugin work directory.

## Implemented Cache Pieces

- Normalized records keyed by `GraphQLRecordID`.
- Merge writes and field-level partial read detection.
- Record watchers via `AsyncStream`.
- Eviction and clear.
- Optimistic layer write, eviction, rollback, and commit.
- Cursor/list reference append with deduplication.
- SQLite-backed record persistence with merge writes, partial-read detection, eviction, clear, batch transactions, and WAL mode.
- `GraphQLNormalizedCache` bridges normalized records into `GraphQLClient` cache policies, stores entities by `__typename:id` by default, supports custom key fields, and falls back to stable response paths for unkeyed objects.

## Kindred Migration Notes

See [KindredGraphQLMigrationInventory.md](Docs/KindredGraphQLMigrationInventory.md) for the Kindred GraphQL migration inventory and narrowed MVP order.

Kindred smoke-test command used during development:

```sh
swift run swift-graphql generate \
  --config /path/to/kindred_mobile/swift-graphql-codegen.yml \
  --output /private/tmp/kindred-swift-graphql-generated-typed
```

Introspection command:

```sh
swift run swift-graphql introspect \
  --endpoint https://example.com/graphql \
  --header "Authorization: Bearer TOKEN" \
  --output schema.graphqls
```

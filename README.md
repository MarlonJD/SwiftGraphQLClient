# SwiftGraphQLClient

SwiftGraphQLClient is a SwiftPM GraphQL toolkit built as Kindred's typed GraphQL runtime and codegen stack.

Current status: the Kindred replacement surface and the Apollo iOS parity layers are in place and tested. The implemented surface covers the core HTTP client, GraphQL input/runtime types, auth headers, GraphQL error parsing, refresh retry coordination, normalized cache integration, local cache mutations, multipart upload requests, subscription transports, HTTP multipart incremental delivery with typed patch merging, APQ/persisted query requests, introspection SDL export, operation manifests, and native Swift operation generation.

The codegen CLI can read the current YAML config or a legacy JSON config, parse schema scalars/enums/input objects/object/interface/union fields plus operation and fragment selections, and emit operation structs, input objects, fragments, scalar aliases, abstract-type projections, local cache mutation helpers, and nested `Codable` response `Data` models under the configured namespace.

## Why Use This Package

- You want a Swift-native GraphQL client that keeps operation definitions,
  generated types, runtime execution, and cache integration in one SwiftPM
  package.
- You need typed queries, mutations, subscriptions, fragments, input objects,
  custom scalar mappings, and generated `Codable` response models without
  maintaining a separate JavaScript codegen toolchain.
- You want modular adoption: use only the HTTP runtime, then add normalized
  caching, SQLite persistence, uploads, WebSocket subscriptions, AppSync
  realtime transport, or the SwiftPM codegen plugin as your app needs them.
- You need production-oriented runtime behavior such as auth headers,
  coordinated refresh-on-401 retry, multipart uploads, GraphQL error parsing,
  cache policies, optimistic cache layers, and reconnecting subscriptions.
- You prefer Swift concurrency APIs and package-local generated sources that
  fit iOS and macOS builds without extra application-level scaffolding.

## Products

- `SwiftGraphQLClient`: typed operation protocols, HTTP runtime, auth providers, errors, scalars.
- `SwiftGraphQLCache`: in-memory normalized record store with watchers, partial-read detection, optimistic layers, and cursor-list reference helpers.
- `SwiftGraphQLSQLiteStore`: SQLite normalized record persistence.
- `SwiftGraphQLUpload`: `GraphQLUpload`, multipart request body builder, and upload-aware request encoder.
- `SwiftGraphQLWebSocket`: single-operation and multiplexed `graphql-transport-ws` subscription transports.
- `SwiftGraphQLAppSync`: single-operation and multiplexed AppSync realtime transports.
- `SwiftGraphQLPagination`: cursor, offset, directional, and query pager helpers.
- `SwiftGraphQLTestSupport`: mock client and typed test data builder helpers.
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
- Automatic persisted query and safelisted persisted query request modes, including operation SHA-256 identifiers and APQ fallback retry.
- Request and response interceptor hooks for custom networking pipelines.
- HTTP multipart response parsing for incremental `@defer`-style responses through `GraphQLClient.fetchIncremental`.
- Incremental patch merging for `@defer`/`@stream` responses through `GraphQLClient.fetchIncrementalMerged`.
- HTTP multipart subscription transport through `GraphQLHTTPSubscriptionTransport`.
- Fragment projection helper for generated `.fragments.foo` accessors.
- Standard `graphql-transport-ws` transports for connection init, subscribe, ping/pong, next/error/complete message decoding, reconnect, keepalive timeout, fresh auth headers per reconnect, generated subscription streams, and optional single-socket multiplexing via `GraphQLMultiplexedWebSocketClient`.
- AppSync realtime transports for `graphql-ws` connection init, start, stop, ack/keepalive/data/error/complete message decoding, reconnect, keepalive timeout, fresh auth headers per reconnect, generated subscription streams, and optional single-socket multiplexing via `AppSyncMultiplexedRealtimeClient`.
- Introspection JSON to SDL conversion plus `swift-graphql-codegen introspect --endpoint ... --output ...`.
- Codegen emits `Upload = GraphQLUpload` and imports `SwiftGraphQLUpload` when the schema declares `scalar Upload`.
- Codegen supports scalar mappings via `scalars`, `scalarMappings`, or `customScalars` in `swift-graphql-codegen.yml`.
- Codegen emits stable `operationIdentifier` values and can generate or publish Apollo persisted-query-compatible operation manifests.
- Codegen models `interface` and `union` selections with optional `asType` projections for inline fragments and concrete fragment spreads.
- Codegen emits per-operation `localCacheMutation(data:)` helpers for typed cache writes.
- Codegen emits fragment selection metadata for cache partial-read detection through fragment spreads.
- SwiftPM build tool plugin discovers `swift-graphql-codegen.yml`/`.yaml` in the target or package root and emits generated sources into the plugin work directory.

## Implemented Cache Pieces

- Normalized records keyed by `GraphQLRecordID`.
- Merge writes and field-level partial read detection.
- Record watchers via `AsyncStream`.
- Eviction and clear.
- Prefix removal, oldest-record trimming, and record ID listing.
- Optimistic layer write, eviction, rollback, and commit.
- Programmatic cache key resolvers that take precedence over declarative/custom key fields.
- ApolloStore-style `GraphQLOperationCacheStore.withinReadWriteTransaction` for typed read/write/update cache transactions.
- Generated local cache mutations can be written through `GraphQLReadWriteTransaction.write(_:)`.
- Cursor/list reference append with deduplication.
- SQLite-backed record persistence with merge writes, partial-read detection, eviction, clear, batch transactions, and WAL mode.
- `GraphQLNormalizedCache` bridges normalized records into `GraphQLClient` cache policies, stores entities by `__typename:id` by default, supports custom key fields, and falls back to stable response paths for unkeyed objects.
- `SQLiteNormalizedCache` provides the same `GraphQLOperationCache` bridge on top of SQLite persistence.

## Kindred Migration Notes

See [KindredGraphQLMigrationInventory.md](Docs/KindredGraphQLMigrationInventory.md) for the Kindred GraphQL migration inventory.

See [SwiftGraphQLClient-0.6.0-Plan.md](Docs/SwiftGraphQLClient-0.6.0-Plan.md) for the next production-hardening plan.

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

Operation manifest command:

```sh
swift run swift-graphql generate-operation-manifest \
  --config swift-graphql-codegen.yml \
  --output operation-manifest.json
```

Operation manifest publish command:

```sh
swift run swift-graphql publish-operation-manifest \
  --manifest operation-manifest.json \
  --endpoint https://example.com/persisted-query-manifest \
  --header "Authorization: Bearer TOKEN"
```

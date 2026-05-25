# Apollo iOS Migration Guide

This guide maps common Apollo iOS surfaces to SwiftGraphQLClient equivalents.

## Package Products

| Apollo iOS surface | SwiftGraphQLClient replacement |
| --- | --- |
| `Apollo` runtime | `SwiftGraphQLClient` |
| `ApolloAPI` generated support | `SwiftGraphQLClient` generated operation support |
| Apollo normalized cache | `SwiftGraphQLCache` |
| SQLite normalized cache | `SwiftGraphQLSQLiteStore` |
| Upload transport | `SwiftGraphQLUpload` |
| WebSocket subscriptions | `SwiftGraphQLWebSocket` |
| AppSync custom realtime code | `SwiftGraphQLAppSync` |
| Test mocks/builders | `SwiftGraphQLTestSupport` |

## Client Calls

Apollo:

```swift
apollo.fetch(query: HomeQuery())
apollo.perform(mutation: SendMessageMutation())
apollo.subscribe(subscription: MessageCreatedSubscription())
```

SwiftGraphQLClient:

```swift
let home = try await client.fetch(KindredAPI.HomeQuery())
let sent = try await client.perform(KindredAPI.SendMessageMutation())
let stream = client.subscribe(KindredAPI.MessageCreatedSubscription())
```

## Input Values

Use `GraphQLNullable.none`, `.null`, and `.some(value)` for omitted, explicit null, and concrete input values.

```swift
KindredAPI.UpdateProfileMutation(
    displayName: .some("Marlon"),
    avatarURL: .null,
    bio: .none
)
```

Use `GraphQLEnum<MyEnum>` for enum inputs when generated code asks for it.

## Cache Policies

| Apollo-style behavior | SwiftGraphQLClient |
| --- | --- |
| Network fetch and cache write | `.networkOnly` |
| Read cache, then network on miss | `.cacheFirst` |
| Read cache only | `.cacheOnly` |
| Return cache and refresh in background | `.cacheAndNetwork` |
| Network without cache write | `.noCache` |

```swift
let data = try await client.fetch(query, cachePolicy: .cacheFirst)
```

## Store Transactions

Apollo `ApolloStore.withinReadWriteTransaction` maps to `GraphQLOperationCacheStore.withinReadWriteTransaction`.

```swift
let operationStore = GraphQLOperationCacheStore(cache: normalizedCache)

try await operationStore.withinReadWriteTransaction { transaction in
    try await transaction.update(KindredAPI.HomeQuery()) { data in
        data.viewer.displayName = "Updated"
    }
}
```

Generated operations also provide local cache mutation helpers.

```swift
try await operationStore.withinReadWriteTransaction { transaction in
    try await transaction.write(query.localCacheMutation(data: updatedData))
}
```

## Uploads

Configure `GraphQLUploadRequestEncoder` to auto-switch matching operations to multipart requests.

```swift
let client = GraphQLClient(configuration: .init(
    endpointURL: endpoint,
    multipartRequestEncoder: GraphQLUploadRequestEncoder()
))
```

Use `GraphQLUpload` in generated `Upload` variables.

## Subscriptions

Use `GraphQLWebSocketClient` for `graphql-transport-ws`.

```swift
let transport = GraphQLMultiplexedWebSocketClient(configuration: .init(endpointURL: websocketURL))
let client = GraphQLClient(configuration: .init(endpointURL: endpoint, subscriptionTransport: transport))
```

Use `AppSyncRealtimeClient` or `AppSyncMultiplexedRealtimeClient` for AppSync realtime.

```swift
let transport = AppSyncMultiplexedRealtimeClient(configuration: .init(
    realtimeEndpointURL: realtimeURL,
    graphQLEndpointURL: endpoint,
    authProvider: APIKeyAuthProvider(value: apiKey)
))
```

## Persisted Queries

Use automatic persisted queries for APQ-style fallback.

```swift
let client = GraphQLClient(configuration: .init(
    endpointURL: endpoint,
    persistedQueries: .automaticPersistedQueries()
))
```

Generate and publish a manifest for safelisted persisted queries.

```sh
swift run swift-graphql generate-operation-manifest \
  --config swift-graphql-codegen.yml \
  --output operation-manifest.json

swift run swift-graphql publish-operation-manifest \
  --manifest operation-manifest.json \
  --endpoint https://example.com/persisted-query-manifest \
  --header "Authorization: Bearer TOKEN"
```

## Incremental Delivery

Use `fetchIncremental` to inspect raw multipart incremental responses, or `fetchIncrementalMerged` to receive typed snapshots after `@defer` or `@stream` patches are applied.

```swift
for try await result in client.fetchIncrementalMerged(KindredAPI.HomeQuery()) {
    render(result.data)
}
```

## Codegen

SwiftGraphQLClient codegen is native Swift and does not require Apollo CLI, Node, or npm.

```sh
swift run swift-graphql generate --config swift-graphql-codegen.yml
```

The generator emits:

- operation structs
- input objects
- enums
- scalar aliases
- fragments
- nested `Codable` response models
- interface and union projections such as `asUser`
- selection metadata for normalized cache partial-read detection
- `operationIdentifier`
- local cache mutation helpers

## Testing

Use `GraphQLMockClient` for operation-level unit tests.

```swift
let mock = GraphQLMockClient()
await mock.enqueue(KindredAPI.HomeQuery.self, data: fixture)
let data = try await mock.fetch(KindredAPI.HomeQuery())
```

Environment-gated live smoke tests are available in the package test suite. They are skipped by default and run only when the relevant `SWIFT_GRAPHQL_LIVE_*` variables are provided.

# Kindred Apollo Migration Inventory

Source inspected: `/Users/marlonjd/Developer/mobile/kindred_swift/kindred_mobile`.

## Current Apollo Footprint

- SwiftPM dependency: `apollo-ios` 2.1.1 in `kindred.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
- Xcode products: `Apollo` and `ApolloAPI` are linked in `kindred.xcodeproj/project.pbxproj`.
- Codegen config: `apollo-codegen-config.json`.
- Codegen script: `Scripts/run-apollo-codegen.sh`.
- Generated namespace: `KindredAPI`.
- Generated output: `kindred_swift/core/Networking/GeneratedGraphQL`.

## Operation Surface

- Queries: 19.
- Mutations: 46.
- Subscriptions: 1 real operation, `MessageCreated`.
- Fragments: 12.
- GraphQL source files: `graphql/Operations/*.graphql` plus `graphql/codegen-directives.graphqls`.
- Schema source: `../kindred_server/graphql/schema.graphqls`.

## Runtime Usage

- `KindredApolloClient` exposes only `fetch` and `perform`.
- Apollo normalized cache is constructed with `ApolloStore(cache: InMemoryNormalizedCache())`, but app code does not call Apollo store read/write/watch APIs.
- Query cache policy usage is effectively `networkOnly` plus test double signatures.
- The app already has a non-Apollo `URLSessionKindredGraphQLClient`, but generated operation materialization is Apollo-backed.
- Auth modes needed by GraphQL clients:
  - bearer token for protected AppSync operations
  - API key via `x-api-key` for public auth/session refresh operations
  - device fingerprint header support
  - refresh-on-401 with a single coordinated retry

## Type Compatibility Needed First

- `GraphQLNullable.none/null/some`.
- `GraphQLEnum`.
- `GraphQLID`.
- `GraphQLJSON` / `AWSJSON`.
- `AWSDateTime` as a string-backed scalar, with app-side date parsing preserved.
- Generated input objects with omitted-vs-null support.
- Generated operation structs under `KindredAPI` with operation name, document, variables, and decodable `Data`.

## Realtime

- Current live environments prefer API Gateway `messageRealtimeURL`.
- AppSync realtime fallback exists in `AppSyncMessageRealtimeClient.swift`.
- The custom AppSync codec hard-codes the `MessageCreated` subscription document and decodes directly to `MessageDTO`.
- Migration target: move that codec into `SwiftGraphQLAppSync` and drive `MessageCreatedSubscription` through generated `KindredAPI` data.

## MVP Order

1. Core runtime: HTTP POST, auth providers, device/custom headers, GraphQL error parsing, refresh-on-401 retry. Done in the package MVP.
2. Type surface: nullable, enum, ID, JSON, input object omission semantics. Done in the package MVP.
3. Codegen for Kindred operations only: operation structs, input objects, enums, fragments, scalar aliases, decodable data structs. Done for the current Kindred operation set; generated output smoke-generates 19 queries, 46 mutations, and 1 subscription and typechecks as a standalone Swift file against `SwiftGraphQLClient`.
4. Replace `KindredApolloClient` implementations with `GraphQLClient` equivalents.
5. Replace `ApolloSessionRefresher` with a package-backed refresher using `RefreshSessionMutation`.
6. Move AppSync message subscription codec into `SwiftGraphQLAppSync`. Done at package level: `AppSyncRealtimeClient` now conforms to `GraphQLSubscriptionTransport`, drives generated subscription documents over `URLSessionWebSocketTask`, and can be attached to `GraphQLClient.subscribe`.
7. Add generic `graphql-transport-ws`. Done at package level: `GraphQLWebSocketClient` now conforms to `GraphQLSubscriptionTransport`, sends `connection_init`/`subscribe`/`complete`, handles ping/pong, decodes `next` payloads into generated subscription data, and maps GraphQL error payloads.
8. Add introspection SDL export. Done at package level: `swift-graphql-codegen introspect --endpoint ... --header "Name: Value" --output schema.graphqls` posts the standard introspection query and converts the response to SDL.
9. Add multipart upload request integration. Done at package level: `GraphQLUploadRequestEncoder` can be attached to `GraphQLClientConfiguration`, detects `GraphQLUpload` variables, emits spec-compatible `operations`/`map`/file fields, and leaves non-upload operations on JSON.
10. Add SwiftPM codegen plugin. Done at package level: `SwiftGraphQLCodegenPlugin` discovers `swift-graphql-codegen.yml`/`.yaml` in the target or package root and invokes `swift-graphql-codegen generate` into the plugin work directory.
11. Remove Apollo products and run final `rg` acceptance.

## Deferred

- Broad schema-aware codegen polish.

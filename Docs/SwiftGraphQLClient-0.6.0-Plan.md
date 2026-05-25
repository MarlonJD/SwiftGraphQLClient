# SwiftGraphQLClient 0.6.0 Production Hardening

## Goal

Turn the Apollo replacement surface from feature-complete for Kindred into a broader production-hardening release for Apple platforms.

## Implemented Scope

- Add environment-gated live smoke tests for HTTP GraphQL execution and AppSync realtime subscriptions.
- Add a persisted-query manifest publish smoke path against a real registry or Apollo-compatible PQL endpoint.
- Expand codegen golden coverage with larger real-world operation sets, especially abstract types, nested inline fragments, aliases, defaults, and custom scalars.
- Add cache stress coverage for watcher cancellation, optimistic layer ordering, eviction, and transaction races.
- Add subscription stress coverage for reconnects with multiple active operations and auth refreshes.
- Add migration documentation that maps common Apollo iOS APIs to SwiftGraphQLClient equivalents.

## Acceptance

- `swift test` passes.
- Environment-gated live smoke tests pass when credentials are provided.
- Kindred remains free of Apollo imports/usages.
- Kindred unit tests pass after pinning the new package tag.
- Public APIs added in 0.5.0 have examples and migration notes.

## Live Smoke Environment

The live smoke tests are skipped unless the relevant environment variables are provided.

HTTP GraphQL:

- `SWIFT_GRAPHQL_LIVE_HTTP_ENDPOINT`
- `SWIFT_GRAPHQL_LIVE_HTTP_AUTHORIZATION`, optional
- `SWIFT_GRAPHQL_LIVE_HTTP_API_KEY`, optional
- `SWIFT_GRAPHQL_LIVE_HTTP_HEADERS_JSON`, optional JSON object
- `SWIFT_GRAPHQL_LIVE_HTTP_QUERY`, optional
- `SWIFT_GRAPHQL_LIVE_HTTP_OPERATION_NAME`, optional
- `SWIFT_GRAPHQL_LIVE_HTTP_VARIABLES_JSON`, optional JSON object

AppSync realtime:

- `SWIFT_GRAPHQL_LIVE_APPSYNC_REALTIME_ENDPOINT`
- `SWIFT_GRAPHQL_LIVE_APPSYNC_GRAPHQL_ENDPOINT`
- `SWIFT_GRAPHQL_LIVE_APPSYNC_SUBSCRIPTION`
- `SWIFT_GRAPHQL_LIVE_APPSYNC_OPERATION_NAME`, optional
- `SWIFT_GRAPHQL_LIVE_APPSYNC_VARIABLES_JSON`, optional JSON object
- `SWIFT_GRAPHQL_LIVE_APPSYNC_AUTHORIZATION`, optional
- `SWIFT_GRAPHQL_LIVE_APPSYNC_API_KEY`, optional
- `SWIFT_GRAPHQL_LIVE_APPSYNC_HEADERS_JSON`, optional JSON object

Operation manifest publish:

- `SWIFT_GRAPHQL_LIVE_MANIFEST_ENDPOINT`
- `SWIFT_GRAPHQL_LIVE_MANIFEST_JSON`, optional
- `SWIFT_GRAPHQL_LIVE_MANIFEST_AUTHORIZATION`, optional
- `SWIFT_GRAPHQL_LIVE_MANIFEST_API_KEY`, optional
- `SWIFT_GRAPHQL_LIVE_MANIFEST_HEADERS_JSON`, optional JSON object

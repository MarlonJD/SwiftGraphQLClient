# SwiftGraphQLClient 0.6.0 Plan

## Goal

Turn the Apollo replacement surface from feature-complete for Kindred into a broader production-hardening release for Apple platforms.

## Scope

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

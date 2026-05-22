import Foundation

public protocol GraphQLAuthProvider: Sendable {
    func graphQLAuthorizationHeaders() async throws -> [String: String]
}

public struct BearerTokenAuthProvider: GraphQLAuthProvider {
    private let tokenProvider: @Sendable () async throws -> String?

    public init(token: String) {
        self.tokenProvider = { token }
    }

    public init(tokenProvider: @escaping @Sendable () async throws -> String?) {
        self.tokenProvider = tokenProvider
    }

    public func graphQLAuthorizationHeaders() async throws -> [String: String] {
        guard let token = try await tokenProvider(), !token.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }
}

public struct APIKeyAuthProvider: GraphQLAuthProvider {
    public let headerName: String
    public let value: String

    public init(value: String, headerName: String = "x-api-key") {
        self.headerName = headerName
        self.value = value
    }

    public func graphQLAuthorizationHeaders() async throws -> [String: String] {
        guard !headerName.isEmpty, !value.isEmpty else { return [:] }
        return [headerName: value]
    }
}

public struct CustomHeadersAuthProvider: GraphQLAuthProvider {
    private let headersProvider: @Sendable () async throws -> [String: String]

    public init(headers: [String: String]) {
        self.headersProvider = { headers }
    }

    public init(headersProvider: @escaping @Sendable () async throws -> [String: String]) {
        self.headersProvider = headersProvider
    }

    public func graphQLAuthorizationHeaders() async throws -> [String: String] {
        try await headersProvider()
    }
}

public protocol GraphQLSessionRefresher: Sendable {
    func refreshSession() async throws -> Bool
}

actor GraphQLRefreshCoordinator {
    private var inFlight: Task<Bool, Error>?

    func refresh(_ perform: @Sendable @escaping () async throws -> Bool) async throws -> Bool {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task<Bool, Error> {
            try await perform()
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

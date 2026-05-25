import CryptoKit
import Foundation

public struct GraphQLPersistedQueryConfiguration: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case disabled
        case automaticPersistedQueries
        case persistedQueries
    }

    public var mode: Mode
    public var useGETForRetry: Bool
    public var sendsDocumentOnFallback: Bool

    public init(
        mode: Mode = .disabled,
        useGETForRetry: Bool = false,
        sendsDocumentOnFallback: Bool = false
    ) {
        self.mode = mode
        self.useGETForRetry = useGETForRetry
        self.sendsDocumentOnFallback = sendsDocumentOnFallback
    }

    public static let disabled = GraphQLPersistedQueryConfiguration()

    public static func automaticPersistedQueries(
        useGETForRetry: Bool = false
    ) -> GraphQLPersistedQueryConfiguration {
        GraphQLPersistedQueryConfiguration(
            mode: .automaticPersistedQueries,
            useGETForRetry: useGETForRetry,
            sendsDocumentOnFallback: true
        )
    }

    public static func persistedQueries(
        sendsDocumentOnFallback: Bool = false
    ) -> GraphQLPersistedQueryConfiguration {
        GraphQLPersistedQueryConfiguration(
            mode: .persistedQueries,
            sendsDocumentOnFallback: sendsDocumentOnFallback
        )
    }
}

public enum GraphQLOperationDocumentHasher {
    public static func sha256(_ document: String) -> String {
        let digest = SHA256.hash(data: Data(document.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public extension GraphQLOperation {
    static var operationIdentifier: String {
        GraphQLOperationDocumentHasher.sha256(document)
    }
}

public extension GraphQLError {
    var isPersistedQueryNotFound: Bool {
        let normalizedCode = code?.replacingOccurrences(of: "_", with: "").uppercased()
        if normalizedCode == "PERSISTEDQUERYNOTFOUND" {
            return true
        }
        return message.replacingOccurrences(of: " ", with: "").uppercased().contains("PERSISTEDQUERYNOTFOUND")
    }
}

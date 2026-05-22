import Foundation

public protocol GraphQLSubscriptionTransport: Sendable {
    func subscribe<Subscription: GraphQLSubscription>(
        _ subscription: Subscription
    ) -> AsyncThrowingStream<Subscription.Data, Error>
}

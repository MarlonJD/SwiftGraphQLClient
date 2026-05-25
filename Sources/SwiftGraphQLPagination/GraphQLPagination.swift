import Foundation
import SwiftGraphQLClient

public enum GraphQLPaginationDirection: Sendable, Equatable {
    case forward
    case reverse
}

public struct GraphQLPageRequest<Cursor: Sendable & Equatable>: Sendable, Equatable {
    public var cursor: Cursor?
    public var limit: Int
    public var direction: GraphQLPaginationDirection

    public init(
        cursor: Cursor? = nil,
        limit: Int,
        direction: GraphQLPaginationDirection = .forward
    ) {
        self.cursor = cursor
        self.limit = limit
        self.direction = direction
    }
}

public struct GraphQLPage<Node: Sendable, Cursor: Sendable & Equatable>: Sendable {
    public var nodes: [Node]
    public var startCursor: Cursor?
    public var endCursor: Cursor?
    public var hasPreviousPage: Bool
    public var hasNextPage: Bool

    public init(
        nodes: [Node],
        startCursor: Cursor? = nil,
        endCursor: Cursor? = nil,
        hasPreviousPage: Bool = false,
        hasNextPage: Bool = false
    ) {
        self.nodes = nodes
        self.startCursor = startCursor
        self.endCursor = endCursor
        self.hasPreviousPage = hasPreviousPage
        self.hasNextPage = hasNextPage
    }
}

public enum CursorBasedPagination {
    public struct Forward<Cursor: Sendable & Equatable>: Sendable, Equatable {
        public var pageSize: Int

        public init(pageSize: Int) {
            self.pageSize = pageSize
        }

        public func nextRequest(after cursor: Cursor?) -> GraphQLPageRequest<Cursor> {
            GraphQLPageRequest(cursor: cursor, limit: pageSize, direction: .forward)
        }
    }

    public struct Reverse<Cursor: Sendable & Equatable>: Sendable, Equatable {
        public var pageSize: Int

        public init(pageSize: Int) {
            self.pageSize = pageSize
        }

        public func previousRequest(before cursor: Cursor?) -> GraphQLPageRequest<Cursor> {
            GraphQLPageRequest(cursor: cursor, limit: pageSize, direction: .reverse)
        }
    }

    public struct Bidirectional<Cursor: Sendable & Equatable>: Sendable, Equatable {
        public var pageSize: Int

        public init(pageSize: Int) {
            self.pageSize = pageSize
        }

        public func nextRequest(after cursor: Cursor?) -> GraphQLPageRequest<Cursor> {
            GraphQLPageRequest(cursor: cursor, limit: pageSize, direction: .forward)
        }

        public func previousRequest(before cursor: Cursor?) -> GraphQLPageRequest<Cursor> {
            GraphQLPageRequest(cursor: cursor, limit: pageSize, direction: .reverse)
        }
    }
}

public enum OffsetPagination {
    public struct Page: Sendable, Equatable {
        public var offset: Int
        public var limit: Int

        public init(offset: Int = 0, limit: Int) {
            self.offset = offset
            self.limit = limit
        }

        public func next(loadedCount: Int) -> Page {
            Page(offset: offset + loadedCount, limit: limit)
        }
    }
}

public actor GraphQLQueryPager<Node: Sendable, Cursor: Sendable & Equatable> {
    public typealias Loader = @Sendable (GraphQLPageRequest<Cursor>) async throws -> GraphQLPage<Node, Cursor>

    private let pageSize: Int
    private let loader: Loader
    private var endCursor: Cursor?
    private var startCursor: Cursor?
    private var loadedNodes: [Node] = []

    public init(
        pageSize: Int,
        initialCursor: Cursor? = nil,
        loader: @escaping Loader
    ) {
        self.pageSize = pageSize
        self.endCursor = initialCursor
        self.startCursor = initialCursor
        self.loader = loader
    }

    public var nodes: [Node] {
        loadedNodes
    }

    public func fetchNext() async throws -> GraphQLPage<Node, Cursor> {
        let page = try await loader(GraphQLPageRequest(cursor: endCursor, limit: pageSize, direction: .forward))
        loadedNodes.append(contentsOf: page.nodes)
        endCursor = page.endCursor
        if startCursor == nil {
            startCursor = page.startCursor
        }
        return page
    }

    public func fetchPrevious() async throws -> GraphQLPage<Node, Cursor> {
        let page = try await loader(GraphQLPageRequest(cursor: startCursor, limit: pageSize, direction: .reverse))
        loadedNodes.insert(contentsOf: page.nodes, at: 0)
        startCursor = page.startCursor
        if endCursor == nil {
            endCursor = page.endCursor
        }
        return page
    }

    public func reset(cursor: Cursor? = nil) {
        loadedNodes.removeAll()
        startCursor = cursor
        endCursor = cursor
    }
}

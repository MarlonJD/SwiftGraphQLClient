import Foundation

public enum GraphQLFragmentProjection {
    public static func project<Source: Encodable, Fragment: Decodable>(
        _ source: Source,
        to fragmentType: Fragment.Type
    ) -> Fragment {
        do {
            let data = try JSONEncoder().encode(source)
            return try JSONDecoder().decode(fragmentType, from: data)
        } catch {
            preconditionFailure("Generated GraphQL fragment projection failed: \(error)")
        }
    }
}

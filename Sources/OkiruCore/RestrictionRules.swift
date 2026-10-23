import Foundation

public enum RestrictionRules {
    /// Every active policy must permit an exception. Finishing one window cannot
    /// widen another active window's own policy. Empty policy list means no shield.
    public static func commonExceptions<Token: Hashable>(_ policies: [Set<Token>]) -> Set<Token> {
        guard var result = policies.first else { return [] }
        for policy in policies.dropFirst() { result.formIntersection(policy) }
        return result
    }
}

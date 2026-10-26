public enum SafetyVerdict: Int, Comparable, Sendable {
    case safe, review, risky, blocked

    public static func < (lhs: SafetyVerdict, rhs: SafetyVerdict) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

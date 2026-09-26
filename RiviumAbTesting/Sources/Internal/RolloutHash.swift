import Foundation

/// Rollout bucket for a flag, 0-99.
///
/// Must be stable: Swift's `hashValue` is seeded per launch, so a user would
/// move in and out of a partial rollout between launches. This is Java's
/// `String.hashCode()`, as the Android SDK uses, so a user gets the same
/// answer on both platforms.
internal enum RolloutHash {
    static func javaHashCode(_ string: String) -> Int32 {
        var hash: Int32 = 0
        for unit in string.utf16 {
            hash = hash &* 31 &+ Int32(unit)
        }
        return hash
    }

    static func bucket(_ string: String) -> Int {
        let hash = javaHashCode(string)
        // Java's Math.abs(Int.MIN_VALUE) stays negative; match it instead of
        // trapping on overflow.
        let value = hash == Int32.min ? Int(hash) : Int(abs(hash))
        return value % 100
    }
}

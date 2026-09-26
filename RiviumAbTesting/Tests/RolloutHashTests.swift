import XCTest
@testable import RiviumAbTesting

final class RolloutHashTests: XCTestCase {
    func testMatchesJavaStringHashCode() {
        // Expected values from Java's String.hashCode(), as the Android SDK uses.
        XCTAssertEqual(RolloutHash.javaHashCode(""), 0)
        XCTAssertEqual(RolloutHash.javaHashCode("hello"), 99162322)
        XCTAssertEqual(RolloutHash.javaHashCode("user-123new-checkout"), 991491075)
        XCTAssertEqual(RolloutHash.javaHashCode("user-42dark-mode"), -1510821414)
        XCTAssertEqual(RolloutHash.javaHashCode("Zo\u{EB}-ab"), -1608785640)
    }

    func testBucketMatchesAndroid() {
        // Android: Math.abs(hashCode) % 100
        XCTAssertEqual(RolloutHash.bucket("user-123new-checkout"), 991491075 % 100)
        XCTAssertEqual(RolloutHash.bucket("user-42dark-mode"), 1510821414 % 100)
    }

    func testBucketIsStable() {
        for i in 0..<500 {
            XCTAssertEqual(RolloutHash.bucket("user-\(i)flag"), RolloutHash.bucket("user-\(i)flag"))
        }
    }
}

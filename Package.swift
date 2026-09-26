// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "RiviumAbTesting",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "RiviumAbTesting",
            targets: ["RiviumAbTesting"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "RiviumAbTesting",
            dependencies: [],
            path: "RiviumAbTesting/Sources"
        ),
        .testTarget(
            name: "RiviumAbTestingTests",
            dependencies: ["RiviumAbTesting"],
            path: "RiviumAbTesting/Tests"
        )
    ],
    swiftLanguageVersions: [.v5]
)

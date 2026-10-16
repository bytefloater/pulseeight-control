// swift-tools-version:5.10
import PackageDescription

// The app is a separate package from ../swift so that `swift test` on PulseEightKit never
// pulls in SwiftCrossUI (and its per-OS backend dependencies).
let package = Package(
    name: "PulseEightControlApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/moreSwift/swift-cross-ui", .upToNextMinor(from: "0.10.0")),
        .package(path: "../swift"),
    ],
    targets: [
        .executableTarget(
            name: "PulseEightControl",
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
                .product(name: "PulseEightKit", package: "swift"),
            ]
        ),
    ]
)

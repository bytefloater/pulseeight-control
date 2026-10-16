// swift-tools-version:5.10
import PackageDescription

// THROWAWAY: M0 risk spike for SwiftCrossUI. Not part of the shipped app.
let package = Package(
    name: "scui-spike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/moreSwift/swift-cross-ui", .upToNextMinor(from: "0.10.0")),
    ],
    targets: [
        .executableTarget(
            name: "Spike",
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
                .product(name: "AppKitBackend", package: "swift-cross-ui", condition: .when(platforms: [.macOS])),
            ]
        ),
    ]
)

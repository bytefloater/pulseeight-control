// swift-tools-version:5.10
import PackageDescription

// THROWAWAY: M0 risk spike for SwiftCrossUI. Not part of the shipped app.
// On Windows build with SCUI_DEFAULT_BACKEND=WinUIBackend (see app/Package.swift for why).

var spikeDependencies: [Target.Dependency] = [
    .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
    .product(name: "DefaultBackend", package: "swift-cross-ui"),
]
#if os(macOS)
    spikeDependencies.append(.product(name: "AppKitBackend", package: "swift-cross-ui"))
#endif

let package = Package(
    name: "scui-spike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/moreSwift/swift-cross-ui", .upToNextMinor(from: "0.10.0")),
    ],
    targets: [
        .executableTarget(name: "Spike", dependencies: spikeDependencies),
    ]
)

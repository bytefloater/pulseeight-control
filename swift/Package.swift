// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PulseEightControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PulseEightKit", targets: ["PulseEightKit"]),
        .executable(name: "p8ctl", targets: ["p8ctl"]),
    ],
    targets: [
        // Foundation-only device layer. No UI, builds and tests on macOS, Windows and Linux.
        .target(name: "PulseEightKit"),
        .executableTarget(name: "p8ctl", dependencies: ["PulseEightKit"]),
        .testTarget(name: "PulseEightKitTests", dependencies: ["PulseEightKit"]),
    ]
)

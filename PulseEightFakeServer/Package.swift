// swift-tools-version:5.10
import PackageDescription

// A stand-in for a Pulse-Eight NeoMatrix, for developing and testing without hardware. The matrix
// logic and a small HTTP server live in the library; p8fake is the command-line wrapper. It depends
// on PulseEightKit only for the HTTPTransport type (so tests can run the whole stack in-process).
let package = Package(
    name: "PulseEightFakeServer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PulseEightFakeMatrix", targets: ["PulseEightFakeMatrix"]),
        .executable(name: "p8fake", targets: ["p8fake"]),
    ],
    dependencies: [
        .package(path: "../PulseEightKit"),
    ],
    targets: [
        .target(
            name: "PulseEightFakeMatrix",
            dependencies: [.product(name: "PulseEightKit", package: "PulseEightKit")]
        ),
        .executableTarget(name: "p8fake", dependencies: ["PulseEightFakeMatrix"]),
        .testTarget(
            name: "PulseEightFakeMatrixTests",
            dependencies: [
                "PulseEightFakeMatrix",
                .product(name: "PulseEightKit", package: "PulseEightKit"),
            ]
        ),
    ]
)

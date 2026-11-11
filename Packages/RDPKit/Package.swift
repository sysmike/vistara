// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RDPKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RDPKit", targets: ["RDPKit"])
    ],
    targets: [
        // C shim and module map over the FreeRDP headers. Nothing above RDPKit imports it.
        .target(name: "CFreeRDP"),
        .target(name: "RDPKit", dependencies: ["CFreeRDP"]),
        .testTarget(name: "RDPKitTests", dependencies: ["RDPKit"])
    ]
)

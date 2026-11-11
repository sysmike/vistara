// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VistaraCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VistaraCore", targets: ["VistaraCore"])
    ],
    targets: [
        .target(name: "VistaraCore"),
        .testTarget(name: "VistaraCoreTests", dependencies: ["VistaraCore"])
    ]
)

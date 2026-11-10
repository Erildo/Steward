// swift-tools-version: 6.2
import PackageDescription

// The agent itself: case, tools, approval gate, model client, agent loop.
// No UI and no networking beyond the model client, so it runs in the iOS app,
// in tests on a Mac, and could be ported to other clients.
let package = Package(
    name: "StewardCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "StewardCore", targets: ["StewardCore"])],
    targets: [
        .target(name: "StewardCore"),
        .testTarget(name: "StewardCoreTests", dependencies: ["StewardCore"]),
    ]
)

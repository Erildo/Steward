// swift-tools-version: 6.2
import PackageDescription

// The agent itself: case, tools, approval gate, model client, agent loop.
// No UI. Its only networking is the model client, the relay client and a
// read-only IMAP client, so it runs in the iOS app, in tests on a Mac, and
// could be ported to other clients.
let package = Package(
    name: "StewardCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "StewardCore", targets: ["StewardCore"])],
    targets: [
        .target(name: "StewardCore", resources: [.copy("Spec"), .copy("TaskSpec")]),
        .testTarget(name: "StewardCoreTests", dependencies: ["StewardCore"]),
    ]
)

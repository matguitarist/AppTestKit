// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppTestKit",
    // AppKit only: the self-test and the snapshots drive a Mac app's windows.
    platforms: [.macOS(.v14)],
    products: [
        // The test-store guard, the self-test's checks and summary, and the snapshot run with its window captures.
        .library(name: "AppTestKit", targets: ["AppTestKit"]),
    ],
    targets: [
        .target(name: "AppTestKit"),
        .testTarget(name: "AppTestKitTests", dependencies: ["AppTestKit"]),
    ]
)

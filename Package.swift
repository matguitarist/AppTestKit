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
    dependencies: [
        // screencapture runs through it: a capture that hangs is stopped instead of holding the run.
        .package(url: "https://github.com/matguitarist/ProcessKit", from: "0.1.1"),
    ],
    targets: [
        .target(name: "AppTestKit", dependencies: [.product(name: "ProcessKit", package: "ProcessKit")]),
        .testTarget(name: "AppTestKitTests", dependencies: ["AppTestKit"]),
    ]
)

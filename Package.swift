// swift-tools-version: 6.0
import PackageDescription

// The app and widget compile these same Foundation-only sources in Xcode.
// This target exercises their business rules without launching the app or reading credentials.
let package = Package(
    name: "PowerNotchUsage",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "MediaCore", path: "MediaCore"),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"], path: "Tests/MediaCoreTests"),
        .target(name: "AIUsageCore", path: "AIUsageCore"),
        .testTarget(name: "AIUsageCoreTests", dependencies: ["AIUsageCore"], path: "Tests/AIUsageCoreTests")
    ]
)

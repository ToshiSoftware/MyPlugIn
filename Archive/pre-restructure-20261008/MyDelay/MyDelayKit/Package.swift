// swift-tools-version: 5.9
import PackageDescription

// One target on purpose: MyDAW compiles these sources into its own module
// (scripts/sync-builtin-plugins.sh), so they must not import each other, and
// they import MyFXShared only `#if canImport(MyFXShared)`.
let package = Package(
    name: "MyDelayKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MyDelayKit", targets: ["MyDelayKit"])
    ],
    dependencies: [
        .package(path: "../../MyFXShared")
    ],
    targets: [
        .target(name: "MyDelayKit", dependencies: ["MyFXShared"]),
        .testTarget(name: "MyDelayKitTests", dependencies: ["MyDelayKit", "MyFXShared"])
    ]
)

// swift-tools-version: 5.9
import PackageDescription

// One target on purpose: MyDAW compiles these sources into its own module
// (scripts/sync-builtin-plugins.sh), so they must not import each other, and
// they import MyFXShared only `#if canImport(MyFXShared)`.
let package = Package(
    name: "MyReverbKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MyReverbKit", targets: ["MyReverbKit"])
    ],
    dependencies: [
        .package(path: "../../MyFXShared")
    ],
    targets: [
        .target(name: "MyReverbKit", dependencies: ["MyFXShared"]),
        .testTarget(name: "MyReverbKitTests", dependencies: ["MyReverbKit", "MyFXShared"])
    ]
)

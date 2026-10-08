// swift-tools-version: 5.9
import PackageDescription

// Parts shared by MyDAW's built-in effects (MyReverb, MyDelay): input/output
// metering and the editor look. MyDAW compiles these sources into its own
// module together with the effects (scripts/sync-builtin-plugins.sh), so the
// effects import this module only `#if canImport(MyFXShared)`.
let package = Package(
    name: "MyFXShared",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MyFXShared", targets: ["MyFXShared"])
    ],
    targets: [
        .target(name: "MyFXShared")
    ]
)

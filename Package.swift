// swift-tools-version: 5.9
import PackageDescription

// MyPlugIn: MyDAW's built-in effects, also packaged as AUv3 extensions
// (Hosts/MyPlugInHost) for other hosts.
//
// Every effect is its own target on top of MyPlugInCore. MyDAW compiles all
// these sources into one module (MyDAW/scripts/sync-myplugin.sh), so targets
// import each other only `#if canImport(...)`, and type names carry a prefix.
//
// To add an effect: Tools/new-plugin.sh (adds it to `plugIns` below and to
// MyPlugInCatalog).

let plugIns = [
    "MyReverb",
    "MyDelay",
    // new-plugin.sh: plug-ins
]

let package = Package(
    name: "MyPlugIn",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MyPlugInCore", targets: ["MyPlugInCore"]),
        .library(name: "MyPlugInCatalog", targets: ["MyPlugInCatalog"])
    ] + plugIns.map { .library(name: $0, targets: [$0]) },
    targets: [
        .target(name: "MyPlugInCore"),
        .target(name: "MyPlugInCatalog", dependencies: plugIns.map { .target(name: $0) }),
        .executableTarget(name: "MyPlugInSnapshots", dependencies: ["MyPlugInCatalog", "MyPlugInCore"],
                          path: "Tools/MyPlugInSnapshots"),
        .testTarget(name: "MyPlugInCoreTests", dependencies: ["MyPlugInCore"]),
        .testTarget(name: "MyPlugInCatalogTests", dependencies: ["MyPlugInCatalog", "MyPlugInCore"])
    ] + plugIns.flatMap { name -> [Target] in
        [
            .target(name: name, dependencies: ["MyPlugInCore"]),
            .testTarget(name: "\(name)Tests", dependencies: [.target(name: name), "MyPlugInCore"])
        ]
    }
)

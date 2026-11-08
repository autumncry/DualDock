// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DualDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DualDock", targets: ["DualDock"])],
    targets: [
        .target(name: "DualDockCore"),
        .executableTarget(name: "DualDock", dependencies: ["DualDockCore"]),
        .testTarget(name: "DualDockCoreTests", dependencies: ["DualDockCore"])
    ]
)

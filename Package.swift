// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DualDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DualDock", targets: ["DualDock"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1")
    ],
    targets: [
        .target(name: "DualDockCore"),
        .executableTarget(
            name: "DualDock",
            dependencies: ["DualDockCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "DualDockCoreTests", dependencies: ["DualDockCore"])
    ]
)

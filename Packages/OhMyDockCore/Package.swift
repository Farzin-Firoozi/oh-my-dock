// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OhMyDockCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OhMyDockCore", targets: ["OhMyDockCore"]),
    ],
    targets: [
        .target(name: "OhMyDockCore"),
        .testTarget(
            name: "OhMyDockCoreTests",
            dependencies: ["OhMyDockCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

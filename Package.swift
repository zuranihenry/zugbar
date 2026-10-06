// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Zugbar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Zugbar", targets: ["Zugbar"]),
    ],
    targets: [
        .target(
            name: "ZugbarCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "Zugbar",
            dependencies: ["ZugbarCore"]
        ),
        .testTarget(
            name: "ZugbarCoreTests",
            dependencies: ["ZugbarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

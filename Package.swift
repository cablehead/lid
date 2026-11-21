// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lid",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LidCore"),
        .executableTarget(name: "Lid", dependencies: ["LidCore"]),
        .testTarget(
            name: "LidCoreTests",
            dependencies: ["LidCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

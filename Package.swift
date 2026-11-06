// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nap",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NapCore"),
        .executableTarget(name: "Nap", dependencies: ["NapCore"]),
        .testTarget(
            name: "NapCoreTests",
            dependencies: ["NapCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

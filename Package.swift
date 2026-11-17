// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clamshell",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClamshellCore"),
        .executableTarget(name: "Clamshell", dependencies: ["ClamshellCore"]),
        .testTarget(
            name: "ClamshellCoreTests",
            dependencies: ["ClamshellCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

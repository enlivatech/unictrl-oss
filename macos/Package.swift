// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unictrl",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Unictrl",
            path: "Sources/Unictrl",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Network"),
            ]
        ),
        .testTarget(
            name: "UnictrlTests",
            dependencies: ["Unictrl"],
            path: "Tests/UnictrlTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

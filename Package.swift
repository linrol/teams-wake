// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TeamsWake",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "TeamsWake",
            targets: ["TeamsWake"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "TeamsWake",
            dependencies: [],
            path: "Sources/TeamsWake",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Translation")
            ]
        )
    ]
)

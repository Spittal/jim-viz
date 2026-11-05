// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "JimViz",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "JimViz",
            path: "Sources/JimViz",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ]
)

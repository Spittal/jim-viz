// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "jim-viz",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "jim-viz", targets: ["JimViz"])],
    targets: [
        .executableTarget(
            name: "JimViz",
            path: "Sources/JimViz",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ]
)

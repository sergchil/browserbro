// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BrowserBro",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RoutingCore", targets: ["RoutingCore"]),
        .executable(name: "bro", targets: ["bro"]),
        .executable(name: "BrowserBro", targets: ["BrowserBro"]),
    ],
    targets: [
        .target(name: "RoutingCore"),
        .executableTarget(name: "bro", dependencies: ["RoutingCore"]),
        .executableTarget(
            name: "BrowserBro",
            dependencies: ["RoutingCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "RoutingCoreTests",
            dependencies: ["RoutingCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

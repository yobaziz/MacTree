// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacTree",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MacTree", targets: ["MacTree"])
    ],
    targets: [
        .executableTarget(
            name: "MacTree",
            path: "Sources/MacTree",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=minimal"])
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)

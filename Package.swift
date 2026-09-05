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
            exclude: ["MacTreeApp.swift", "MacTreeV4.swift", "MacTreeV5.swift",
                      "MacTreeV6.swift", "MacTreeV7.swift", "MacTreeV8.swift",
                      "MacTreeV9.swift", "ConcurrencyCompat.swift"],
            sources: ["App.swift", "Core.swift", "FastScanner.swift", "Tree.swift",
                      "Treemap.swift", "VTypeCompat.swift"],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=minimal"])
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)


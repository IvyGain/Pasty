// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Pasty",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Pasty", targets: ["Pasty"])
    ],
    dependencies: [
        // Vendored to side-step xcrun/git license checks on machines where
        // Xcode is installed but its license has not been accepted yet.
        // Switch back to `.package(url: ...)` once the user accepts the
        // Xcode license; see Vendor/GRDB.swift for the pinned source.
        .package(path: "Vendor/GRDB.swift")
    ],
    targets: [
        .executableTarget(
            name: "Pasty",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/Pasty",
            exclude: [],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "PastyTests",
            dependencies: ["Pasty"],
            path: "Tests/PastyTests"
        )
    ]
)

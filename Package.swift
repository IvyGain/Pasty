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
        .package(path: "Vendor/GRDB.swift"),
        // Sparkle 2: 起動時の自動アップデートと EdDSA 署名検証。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "Pasty",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle")
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

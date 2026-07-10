
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperReader",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // The reusable core (models + database layer). Views and services in later
        // sessions can depend on this without pulling in the @main app entry point.
        .library(name: "PaperReaderCore", targets: ["PaperReaderCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        // Models/ + Database/ live here. Kept separate from the app target so the
        // test bundle can link the DB layer without linking a second `main`.
        .target(
            name: "PaperReaderCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "PaperReader",
            sources: ["Models", "Database", "Services"]
        ),
        .executableTarget(
            name: "PaperReaderApp",
            dependencies: ["PaperReaderCore"],
            path: "PaperReader",
            sources: ["App", "Views/Home", "Views/Reader", "Views/Notes", "Views/ClaudePanel", "Views/Settings"]
        ),
        .testTarget(
            name: "PaperReaderCoreTests",
            dependencies: ["PaperReaderCore"],
            path: "Tests/PaperReaderCoreTests"
        )
    ]
)


// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Petal",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // The reusable core (models + database layer). Views and services in later
        // sessions can depend on this without pulling in the @main app entry point.
        .library(name: "PetalCore", targets: ["PetalCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.5.0")
    ],
    targets: [
        // Models/ + Database/ live here. Kept separate from the app target so the
        // test bundle can link the DB layer without linking a second `main`.
        .target(
            name: "PetalCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Petal",
            sources: ["Models", "Database", "Services"]
        ),
        .executableTarget(
            name: "PetalApp",
            dependencies: [
                "PetalCore",
                .product(name: "SwiftMath", package: "SwiftMath")
            ],
            path: "Petal",
            sources: ["App", "Views/Home", "Views/Reader", "Views/Notes", "Views/ClaudePanel", "Views/Settings"]
        ),
        .testTarget(
            name: "PetalCoreTests",
            dependencies: ["PetalCore"],
            path: "Tests/PetalCoreTests"
        )
    ]
)

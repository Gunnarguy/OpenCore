// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OpenCoreKit", targets: ["CoreModel", "CoreStore", "CoreIngest", "CoreGraph", "CoreSearch", "CoreReason", "CoreMCP"]),
        .executable(name: "opencore", targets: ["opencore"]),
    ],
    targets: [
        // Layer 0 — vocabulary. Value types only, no I/O, no dependencies.
        .target(name: "CoreModel"),

        // Layer 1 — persistence. Owns the schema and every SQL statement in the project.
        .target(
            name: "CoreStore",
            dependencies: ["CoreModel"],
            resources: [.copy("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // Layer 2 — the three things that touch the store independently.
        .target(name: "CoreIngest", dependencies: ["CoreModel", "CoreStore"]),
        .target(name: "CoreGraph", dependencies: ["CoreModel", "CoreStore"]),
        .target(name: "CoreSearch", dependencies: ["CoreModel", "CoreStore"]),

        // Layer 3 — planning and answering. The only layer allowed to reach a model.
        .target(name: "CoreReason", dependencies: ["CoreModel", "CoreStore", "CoreSearch", "CoreGraph"]),

        // Layer 4 — surfaces.
        .target(name: "CoreMCP", dependencies: ["CoreModel", "CoreStore", "CoreGraph", "CoreSearch", "CoreReason"]),

        .executableTarget(
            name: "opencore",
            dependencies: ["CoreModel", "CoreStore", "CoreIngest", "CoreGraph", "CoreSearch", "CoreReason", "CoreMCP"]
        ),

        .testTarget(name: "CoreStoreTests", dependencies: ["CoreStore", "CoreModel"]),
        .testTarget(name: "CoreGraphTests", dependencies: ["CoreGraph", "CoreSearch", "CoreIngest", "CoreStore", "CoreModel"]),
    ]
)

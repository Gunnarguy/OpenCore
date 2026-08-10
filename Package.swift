// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OpenCoreKit", targets: ["CoreModel", "CoreJSONRPC", "CoreTelemetry", "CoreStore", "CoreIngest", "CoreGraph", "CoreSearch", "CoreReason", "CoreMCP"]),
        .executable(name: "opencore", targets: ["opencore"]),
    ],
    targets: [
        // Layer 0 — vocabulary. Value types only, no I/O, no dependencies.
        .target(name: "CoreModel"),

        // Layer 0 — protocol plumbing. JSON-RPC types and the stdio transport, shared by the
        // MCP server in CoreMCP and the MCP client in CoreIngest. It sits here rather than in
        // either of them because the alternative is CoreIngest depending on CoreMCP, which
        // would make ingestion depend on the whole reasoning stack.
        .target(name: "CoreJSONRPC", dependencies: ["CoreTelemetry"]),

        // Layer 0 — measurement. Every other layer depends on it, so it can depend on nothing.
        // Deliberately not folded into CoreModel: CoreModel is the vocabulary of what OpenCore
        // stores, and how long a query took is not part of that vocabulary.
        .target(name: "CoreTelemetry"),

        // Layer 1 — persistence. Owns the schema and every SQL statement in the project.
        .target(
            name: "CoreStore",
            dependencies: ["CoreModel", "CoreTelemetry"],
            resources: [.copy("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // Layer 2 — the three things that touch the store independently.
        .target(name: "CoreIngest", dependencies: ["CoreModel", "CoreStore", "CoreJSONRPC", "CoreTelemetry"]),
        .target(name: "CoreGraph", dependencies: ["CoreModel", "CoreStore", "CoreTelemetry"]),
        .target(name: "CoreSearch", dependencies: ["CoreModel", "CoreStore", "CoreTelemetry"]),

        // Layer 3 — planning and answering. The only layer allowed to reach a model.
        .target(name: "CoreReason", dependencies: ["CoreModel", "CoreStore", "CoreSearch", "CoreGraph", "CoreTelemetry"]),

        // Layer 4 — surfaces.
        .target(name: "CoreMCP", dependencies: ["CoreModel", "CoreStore", "CoreGraph", "CoreSearch", "CoreReason", "CoreJSONRPC", "CoreTelemetry"]),

        .executableTarget(
            name: "opencore",
            dependencies: ["CoreModel", "CoreJSONRPC", "CoreTelemetry", "CoreStore", "CoreIngest", "CoreGraph", "CoreSearch", "CoreReason", "CoreMCP"]
        ),

        .testTarget(name: "CoreStoreTests", dependencies: ["CoreStore", "CoreModel"]),
        .testTarget(name: "CoreGraphTests", dependencies: ["CoreGraph", "CoreSearch", "CoreIngest", "CoreJSONRPC", "CoreStore", "CoreModel"]),
        .testTarget(name: "CoreReasonTests", dependencies: ["CoreReason", "CoreSearch", "CoreStore", "CoreModel"]),
        .testTarget(name: "CoreSearchTests", dependencies: ["CoreSearch", "CoreStore", "CoreModel"]),
        .testTarget(name: "CoreMCPTests", dependencies: ["CoreMCP"]),
        .testTarget(name: "CoreTelemetryTests", dependencies: ["CoreTelemetry"]),
    ]
)

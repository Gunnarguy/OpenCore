// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "OpenCoreKit", targets: ["CoreModel", "CoreJSONRPC", "CoreTelemetry", "CoreStore", "CoreIngest", "CoreGraph", "CoreSearch", "CoreReason", "CoreMCP"]),
        .executable(name: "opencore", targets: ["opencore"]),
        .library(name: "OpenCoreCompanion", targets: ["CoreCompanion"]),
        .library(name: "OpenCoreCompanionHost", targets: ["CoreCompanionHost"]),
        .library(name: "OpenCoreReviewSupport", targets: ["CoreStore", "CoreTelemetry"]),
        .library(name: "OpenCorePresentation", targets: ["CorePresentation"]),
    ],
    targets: [
        // Layer 0 — vocabulary. Value types only, no I/O, no dependencies.
        .target(name: "CoreModel"),
        .target(name: "CoreCompanion"),

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
        .target(name: "CoreCompanionHost", dependencies: ["CoreCompanion", "CoreModel", "CoreStore", "CoreSearch", "CoreReason"]),

        // UI state is testable independently from app startup and its controller singletons.
        .target(name: "CorePresentation", dependencies: ["CoreModel", "CoreSearch", "CoreStore"]),

        // Layer 4 — surfaces.
        .target(name: "CoreMCP", dependencies: ["CoreModel", "CoreStore", "CoreGraph", "CoreSearch", "CoreReason", "CoreJSONRPC", "CoreTelemetry"]),

        .executableTarget(
            name: "opencore",
            dependencies: ["CoreModel", "CoreJSONRPC", "CoreTelemetry", "CoreStore", "CoreIngest", "CoreGraph", "CoreSearch", "CoreReason", "CoreMCP"]
        ),

        .testTarget(name: "CorePresentationTests", dependencies: ["CorePresentation", "CoreStore", "CoreModel"]),
        .testTarget(name: "CoreStoreTests", dependencies: ["CoreStore", "CoreModel"]),
        .testTarget(name: "CoreGraphTests", dependencies: ["CoreGraph", "CoreReason", "CoreSearch", "CoreIngest", "CoreJSONRPC", "CoreStore", "CoreModel", "CoreTelemetry"]),
        .testTarget(name: "CoreReasonTests", dependencies: ["CoreReason", "CoreSearch", "CoreStore", "CoreModel"]),
        .testTarget(name: "CoreSearchTests", dependencies: ["CoreSearch", "CoreStore", "CoreModel"]),
        .testTarget(name: "CoreMCPTests", dependencies: ["CoreMCP", "CoreReason", "CoreGraph", "CoreSearch", "CoreIngest", "CoreStore", "CoreModel", "CoreJSONRPC"]),
        .testTarget(name: "CoreTelemetryTests", dependencies: ["CoreTelemetry"]),
        .testTarget(name: "CoreCompanionTests", dependencies: ["CoreCompanion", "CoreCompanionHost", "CoreStore", "CoreModel", "CoreSearch", "CoreReason"]),
    ]
)

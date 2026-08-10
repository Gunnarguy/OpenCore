import Foundation
import Testing

@testable import CoreTelemetry

/// Serialized, and each test resets first: `Telemetry` is deliberately a process-wide singleton
/// so instrumentation deep in `CoreStore` needs no plumbing, and the cost of that choice is
/// that its own tests cannot run concurrently against it.
@Suite(.serialized)
struct TelemetrySuite {

    private func fresh() async {
        await Telemetry.reset()
        Telemetry.enable()
    }

    @Test("a span opened inside another becomes its child with nothing threaded through")
    func spansNestByTaskLocal() async throws {
        await fresh()

        // The point of the task-local: `inner` is opened by a function that was handed no
        // span, no context object and no parameter. If this regresses, every call site
        // between CoreStore and the CLI has to grow an argument.
        func inner() async {
            await Telemetry.span("inner", .store) { _ in }
        }

        await Telemetry.span("outer", .cli) { _ in
            await inner()
        }

        let spans = await Telemetry.collected()
        let outer = try #require(spans.first { $0.name == "outer" })
        let child = try #require(spans.first { $0.name == "inner" })

        #expect(child.parentID == outer.id)
        #expect(outer.parentID == nil)
    }

    @Test("a span that throws is recorded before the error propagates")
    func failedSpansAreStillMeasured() async throws {
        await fresh()
        struct Boom: Error {}

        await #expect(throws: Boom.self) {
            try await Telemetry.span("doomed", .ingest) { _ in throw Boom() }
        }

        // A run that failed halfway is exactly when the tree is worth reading, so the failed
        // span must be present rather than swallowed with the error.
        let span = try #require(await Telemetry.collected().first { $0.name == "doomed" })
        #expect(span.failure != nil)
        #expect(span.milliseconds != nil)
    }

    @Test("counters accumulate additively across a loop")
    func countersAccumulate() async throws {
        await fresh()

        await Telemetry.span("chunking", .graph) { scope in
            for _ in 0..<5 { scope.count("chunks", 3) }
            scope.set("objects", 2)
            scope.set("objects", 7)  // set replaces, count adds
        }

        let span = try #require(await Telemetry.collected().first { $0.name == "chunking" })
        #expect(span.counters["chunks"] == 15)
        #expect(span.counters["objects"] == 7)
    }

    @Test("nothing is recorded while telemetry is disabled")
    func disabledRecordsNothing() async throws {
        await Telemetry.reset()
        Telemetry.disable()
        defer { Telemetry.enable() }

        await Telemetry.span("expensive", .search) { scope in
            scope.count("rows", 1000)
        }
        Telemetry.event("skipped", .search)

        // Off means off. The body still runs, so instrumentation never changes behaviour.
        #expect(await Telemetry.collected().isEmpty)
    }

    @Test("an unclosed span reports no duration rather than a plausible one")
    func openSpansStayUnmeasured() async throws {
        await fresh()

        // Opened directly, never closed, which is what a crash mid-span leaves behind.
        _ = Telemetry.recorder.openSync(category: .store, name: "orphan", parent: nil)

        let span = try #require(await Telemetry.collected().first { $0.name == "orphan" })
        // "Unmeasured stays nil" is a project-wide invariant, and a duration invented for an
        // unfinished span is exactly the plausible default it exists to forbid.
        #expect(span.elapsedNanoseconds == nil)
        #expect(span.milliseconds == nil)
        #expect(TelemetryReport.tree([span]).contains("open"))
    }

    @Test("the tree renders parents above their children and survives a dropped parent")
    func treeRendersHierarchy() async throws {
        await fresh()

        await Telemetry.span("sync", .cli) { _ in
            await Telemetry.span("fetch", .ingest) { scope in
                scope.set("objects", 651)
            }
            await Telemetry.span("pipeline", .graph) { _ in
                await Telemetry.span("chunk", .graph) { _ in }
            }
        }

        let tree = TelemetryReport.tree(await Telemetry.collected())
        let lines = tree.split(separator: "\n").map(String.init)

        #expect(try #require(lines.firstIndex { $0.contains("sync") }) < #require(lines.firstIndex { $0.contains("fetch") }))
        #expect(try #require(lines.firstIndex { $0.contains("pipeline") }) < #require(lines.firstIndex { $0.contains("chunk") }))
        #expect(tree.contains("objects=651"))

        // An orphan whose parent is missing must still appear. Re-parenting to the root is
        // what stops a buffer-cap drop from silently deleting whole subtrees from the report.
        let orphan = TelemetrySpan(
            id: 999_999, parentID: 424_242, category: .store, name: "orphaned-query",
            startedAt: Date(), elapsedNanoseconds: 1_000_000, counters: [:], attributes: [:], failure: nil
        )
        #expect(TelemetryReport.tree([orphan]).contains("orphaned-query"))
    }

    @Test("summary attributes time to the layer that spent it, not to its callers")
    func summaryUsesSelfTime() async throws {
        await fresh()

        await Telemetry.span("outer", .cli) { _ in
            await Telemetry.span("inner", .store) { _ in
                try? await Task.sleep(for: .milliseconds(30))
            }
        }

        let summary = TelemetryReport.summary(await Telemetry.collected())
        // Summing total time per layer would double-count every parent and report far more
        // time than the run actually took, which makes the percentages meaningless.
        let storeLine = try #require(summary.split(separator: "\n").first { $0.contains("store") })
        let cliLine = try #require(summary.split(separator: "\n").first { $0.contains("cli") })

        func milliseconds(_ line: Substring) -> Double {
            Double(line.split(separator: " ").first { $0.hasSuffix("ms") }?.dropLast(2) ?? "0") ?? 0
        }
        #expect(milliseconds(storeLine) > milliseconds(cliLine))
    }

    @Test("every span round-trips through JSONL")
    func jsonlRoundTrips() async throws {
        await fresh()
        await Telemetry.span("query", .store, attributes: ["sql": "objects"]) { $0.set("rows", 12) }

        let spans = await Telemetry.collected()
        let lines = try TelemetryReport.jsonl(spans).split(separator: "\n")
        #expect(lines.count == spans.count)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TelemetrySpan.self, from: Data(lines[0].utf8))
        #expect(decoded.counters["rows"] == 12)
        #expect(decoded.attributes["sql"] == "objects")
    }
}

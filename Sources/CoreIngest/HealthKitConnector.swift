import CoreModel
import Foundation

#if canImport(HealthKit)
import HealthKit
#endif

/// Apple Health.
///
/// HealthKit **is** available on macOS: `HKHealthStore` is annotated `macos(13.0)` and the
/// framework ships in the macOS SDK. The obvious assumption that this needs an iOS companion
/// app or an export file is wrong, and was checked before this was written.
///
/// ## Everything here is `.medical`, and that is not configurable
///
/// This is the first source OpenCore ingests that is unambiguously medical, and the domain
/// firewall was built for exactly it. A project question cannot reach any of this, and the MCP
/// server cannot expose it regardless of how a tool call is worded. Offering a domain picker
/// would let a user defeat the one protection that matters most, so there isn't one.
///
/// ## What is ingested, and what is deliberately not
///
/// **Not** the raw sample stream. Millions of heart-rate readings would swamp the store and
/// mean nothing as retrievable passages. What goes in is the shape that can carry a claim:
/// workouts, sleep, and daily aggregates.
///
/// **Never** an inferred health conclusion. `workout(type, date, duration)` is a fact read from
/// a structured field. Anything resembling a diagnosis, a trend, or a judgement about someone's
/// health is not OpenCore's to write, and putting one in the claim table at `derivedPattern`
/// authority would be the most damaging thing this project could ship. Facts only.
///
/// Read-only: authorization is requested `toShare: []`, so OpenCore cannot write to a health
/// record even by accident.
public struct HealthKitConnector: Connector {
    public let source: Source
    private let lookBackDays: Int

    public init(lookBackDays: Int = 365) {
        self.lookBackDays = lookBackDays
        self.source = Source(
            kind: .manual,
            handle: "apple-health",
            displayName: "Apple Health",
            // The device recorded it; the user did not write it. A workout is a third-party
            // record about them, not testimony from them.
            defaultAuthority: .thirdPartyRecord,
            defaultDomain: .medical
        )
    }

    public enum HealthError: Error, CustomStringConvertible {
        case unavailable
        case noInfoPlist
        case denied

        public var description: String {
            switch self {
            case .unavailable:
                "HealthKit is not available on this Mac."
            case .noInfoPlist:
                """
                HealthKit needs NSHealthShareUsageDescription in the calling binary's \
                Info.plist, which a SwiftPM executable does not have. Run this sync from the \
                OpenCore app.
                """
            case .denied:
                "Health access was denied. Grant it in System Settings › Privacy & Security › Health."
            }
        }
    }

    public func fetch(since: Date?, cursor: String?, log: @Sendable (String) -> Void) async throws -> ConnectorBatch {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        guard Bundle.main.object(forInfoDictionaryKey: "NSHealthShareUsageDescription") != nil else {
            throw HealthError.noInfoPlist
        }

        let store = HKHealthStore()
        let readTypes: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
            HKObjectType.quantityType(forIdentifier: .stepCount),
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
        ].compactMap { $0 }.reduce(into: Set<HKObjectType>()) { $0.insert($1) }

        // toShare is empty on purpose. OpenCore has no business writing to a health record.
        try await store.requestAuthorization(toShare: [], read: readTypes)

        let start = since ?? Date().addingTimeInterval(-Double(lookBackDays) * 86_400)
        var objects: [CoreObject] = []

        objects += try await workouts(store: store, since: start, log: log)
        objects += try await dailySteps(store: store, since: start, log: log)

        return ConnectorBatch(objects: objects, cursor: ISO8601DateFormatter().string(from: Date()))
        #else
        throw HealthError.unavailable
        #endif
    }

    #if canImport(HealthKit)
    private func workouts(store: HKHealthStore, since: Date, log: @Sendable (String) -> Void) async throws -> [CoreObject] {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: Date())
        let sourceID = source.id

        // Mapping happens inside the callback: HKWorkout is a reference type and is not
        // Sendable, so returning samples and mapping afterwards would move them across an
        // isolation boundary, which Swift 6 correctly rejects.
        let objects: [CoreObject] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, _ in
                let formatter = ISO8601DateFormatter()
                let mapped = (samples as? [HKWorkout] ?? []).map { workout -> CoreObject in
                    let minutes = Int(workout.duration / 60)
                    let name = Self.name(for: workout.workoutActivityType)

                    var text = "\(name) workout, \(minutes) minutes"
                    text += "\nStarted: \(formatter.string(from: workout.startDate))"
                    if let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                        .sumQuantity()?.doubleValue(for: .kilocalorie()) {
                        text += "\nEnergy: \(Int(energy)) kcal"
                    }
                    if let distance = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?
                        .sumQuantity()?.doubleValue(for: .mile()) {
                        text += "\nDistance: \(String(format: "%.2f", distance)) miles"
                    }

                    return CoreObject(
                        sourceID: sourceID,
                        kind: .note,
                        externalID: "workout:\(workout.uuid.uuidString)",
                        title: "\(name), \(minutes) min",
                        text: text,
                        uri: nil,
                        authoredAt: workout.startDate,
                        domain: .medical,
                        authority: .thirdPartyRecord,
                        metadata: [
                            "health_kind": "workout",
                            "activity": name,
                            "duration_minutes": String(minutes),
                        ]
                    )
                }
                continuation.resume(returning: mapped)
            }
            store.execute(query)
        }

        log("health: \(objects.count) workouts")
        return objects
    }

    /// Daily step totals rather than individual samples.
    ///
    /// One object per day. A year is 365 rows; the same period as raw samples would be
    /// hundreds of thousands, none of which says anything a day total does not.
    private func dailySteps(store: HKHealthStore, since: Date, log: @Sendable (String) -> Void) async throws -> [CoreObject] {
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return [] }
        let sourceID = source.id
        let anchor = Calendar.current.startOfDay(for: since)

        let objects: [CoreObject] = await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: stepType,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: since, end: Date()),
                options: .cumulativeSum,
                anchorDate: anchor,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, _ in
                var mapped: [CoreObject] = []
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"

                collection?.enumerateStatistics(from: since, to: Date()) { statistics, _ in
                    guard let steps = statistics.sumQuantity()?.doubleValue(for: .count()), steps > 0 else { return }
                    let day = formatter.string(from: statistics.startDate)
                    mapped.append(CoreObject(
                        sourceID: sourceID,
                        kind: .note,
                        externalID: "steps:\(day)",
                        title: "\(Int(steps)) steps",
                        text: "\(Int(steps)) steps on \(day)",
                        uri: nil,
                        authoredAt: statistics.startDate,
                        domain: .medical,
                        authority: .thirdPartyRecord,
                        metadata: ["health_kind": "steps", "day": day, "steps": String(Int(steps))]
                    ))
                }
                continuation.resume(returning: mapped)
            }
            store.execute(query)
        }

        log("health: \(objects.count) days of step totals")
        return objects
    }

    /// A readable name for the handful of activity types worth naming. Anything else keeps its
    /// raw value rather than being guessed at.
    static func name(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "Running"
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .swimming: "Swimming"
        case .hiking: "Hiking"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength training"
        case .highIntensityIntervalTraining: "HIIT"
        case .yoga: "Yoga"
        case .rowing: "Rowing"
        case .elliptical: "Elliptical"
        case .stairClimbing: "Stair climbing"
        case .coreTraining: "Core training"
        default: "Activity \(type.rawValue)"
        }
    }
    #endif
}

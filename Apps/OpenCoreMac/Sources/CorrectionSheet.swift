import CoreGraph
import CoreModel
import CoreStore
import SwiftUI

extension AppModel {
    /// Tell the store it is wrong.
    ///
    /// The most distinctive idea in this project's design and, until now, unreachable:
    /// `BeliefEngine.correct` existed, was tested, and had no caller in any surface.
    ///
    /// A correction does not edit the wrong claim. It asserts a new one at `directStatement`
    /// authority, retracts the old, and records **why the old belief was reachable** — the
    /// part that lets the extractor be fixed rather than the symptom patched.
    func correct(
        claim wrong: CoreClaim,
        to newValue: String,
        reason: String,
        priorFailure: String?
    ) async -> String {
        guard let store else { return "store is not open" }
        do {
            // Resolve to an entity when one exists, so the correction lands in the graph
            // rather than as a dangling string.
            let resolved = try await store.resolve(surface: newValue).first?.0

            let asserted = CoreClaim(
                subject: wrong.subject,
                predicate: wrong.predicate,
                objectEntity: resolved?.id,
                literal: resolved == nil ? newValue : nil,
                confidence: 1.0,
                authority: .directStatement,
                derivation: .corrected,
                validity: Validity(validFrom: wrong.validity.validFrom, observedAt: Date()),
                domain: wrong.domain
            )

            try await BeliefEngine(store: store).correct(
                supersedingClaim: wrong.id,
                with: asserted,
                reason: reason,
                priorFailure: priorFailure?.isEmpty == true ? nil : priorFailure
            )

            await loadClaims()
            await refresh()
            return "Corrected. The old claim is retracted, not deleted; see Beliefs and Contradictions."
        } catch {
            return "failed: \(error)"
        }
    }
}

struct CorrectionSheet: View {
    let row: AppModel.ClaimRow
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var newValue = ""
    @State private var reason = ""
    @State private var priorFailure = ""
    @State private var working = false
    @State private var outcome: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Form {
                SwiftUI.Section {
                    LabeledContent("Subject", value: row.subject)
                    LabeledContent("Predicate", value: row.predicate)
                    LabeledContent {
                        Text(row.value).foregroundStyle(.secondary).strikethrough(!newValue.isEmpty)
                    } label: {
                        Text("Currently")
                    }
                    LabeledContent("Authority", value: row.claim.authority.label)
                } header: {
                    Text("What it believes")
                } footer: {
                    Text(row.claim.derivation == .observed
                         ? "Read directly from source data. Correcting it means the source is wrong, or the extractor read it wrong."
                         : "Inferred, not observed. These are the ones most worth correcting.")
                }

                SwiftUI.Section {
                    TextField("Corrected value", text: $newValue)
                    TextField("Why is it wrong?", text: $reason, axis: .vertical).lineLimit(2...4)
                } header: {
                    Text("The correction")
                } footer: {
                    Text("Your statement enters at the highest authority tier and outranks anything the extractor concluded.")
                }

                SwiftUI.Section {
                    TextField("What made the old belief reachable?", text: $priorFailure, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Diagnosis (optional, and the useful part)")
                } footer: {
                    Text("Storing only the new value teaches nothing. Recording why the wrong belief looked right is what lets the extractor be fixed instead of the symptom patched.")
                }

                if let outcome {
                    SwiftUI.Section { Text(outcome).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Correct a belief").font(.headline)
                Text("Nothing is deleted. The old claim is retracted and kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if working { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Correct") { Task { await apply() } }
                .keyboardShortcut(.defaultAction)
                .disabled(working || newValue.trimmingCharacters(in: .whitespaces).isEmpty
                          || reason.trimmingCharacters(in: .whitespaces).isEmpty
                          || newValue == row.value)
        }
        .padding()
    }

    private func apply() async {
        working = true
        defer { working = false }
        outcome = await model.correct(
            claim: row.claim,
            to: newValue.trimmingCharacters(in: .whitespacesAndNewlines),
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
            priorFailure: priorFailure.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        // Leave the sheet open briefly so the outcome is readable rather than flashing past.
        try? await Task.sleep(nanoseconds: 900_000_000)
        dismiss()
    }
}

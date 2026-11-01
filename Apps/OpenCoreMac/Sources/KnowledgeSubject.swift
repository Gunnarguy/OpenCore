import CoreModel
import SwiftUI

/// A visible UI scope, not a domain-admission grant or a change to the underlying records.
struct KnowledgeSubject: Hashable, Sendable {
    let id: EntityID
    let name: String
}

struct KnowledgeBrowseKey: Hashable {
    let generation: Int
    let subject: KnowledgeSubject?
}

struct KnowledgeSubjectBanner: View {
    let subject: KnowledgeSubject
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Subject: \(subject.name)", systemImage: "line.3.horizontal.decrease.circle")
                .font(.callout.weight(.semibold))
                .textSelection(.enabled)
            Spacer()
            Button("Show all subjects", action: clear)
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Pastel.sky.opacity(0.08))
    }
}

/// Every destination receives the same actual entity ID. Excerpt search is explicitly a
/// text query, while Statements and Decisions use the exact subject identity.
struct KnowledgeSubjectActions: View {
    @Environment(\.appModel) private var model
    let subject: KnowledgeSubject
    var compact = false
    var beforeNavigate: () -> Void = {}

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 8) { buttons }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 8) { buttons }
            }
        }
        .controlSize(.small)
    }

    private var buttons: some View {
        Group {
            Button {
                beforeNavigate()
                model.openStatements(for: subject)
            } label: {
                Label("Statements", systemImage: Section.claims.symbol)
            }
            .accessibilityLabel("Statements about \(subject.name)")

            Button {
                beforeNavigate()
                model.openDecisions(for: subject)
            } label: {
                Label("Decisions", systemImage: Section.beliefs.symbol)
            }
            .accessibilityLabel("Decisions about \(subject.name)")

            Button {
                beforeNavigate()
                model.showingInspector = false
                model.openPassages(query: subject.name)
            } label: {
                Label("Find excerpts", systemImage: Section.passages.symbol)
            }
            .accessibilityLabel("Find excerpts mentioning \(subject.name)")

            Button {
                beforeNavigate()
                model.showingInspector = false
                model.openEntity(id: subject.id)
            } label: {
                Label("Topic overview", systemImage: Section.entities.symbol)
            }
            .accessibilityLabel("Topic overview for \(subject.name)")
        }
    }
}

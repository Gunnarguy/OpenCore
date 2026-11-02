import SwiftUI

/// The same small orientation pattern appears in every workspace. Detailed explanations live
/// in the map, leaving the actual data and controls room to work.
struct WorkspaceOrientationView: View {
    @Environment(\.appModel) private var model
    let section: Section

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: section.symbol)
                    .foregroundStyle(section.family.tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.guide.role).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(section.guide.purpose).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button {
                    model.showingWorkspaceMap = true
                } label: {
                    Label("How it connects", systemImage: "map")
                }
                .controlSize(.small)
                .help("See when to use this workspace and follow a project through related views")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text(section.family.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 3)
                    ForEach(section.family.sections) { destination in
                        Button {
                            model.followWorkspace(to: destination)
                        } label: {
                            Text(destination.guide.shortName)
                                .font(.caption.weight(destination == section ? .bold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(destination == section ? section.family.tint.opacity(0.16) : .clear, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(destination == section ? .primary : .secondary)
                        .accessibilityLabel("Open \(destination.rawValue): \(destination.guide.shortName)")
                        .accessibilityValue(destination == section ? "Current workspace" : "")
                        .help(destination.guide.purpose)
                    }
                    Divider().frame(height: 14)
                    Button(section.guide.nextAction) {
                        model.followWorkspace(to: section.guide.next)
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }
            }
            .frame(height: 28)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        Divider()
    }
}

struct WorkspaceMapView: View {
    @Environment(\.appModel) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProjectID = ""

    private var project: AppModel.ProjectBrief? {
        model.projectBriefs.first { $0.id.value == selectedProjectID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("How OpenCore fits together").font(.title2.weight(.bold))
                    Text("Choose an outcome. Each workspace is a different view or action on your work.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    currentWorkspace
                    projectExample
                    evidenceRoutes
                    ForEach(WorkspaceFamily.allCases.filter { $0 != .evidence && $0 != .ask }) { family in
                        familyCard(family)
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 760, idealWidth: 940, minHeight: 560, idealHeight: 720)
        .onChange(of: model.projectBriefs.map { $0.id.value }, initial: true) { _, ids in
            guard !ids.contains(selectedProjectID) else { return }
            if let subject = model.knowledgeSubject(for: model.selectedSection), ids.contains(subject.id.value) {
                selectedProjectID = subject.id.value
            } else {
                selectedProjectID = model.projectBriefs.first(where: { $0.name == "OpenCore" })?.id.value ?? ids.first ?? ""
            }
        }
    }

    private var currentWorkspace: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("You are here: \(model.selectedSection.rawValue)", systemImage: model.selectedSection.symbol)
                .font(.headline)
            Text(model.selectedSection.guide.useWhen).foregroundStyle(.secondary)
            HStack {
                Button(model.selectedSection.guide.nextAction) { open(model.selectedSection.guide.next, followingSubject: true) }
                Button("Ask") { open(.ask) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: model.selectedSection.family.tint)
    }

    private var projectExample: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try the connections with one of your projects").font(.headline)
            if model.projectBriefs.isEmpty {
                Text("No project briefs are loaded. Start by checking an imported original or syncing a source.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Browse originals") { open(.corpus) }
                    Button("Check sources") { open(.sources) }
                }
            } else {
                Picker("Project from your records", selection: Binding(
                    get: { project == nil ? "" : selectedProjectID },
                    set: { selectedProjectID = $0 }
                )) {
                    Text("Choose a project…").tag("")
                    ForEach(model.projectBriefs) { brief in
                        Text(brief.name).tag(brief.id.value)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                if let project {
                    KnowledgeSubjectActions(subject: KnowledgeSubject(id: project.id, name: project.name)) {
                        dismiss()
                    }
                    Text("Statements and Decisions follow this exact subject. Find excerpts searches its name in source text. Inspect evidence on any statement to open the original record.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.sky)
    }

    private var evidenceRoutes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Follow the evidence").font(.headline)
            Text("The same original records support two useful routes. An item can have searchable excerpts without producing a structured statement.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                routeButton(.sources)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                routeButton(.corpus)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Read the source words").font(.caption.weight(.semibold))
                    routeButton(.passages)
                    Text("Searchable excerpts retain their original record and location.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Inspect the interpretation").font(.caption.weight(.semibold))
                    HStack {
                        routeButton(.claims)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        routeButton(.beliefs)
                    }
                    Text("Claims are extracted statements. Beliefs record selections and revisions; neither is a guarantee of truth.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                routeButton(.ask)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                routeButton(.receipts)
            }
            Text("An answer can cite excerpts or statements. Its receipt records the evidence and measurements captured by that answer path.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: Pastel.mint)
    }

    private func familyCard(_ family: WorkspaceFamily) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(family.rawValue).font(.headline)
            Text(family.purpose).font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(family.sections) { section in
                    Button { open(section) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(section.rawValue, systemImage: section.symbol).font(.callout.weight(.semibold))
                            Text(section.guide.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                        .padding(10)
                        .background(family.tint.opacity(0.07), in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openCoreGlassCard(cornerRadius: 12, tint: family.tint)
    }

    private func routeButton(_ section: Section) -> some View {
        Button { open(section) } label: {
            Label(section.guide.shortName, systemImage: section.symbol)
                .font(.callout.weight(.semibold))
        }
        .controlSize(.small)
        .help("\(section.rawValue): \(section.guide.purpose)")
    }

    private func open(_ section: Section, followingSubject: Bool = false) {
        dismiss()
        if followingSubject { model.followWorkspace(to: section) }
        else { model.navigate(to: section) }
    }
}

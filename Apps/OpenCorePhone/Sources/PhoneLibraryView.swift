import CoreCompanion
import SwiftUI

struct PhoneLibraryView: View {
    var body: some View {
        List {
            Section("Explore your knowledge") {
                ForEach([CompanionSection.graph, .claims, .beliefs, .passages, .realityChecks]) { section in
                    NavigationLink { PhoneReadView(section: section) } label: { Label(section.title, systemImage: section.symbol) }
                }
            }
            Section("Evidence through time") {
                ForEach([CompanionSection.receipts, .timeline, .timeTravel]) { section in
                    NavigationLink { PhoneReadView(section: section) } label: { Label(section.title, systemImage: section.symbol) }
                }
            }
            Section("Your store") {
                ForEach([CompanionSection.sources, .corpus]) { section in
                    NavigationLink { PhoneReadView(section: section) } label: { Label(section.title, systemImage: section.symbol) }
                }
            }
        }
        .navigationTitle("Library")
    }
}

struct PhoneReadView: View {
    let section: CompanionSection
    var recordID: String? = nil
    @Environment(PhoneModel.self) private var model
    @State private var page: CompanionPage?
    @State private var records: [CompanionRecord] = []
    @State private var query = ""
    @State private var date = Date()
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        Group {
            if !model.isConnected {
                LockedContentView()
            } else {
                List {
                    if section == .timeTravel {
                        Section {
                            DatePicker("Believed as of", selection: $date, in: ...Date())
                            Button("Read this checkout") { Task { await load() } }.disabled(loading || model.busy)
                        }
                    }
                    if let page {
                        if !page.note.isEmpty { Section { Text(page.note).font(.callout).foregroundStyle(.secondary) } }
                        if !page.metrics.isEmpty { Section { PhoneMetricsView(metrics: page.metrics) } }
                        Section {
                            ForEach(records, id: \.identityBytes) { record in
                                if recordID == nil && (section == .graph || section == .receipts) {
                                    NavigationLink {
                                        PhoneReadView(section: section, recordID: record.id)
                                    } label: { PhoneRecordRow(record: record) }
                                } else {
                                    NavigationLink { PhoneRecordDetail(record: record) } label: { PhoneRecordRow(record: record) }
                                }
                            }
                            if records.isEmpty && !loading { Text("No admitted records in this view.").foregroundStyle(.secondary) }
                            if page.nextOffset != nil {
                                Button("Load more") { Task { await load(more: true) } }.disabled(loading || model.busy)
                            }
                        }
                        Section { Text("Received \(page.generatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let error { Section { Text(error).foregroundStyle(.orange) } }
                    if loading { ProgressView("Reading from your Mac…") }
                    if page == nil && !loading { Button("Read from Mac") { Task { await load() } }.disabled(model.busy) }
                }
                .searchable(text: $query, prompt: section == .passages ? "Search passages on your Mac" : "Search this view")
                .onSubmit(of: .search) { Task { await load() } }
                .refreshable { await load() }
            }
        }
        .navigationTitle(page?.title ?? section.title)
        .navigationBarTitleDisplayMode(.large)
        .task { if page == nil && model.isConnected && !model.busy { await load() } }
    }
    private func load(more: Bool = false) async {
        guard !loading, !model.busy else { return }
        loading = true; defer { loading = false }
        do {
            let request = CompanionRequest(section: section, query: query, recordID: recordID,
                asOf: section == .timeTravel ? date : nil, offset: more ? page?.nextOffset ?? 0 : 0)
            let result = try await model.read(request)
            records = CompanionRecord.appendingDistinct(result.records, to: more ? records : [])
            page = result; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct PhoneRecordRow: View {
    let record: CompanionRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(record.title).font(.headline).foregroundStyle(.primary)
            if !record.body.isEmpty { Text(record.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
            HStack(spacing: 8) {
                if let domain = record.domain { Text(domain.uppercased()).font(.caption2.weight(.semibold)) }
                if let date = record.date { Text(date, format: .dateTime.month(.abbreviated).day().year()).font(.caption) }
            }.foregroundStyle(.secondary)
        }.padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct PhoneRecordDetail: View {
    let record: CompanionRecord
    var body: some View {
        List {
            Section {
                Text(record.title).font(.title3.bold()).textSelection(.enabled)
                if !record.body.isEmpty { Text(record.body).textSelection(.enabled) }
                if let date = record.date { LabeledContent("Recorded", value: date.formatted()) }
                if let domain = record.domain { LabeledContent("Domain", value: domain) }
            }
            if let objectID = record.objectID {
                Section {
                    NavigationLink {
                        PhoneReadView(section: .corpus, recordID: objectID)
                    } label: {
                        Label("Open full source", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            if !record.links.isEmpty {
                Section("Evidence & related records") {
                    ForEach(record.links) { link in
                        NavigationLink {
                            switch link.kind {
                            case .object: PhoneReadView(section: .corpus, recordID: link.targetID)
                            case .entity: PhoneReadView(section: .graph, recordID: link.targetID)
                            case .claim: PhoneReadView(section: .claims, recordID: link.targetID)
                            case .receipt: PhoneReadView(section: .receipts, recordID: link.targetID)
                            }
                        } label: { Label(link.title, systemImage: "arrow.up.right.square") }
                    }
                }
            }
            Section("Details") {
                ForEach(record.fields) { field in
                    DisclosureGroup(field.label) { Text(field.value).font(.callout).textSelection(.enabled) }
                }
                LabeledContent("Record ID", value: record.id).font(.caption).textSelection(.enabled)
            }
        }
        .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
    }
}

struct PhoneMetricsView: View {
    let metrics: [CompanionField]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 20) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 5) {
                    Text(metric.value).font(.title2.bold().monospacedDigit())
                    Text(metric.label).font(.caption).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            }
        }.padding(.vertical, 10)
    }
}

struct LockedContentView: View {
    @Environment(PhoneModel.self) private var model
    var body: some View {
        ContentUnavailableView {
            Label(model.state == .offline ? "Your Mac is unreachable" : "Your history stays private", systemImage: model.state == .offline ? "network.slash" : "lock.shield")
        } description: {
            Text(model.state == .unpaired ? "Pair this iPhone from the Connection tab to begin." : "Unlock from Connection. Your Mac must be awake with OpenCore and Tailscale running.")
            if let date = model.lastReachable { Text("Last reached \(date.formatted()).") }
        }
    }
}

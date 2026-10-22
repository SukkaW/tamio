//
//  SnippetView.swift
//  TamioMobile
//
//  Snippet cards with their SF Symbol, group, comment, the command on
//  `terminal-bg`, and Run… (server picker, then the run sheet): the Mac's
//  Snippets page.
//

import MachineStatusView
import SwiftUI
import TamioModule

struct SnippetView: View {
    @EnvironmentObject var store: TamioStore
    @State private var searchText = ""
    @State private var groupFilter: String?
    @State private var creating = false
    @State private var editing: RDSnippet.ID?

    var groupNames: [String] {
        Set(store.snippetGroup.snippets.map(\.group)).filter { !$0.isEmpty }.sorted()
    }

    var filtered: [RDSnippet] {
        var result = store.snippetGroup.snippets
        if let groupFilter {
            result = result.filter { $0.group == groupFilter }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.isQualifiedForSearch(text: searchText) }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                if store.snippetGroup.snippets.isEmpty {
                    EmptyStateView(
                        "No snippets yet",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        actionTitle: "New Snippet"
                    ) {
                        creating = true
                    }
                    .rxCard()
                } else if filtered.isEmpty {
                    EmptyStateView("No matches", systemImage: "magnifyingglass")
                        .rxCard()
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280), spacing: RX.Space.s4, alignment: .top)],
                        alignment: .leading,
                        spacing: RX.Space.s4
                    ) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, snippet in
                            SnippetTile(snippet: snippet, run: { SnippetActions.run(snippet.id) }, edit: { editing = snippet.id }) {
                                Button("Run…") { SnippetActions.run(snippet.id) }
                                Button("Edit…") { editing = snippet.id }
                                Button("Duplicate") { SnippetActions.duplicate(snippet.id) }
                                Button("Copy Command") { UIBridge.sendPasteboard(str: snippet.code) }
                                Divider()
                                Button("Delete…", role: .destructive) { SnippetActions.delete(snippet.id) }
                            }
                            .rxRise(index)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                        }
                    }
                    .animation(.rxMove, value: filtered.map(\.id))
                }
            }
            .padding(.horizontal, RX.Space.s4)
            .padding(.top, RX.Space.s1)
            .padding(.bottom, RX.Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RXBackdrop().ignoresSafeArea())
        .navigationTitle("Snippets")
        .searchable(text: $searchText, prompt: "Search snippets")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !groupNames.isEmpty {
                    Menu {
                        Picker("Group", selection: $groupFilter) {
                            Text("All Groups").tag(String?.none)
                            Divider()
                            ForEach(groupNames, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    } label: {
                        Label(groupFilter ?? String(localized: "All Groups"), systemImage: "folder")
                    }
                    .help(String(localized: "Filter by group"))
                }
                Button { creating = true } label: {
                    Label("New Snippet", systemImage: "plus")
                }
            }
        }
        .onChange(of: groupNames) { names in
            if let groupFilter, !names.contains(groupFilter) { self.groupFilter = nil }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { EditSnippetView() }
        }
        .sheet(item: Binding(get: { editing.map(EditingID.init) }, set: { editing = $0?.id })) { item in
            NavigationStack { EditSnippetView(requestSnippet: item.id) }
        }
    }

    private struct EditingID: Identifiable {
        let id: RDSnippet.ID
    }
}

@MainActor
enum SnippetActions {
    static func run(_ id: RDSnippet.ID) {
        let snippet = TamioStore.shared.snippetGroup[id]
        guard !snippet.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            UIBridge.presentError(with: String(localized: "This snippet has no command to run."))
            return
        }
        TamioUtil.createExecuteFor(snippet: snippet)
    }

    static func duplicate(_ id: RDSnippet.ID) {
        var copy = TamioStore.shared.snippetGroup[id]
        copy.id = UUID()
        copy.name += " copy"
        TamioStore.shared.snippetGroup.insert(copy)
    }

    static func delete(_ id: RDSnippet.ID) {
        let snippet = TamioStore.shared.snippetGroup[id]
        UIBridge.requiresConfirmation(
            message: snippet.name.isEmpty ? String(localized: "Delete this snippet?") : String(localized: "Delete \(snippet.name)?"),
            confirmTitle: String(localized: "Delete"),
            destructive: true
        ) { confirmed in
            if confirmed { TamioStore.shared.snippetGroup.delete(id) }
        }
    }
}

//
//  IdentityView.swift
//  TamioMobile
//
//  Identities grouped by group, as on the Mac's list; the editor is pushed
//  over it (the iOS editor is a form of its own, not a panel).
//

import MachineStatusView
import SwiftUI
import TamioModule

struct IdentityView: View {
    @EnvironmentObject var store: TamioStore
    @State private var searchText = ""
    @State private var selection: RDIdentity.ID?
    @State private var creating = false

    var filtered: [RDIdentity] {
        let all = store.identityGroup.shared
        guard !searchText.isEmpty else { return all }
        let key = searchText.lowercased()
        return all.filter {
            $0.name.lowercased().contains(key)
                || $0.group.lowercased().contains(key)
                || $0.comment.lowercased().contains(key)
        }
    }

    var groups: [(name: String, identities: [RDIdentity])] {
        let identities = filtered
        let names = Set(identities.map(\.group)).sorted { lhs, rhs in
            if lhs.isEmpty { return false }
            if rhs.isEmpty { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return names.map { name in
            (name, identities.filter { $0.group == name }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                if store.identityGroup.shared.isEmpty {
                    EmptyStateView(
                        "No identities yet",
                        systemImage: "person",
                        message: "SSH keys you can use on any server, as any user.",
                        actionTitle: "New Key"
                    ) {
                        creating = true
                    }
                    .rxCard()
                } else {
                    list
                }
            }
            .padding(.horizontal, RX.Space.s4)
            .padding(.top, RX.Space.s1)
            .padding(.bottom, RX.Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RXBackdrop().ignoresSafeArea())
        .navigationTitle("Identities")
        .searchable(text: $searchText, prompt: "Search identities")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: {
                    Label("New Key", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { EditIdentityView() }
        }
        .navigationDestination(item: Binding(
            get: { selection.map(Selected.init) },
            set: { selection = $0?.id }
        )) { selected in
            EditIdentityView(requestIdentity: selected.id)
        }
    }

    var list: some View {
        IdentityList(groups: groups, selection: nil, select: { selection = $0 }) { identity in
            Button("Duplicate") { IdentityActions.duplicate(identity.id) }
            Button("Copy Public Key") { UIBridge.sendPasteboard(str: identity.publicKey) }
                .disabled(identity.publicKey.isEmpty)
            Divider()
            Button("Delete…", role: .destructive) { IdentityActions.delete(identity.id) }
        }
    }

    private struct Selected: Identifiable, Hashable { let id: RDIdentity.ID }
}

@MainActor
enum IdentityActions {
    static func duplicate(_ id: RDIdentity.ID) {
        var copy = TamioStore.shared.identityGroup[id]
        guard copy.hasCredentials else { return }
        copy.id = UUID()
        copy.name = copy.displayName + " copy"
        TamioStore.shared.identityGroup.insert(copy)
    }

    static func delete(_ id: RDIdentity.ID) {
        let store = TamioStore.shared
        let identity = store.identityGroup[id]
        let users = store.machineGroup.machines.filter { $0.associatedIdentity == id.uuidString }.count
        UIBridge.requiresConfirmation(
            message: String(localized: "Delete identity \(identity.displayName)?"),
            informative: users > 0
                ? (users == 1 ? String(localized: "1 server uses it and will try automatic identities instead.") : String(localized: "\(users) servers use it and will try automatic identities instead."))
                : String(localized: "Its password and keys are removed from Tamio."),
            confirmTitle: String(localized: "Delete"),
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            store.identityGroup.delete(id)
        }
    }
}

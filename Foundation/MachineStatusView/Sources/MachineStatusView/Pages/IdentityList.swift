//
//  IdentityList.swift
//  MachineStatusView
//
//  Identities grouped by group: each a name, what it is, and how many
//  servers use it.
//

import SwiftUI
import TamioModule

public struct IdentityList<Context: View>: View {
    let groups: [(name: String, identities: [RDIdentity])]
    let selection: RDIdentity.ID?
    let select: (RDIdentity.ID) -> Void
    let context: (RDIdentity) -> Context

    public init(
        groups: [(name: String, identities: [RDIdentity])],
        selection: RDIdentity.ID?,
        select: @escaping (RDIdentity.ID) -> Void,
        @ViewBuilder context: @escaping (RDIdentity) -> Context
    ) {
        self.groups = groups
        self.selection = selection
        self.select = select
        self.context = context
    }

    public var body: some View {
        VStack(spacing: 0) {
            if groups.isEmpty {
                EmptyStateView("No matches", systemImage: "magnifyingglass")
            }
            ForEach(groups, id: \.name) { group in
                TableGroupRow(group.name.isEmpty ? String(localized: "Default") : group.name)
                    .transition(.opacity)
                ForEach(Array(group.identities.enumerated()), id: \.element.id) { index, identity in
                    IdentityRow(identity: identity, selected: selection == identity.id, context: { context(identity) })
                        .onTapGesture { select(identity.id) }
                        .rxRise(index)
                        .transition(.opacity)
                }
            }
        }
        .animation(.rxMove, value: groups.flatMap { $0.identities.map(\.id) })
        .rxCard(padding: RX.Space.s2)
    }
}

private struct IdentityRow<Context: View>: View {
    let identity: RDIdentity
    let selected: Bool
    @ViewBuilder let context: () -> Context
    @EnvironmentObject var store: TamioStore
    @State private var hovered = false

    var usage: Int {
        store.machineGroup.machines.filter { $0.associatedIdentity == identity.id.uuidString }.count
    }

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(identity.displayName)
                    .font(.rxBody)
                    .foregroundStyle(Color.rxInk)
                    .lineLimit(1)
                Text(identity.authDescription)
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
            }
            Spacer()
            Text(usage == 1 ? String(localized: "1 server") : String(localized: "\(usage) servers"))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: RX.tableRowHeight)
        .rxRowBackground(selected: selected, hovered: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu { context() }
    }
}

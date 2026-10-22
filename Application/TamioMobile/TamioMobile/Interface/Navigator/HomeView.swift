//
//  HomeView.swift
//  TamioMobile
//
//  Start page, as on the Mac: every server's live status card in a dense
//  grid, a group switcher, search and New Server in the bar, and the
//  inspector of the card that is selected: beside the cards where the page
//  is wide enough (iPad), over them as a sheet on a phone.
//

import MachineStatusView
import SwiftUI
import TamioModule

struct HomeView: View {
    @EnvironmentObject var store: TamioStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.serverActions) private var actions
    @State private var search = ""
    @State private var selection: RDMachine.ID?
    @State private var pageWidth: CGFloat = 0

    /// Room for the cards and the panel side by side; otherwise the panel
    /// is a sheet.
    static let sideBySideWidth = ServerInspector.width + StatusCardMetrics.minimumWidth + RX.Space.s4 * 3

    var sideBySide: Bool { sizeClass == .regular && pageWidth >= Self.sideBySideWidth }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: RX.Space.s3) {
                    if !sideBySide {
                        // The bar of a phone has no room for the switcher.
                        ScrollView(.horizontal, showsIndicators: false) {
                            HomeGroupSwitcher()
                        }
                    }
                    ServerCardsGrid(search: search, selection: $selection) { machine in
                        ServerMenuItems(machine: machine, includesTools: false)
                    } context: { machine in
                        ServerMenuItems(machine: machine)
                    }
                }
                .padding(.horizontal, RX.Space.s4)
                .padding(.top, RX.Space.s1)
                .padding(.bottom, RX.Space.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            if sideBySide, let selection, store.machineGroup.machines.contains(where: { $0.id == selection }) {
                ServerInspector(machine: selection) { self.selection = nil }
                    .frame(width: ServerInspector.width)
                    .padding(.top, RX.Space.s1)
                    .transition(.move(edge: .trailing).combined(with: .opacity)
                        .animation(.spring(response: 0.3, dampingFraction: 0.9)))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        #if DEBUG
            // TAMIO_PREVIEW_OPEN=inspector shows the first server's inspector.
            .onAppear {
                if ProcessInfo.processInfo.environment["TAMIO_PREVIEW_OPEN"] == "inspector" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { selection = store.machineGroup.machines.first?.id }
                }
            }
        #endif
        .background(RXBackdrop().ignoresSafeArea())
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search servers")
        .toolbar {
            if sideBySide {
                ToolbarItem(placement: .principal) { HomeGroupSwitcher() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { actions.newServer() } label: {
                    Label("New Server", systemImage: "plus")
                }
            }
        }
        // On a phone the inspector comes up over the cards.
        .sheet(item: Binding(
            get: { sideBySide ? nil : selection.map(Selected.init) },
            set: { selection = $0?.id }
        )) { selected in
            ServerInspector(machine: selected.id) { selection = nil }
                .environmentObject(store)
                .environment(\.serverActions, actions)
                .padding(.top, RX.Space.s3)
                .background(RXBackdrop().ignoresSafeArea())
        }
    }

    private struct Selected: Identifiable { let id: RDMachine.ID }
}

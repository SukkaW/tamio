//
//  PortForwardView.swift
//  TamioMobile
//
//  Forwards: orientation, bind, through server, target, status and an
//  on/off switch, as on the Mac.
//

import MachineStatusView
import SwiftUI
import TamioModule

struct PortForwardView: View {
    @EnvironmentObject var store: TamioStore
    @ObservedObject var backend = PortForwardBackend.shared

    @State private var searchText = ""
    @State private var selection: RDPortForward.ID?
    @State private var editor: EditorTarget?

    struct EditorTarget: Identifiable {
        let id = UUID()
        let forward: RDPortForward.ID?
    }

    var filtered: [RDPortForward] {
        let all = store.portForwardGroup.forwards
        guard !searchText.isEmpty else { return all }
        let key = searchText.lowercased()
        return all.filter {
            $0.targetHost.lowercased().contains(key)
                || String($0.targetPort).contains(key)
                || String($0.bindPort).contains(key)
                || ($0.getMachineName() ?? "").lowercased().contains(key)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                if store.portForwardGroup.forwards.isEmpty {
                    EmptyStateView(
                        "No port forwards",
                        systemImage: "arrow.right",
                        actionTitle: "New Port Forward"
                    ) {
                        editor = EditorTarget(forward: nil)
                    }
                    .rxCard()
                } else if filtered.isEmpty {
                    EmptyStateView("No matches", systemImage: "magnifyingglass")
                        .rxCard()
                } else {
                    PortForwardTable(forwards: filtered, selection: $selection, edit: { editor = EditorTarget(forward: $0) }) { forward in
                        let running = backend.sessionExists(withPortForwardID: forward.id)
                        Button("Edit…") { editor = EditorTarget(forward: forward.id) }.disabled(running)
                        Button("Duplicate") { PortForwardActions.duplicate(forward.id) }
                        Button("Copy SSH Command") { UIBridge.sendPasteboard(str: forward.getCommand() ?? "") }
                            .disabled(forward.getCommand() == nil)
                        Divider()
                        Button("Delete…", role: .destructive) { PortForwardActions.delete(forward.id) }
                    }
                }
            }
            .padding(.horizontal, RX.Space.s4)
            .padding(.top, RX.Space.s1)
            .padding(.bottom, RX.Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RXBackdrop().ignoresSafeArea())
        .navigationTitle("Port Forward")
        .searchable(text: $searchText, prompt: "Search forwards")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    for context in backend.container {
                        backend.endSession(withPortForwardID: context.info.id)
                    }
                } label: {
                    Label("Stop All", systemImage: "stop.circle")
                }
                .disabled(backend.container.isEmpty)
                Button { editor = EditorTarget(forward: nil) } label: {
                    Label("New Port Forward", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editor) { target in
            NavigationStack { EditPortForwardView(requestPortForward: target.forward) }
        }
    }
}

@MainActor
enum PortForwardActions {
    static func duplicate(_ id: RDPortForward.ID) {
        var copy = TamioStore.shared.portForwardGroup[id]
        copy.id = UUID()
        TamioStore.shared.portForwardGroup.insert(copy)
    }

    static func delete(_ id: RDPortForward.ID) {
        let forward = TamioStore.shared.portForwardGroup[id]
        UIBridge.requiresConfirmation(
            message: String(localized: "Delete the forward on port \(forward.bindPort)?"),
            confirmTitle: String(localized: "Delete"),
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            PortForwardBackend.shared.endSession(withPortForwardID: id)
            TamioStore.shared.portForwardGroup.delete(id)
        }
    }
}

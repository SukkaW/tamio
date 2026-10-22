//
//  PortForwardView.swift
//  Tamio (macOS)
//
//  Forwards: orientation, bind, through server, target, status and an on/off switch.
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
        PageScaffold(
            search: $searchText,
            searchPrompt: "Search forwards",
            primary: ToolbarAction("New Port Forward", systemImage: "plus", primary: true) {
                editor = EditorTarget(forward: nil)
            },
            trailingMetrics: .single
        ) {
        } trailing: {
            ToolbarAction("Stop All", systemImage: "stop.circle") {
                for context in backend.container {
                    backend.endSession(withPortForwardID: context.info.id)
                }
            }
            .disabled(backend.container.isEmpty)
        } header: {
            PageTitle("Port Forward")
        } content: {
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
                table
            }
        }
        .sheet(item: $editor) { target in
            PortForwardEditorSheet(forward: target.forward) { editor = nil }
                .environmentObject(TamioStore.shared)
        }
        .background {
            // ⌘⌫ deletes the selected row.
            Button("Delete") {
                if let selection { PortForwardActions.delete(selection) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selection == nil)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    var table: some View {
        PortForwardTable(forwards: filtered, selection: $selection, edit: { editor = EditorTarget(forward: $0) }) { forward in
            let running = backend.sessionExists(withPortForwardID: forward.id)
            Button("Edit…") { editor = EditorTarget(forward: forward.id) }.disabled(running)
            Button("Duplicate") { PortForwardActions.duplicate(forward.id) }
            Button("Copy SSH Command") { Dialogs.sendPasteboard(str: forward.getCommand() ?? "") }
                .disabled(forward.getCommand() == nil)
            Divider()
            Button("Delete…", role: .destructive) { PortForwardActions.delete(forward.id) }
        }
    }
}

enum PortForwardActions {
    static func duplicate(_ id: RDPortForward.ID) {
        var copy = TamioStore.shared.portForwardGroup[id]
        copy.id = UUID()
        TamioStore.shared.portForwardGroup.insert(copy)
    }

    @MainActor
    static func delete(_ id: RDPortForward.ID) {
        let forward = TamioStore.shared.portForwardGroup[id]
        Dialogs.requiresConfirmation(
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

/// New / Edit Port Forward.
struct PortForwardEditorSheet: View {
    let forward: RDPortForward.ID?
    let onClose: () -> Void

    @EnvironmentObject var store: TamioStore
    @State private var orientation: RDPortForward.ForwardOrientation = .listenLocal
    @State private var bindPort = ""
    @State private var machine: RDMachine.ID?
    @State private var targetHost = "127.0.0.1"
    @State private var targetPort = ""

    var draft: RDPortForward {
        var result = forward.map { store.portForwardGroup[$0] } ?? RDPortForward()
        result.forwardOrientation = orientation
        result.bindPort = Int(bindPort) ?? 0
        result.usingMachine = machine
        result.targetHost = targetHost.trimmingCharacters(in: .whitespaces)
        result.targetPort = Int(targetPort) ?? 0
        return result
    }

    var body: some View {
        SheetScaffold(
            forward == nil ? String(localized: "New Port Forward") : String(localized: "Edit Port Forward"),
            lead: orientation == .listenLocal ? "This Mac :port → server → target" : "Server :port → this Mac → target"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                RXField("Orientation") {
                    RXSegmented(selection: $orientation, options: [
                        .init(.listenLocal, "Listen local"),
                        .init(.listenRemote, "Listen remote"),
                    ], caps: false, fullWidth: true)
                }
                HStack(alignment: .top, spacing: RX.Space.s4) {
                    RXField("Bind port", error: bindPort.isEmpty || UInt16(bindPort) != nil ? nil : "1–65535") {
                        TextField("5433", text: $bindPort)
                            .textFieldStyle(.rxMono)
                    }
                    .frame(width: 120)
                    RXField("Forward through") {
                        RXPicker(
                            selection: $machine,
                            options: store.machineGroup.machines.map { .init(RDMachine.ID?.some($0.id), $0.name) },
                            placeholder: "Choose a server"
                        )
                    }
                }
                HStack(alignment: .top, spacing: RX.Space.s4) {
                    RXField("Target host") {
                        TextField("127.0.0.1", text: $targetHost)
                            .textFieldStyle(.rxMono)
                            .disableAutocorrection(true)
                    }
                    RXField("Target port", error: targetPort.isEmpty || UInt16(targetPort) != nil ? nil : "1–65535") {
                        TextField("5432", text: $targetPort)
                            .textFieldStyle(.rxMono)
                    }
                    .frame(width: 120)
                }
                if let command = draft.getCommand(), draft.isValid() {
                    RXField("Equivalent command") {
                        CodeBlock(command)
                    }
                }
            }
        } footer: {
            Spacer()
            Button("Cancel", action: onClose)
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                store.portForwardGroup.insert(draft)
                onClose()
            }
            .buttonStyle(.rx)
            .disabled(!draft.isValid())
            Button("Save and Start") {
                let saved = draft
                store.portForwardGroup.insert(saved)
                PortForwardBackend.shared.createSession(withPortForwardID: saved.id)
                onClose()
            }
            .buttonStyle(.rxPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.isValid())
        }
        .frame(width: 520)
        .onAppear {
            guard let forward else { return }
            let read = store.portForwardGroup[forward]
            orientation = read.forwardOrientation
            bindPort = read.bindPort > 0 ? String(read.bindPort) : ""
            machine = read.usingMachine
            targetHost = read.targetHost
            targetPort = read.targetPort > 0 ? String(read.targetPort) : ""
        }
    }
}

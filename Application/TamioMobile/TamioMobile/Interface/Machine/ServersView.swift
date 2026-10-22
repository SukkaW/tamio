//
//  ServersView.swift
//  TamioMobile
//
//  Servers grouped, with redaction and Batch Startup.
//

import MachineStatusView
import TamioModule
import SwiftUI

struct ServersView: View {
    @EnvironmentObject var store: TamioStore
    @ObservedObject var monitors = MonitorCenter.shared
    @State private var searchKey = ""
    @State private var openNewServer = false
    @State private var editing: RDMachine.ID?

    var filtered: [RDMachine] {
        let all = store.machineGroup.machines
        guard !searchKey.isEmpty else { return all }
        return all.filter { $0.isQualifiedForSearch(text: searchKey.lowercased()) }
    }

    var groups: [(name: String, machines: [RDMachine])] {
        let names = Set(filtered.map(\.group)).sorted { lhs, rhs in
            if lhs.isEmpty { return false }
            if rhs.isEmpty { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return names.map { name in
            (name, filtered.filter { $0.group == name }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }

    var body: some View {
        Group {
            if store.machineGroup.machines.isEmpty {
                EmptyStateView(
                    "No servers yet",
                    systemImage: "server.rack",
                    actionTitle: "New Server"
                ) {
                    openNewServer = true
                }
                .frame(maxHeight: .infinity)
                .background(RXBackdrop().ignoresSafeArea())
            } else {
                List {
                    if store.machineRedacted != .none {
                        Section {
                            HStack {
                                Image(systemName: "eye.slash").foregroundStyle(.rxInkSecondary)
                                Text(store.machineRedacted == .all ? "Names and addresses are hidden" : "Addresses are hidden")
                                    .font(.subheadline)
                                    .foregroundStyle(.rxInkSecondary)
                                Spacer()
                                Button("Show") { store.machineRedacted = .none }
                                    .font(.subheadline.weight(.semibold))
                            }
                            .rxListRow()
                        }
                    }
                    ForEach(groups, id: \.name) { group in
                        Section {
                            ForEach(group.machines) { machine in
                                ServerListRow(machine: machine.id, edit: { editing = machine.id })
                                    .rxListRow()
                            }
                        } header: {
                            RXSectionHeader(group.name.isEmpty ? "Default" : group.name)
                        }
                    }
                }
                .rxGroupedList()
                .searchable(text: $searchKey, prompt: "Search servers")
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Redaction", selection: $store.machineRedacted) {
                        Label("Show Everything", systemImage: "eye").tag(RDMachine.RedactedLevel.none)
                        Label("Hide Addresses", systemImage: "eye.slash").tag(RDMachine.RedactedLevel.sensitive)
                        Label("Hide Names and Addresses", systemImage: "eye.slash.fill").tag(RDMachine.RedactedLevel.all)
                    }
                    Divider()
                    Button {
                        ServerActions.batchStartup()
                    } label: {
                        Label("Batch Startup", systemImage: "wind")
                    }
                    .disabled(store.machineGroup.machines.isEmpty)
                } label: {
                    Label("More", systemImage: store.machineRedacted == .none ? "ellipsis.circle" : "eye.slash")
                }
                Button {
                    openNewServer = true
                } label: {
                    Label("New Server", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $openNewServer) {
            NavigationStack { EditMachineView() }
        }
        .sheet(item: Binding(get: { editing.map(EditTarget.init) }, set: { editing = $0?.id })) { target in
            NavigationStack { EditMachineView(requestMachine: target.id) }
        }
    }

    private struct EditTarget: Identifiable { let id: RDMachine.ID }
}

/// A server row: name, address, state; tap for actions.
struct ServerListRow: View {
    let machine: RDMachine.ID
    let edit: () -> Void
    @EnvironmentObject var store: TamioStore
    @ObservedObject var live = LiveStatusCenter.shared

    var body: some View {
        let read = store.machineGroup[machine]
        Menu {
            ServerMenuItems(machine: machine, edit: edit)
        } label: {
            HStack(spacing: RX.Space.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    RedactableText(read.name, redacted: store.machineRedacted == .all)
                        .foregroundStyle(.rxInk)
                        .lineLimit(1)
                    RedactableText("\(read.remoteAddress):\(read.remotePort)", redacted: store.machineRedacted != .none)
                        .font(.rxCode)
                        .foregroundStyle(.rxInkSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if let session = live.session(for: machine), session.status.hasData {
                    ServerRowState(session: session)
                } else {
                    Text(RXFormat.relative(read.lastConnection))
                        .font(.footnote)
                        .foregroundStyle(.rxInkSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                ServerActions.delete(machine)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button(action: edit) {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.rxAccent)
        }
    }
}

/// CPU and memory, and the traffic of the physical interfaces, as the Mac's
/// Servers table shows them.
private struct ServerRowState: View {
    @ObservedObject var session: MonitorSession
    var body: some View {
        let status = session.status
        let physical = status.network.elements.filter { !NetworkFilter.isVirtual($0.device) }
        VStack(alignment: .trailing, spacing: 2) {
            Text("CPU \(RXFormat.percent(Double(status.processor.summary.sumUsed)))% · Mem \(RXFormat.percent(status.memoryUsedPercent))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
            Text("↑ \(RXFormat.rateString(Double(physical.map(\.txBytesPerSec).reduce(0, +)))) ↓ \(RXFormat.rateString(Double(physical.map(\.rxBytesPerSec).reduce(0, +))))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.rxInkTertiary)
        }
    }
}

/// Open Terminal, Monitor, File Transfer; Edit, Duplicate, Copy; Delete.
struct ServerMenuItems: View {
    let machine: RDMachine.ID
    var edit: (() -> Void)?

    var body: some View {
        Section {
            Button { TerminalManager.shared.begin(for: machine) } label: {
                Label("Open Terminal", systemImage: "terminal")
            }
            Button { ServerActions.openMonitor(machine) } label: {
                Label("Open Monitor", systemImage: "waveform.path.ecg")
            }
            Button { FileTransferManager.shared.begin(for: machine) } label: {
                Label("Open File Transfer", systemImage: "arrow.up.arrow.down")
            }
        }
        Section {
            if let edit {
                Button(action: edit) { Label("Edit", systemImage: "pencil") }
            }
            Button { ServerActions.duplicate(machine) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button {
                UIBridge.sendPasteboard(str: TamioStore.shared.machineGroup[machine].getCommand())
            } label: {
                Label("Copy SSH Command", systemImage: "doc.on.doc")
            }
            Button { ServerActions.forgetHostKey(machine) } label: {
                Label("Forget Host Key", systemImage: "key.slash")
            }
        }
        Section {
            Button(role: .destructive) { ServerActions.delete(machine) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

enum ServerActions {
    @MainActor
    static func openMonitor(_ machine: RDMachine.ID) {
        do {
            let existing = MonitorCenter.shared.session(for: machine)
            let session = try MonitorCenter.shared.begin(for: machine)
            // An existing monitor is brought forward even when sessions do
            // not open automatically; a new one waits for the setting.
            guard existing != nil || TamioStore.shared.openInterfaceAutomatically else { return }
            let host = UIHostingController(rootView: DefaultModalPresenter {
                MonitorView(session: session)
            }.environmentObject(TamioStore.shared))
            host.modalTransitionStyle = .coverVertical
            host.modalPresentationStyle = .formSheet
            host.preferredContentSize = preferredPopOverSize
            PresentationQueue.present(next: host)
        } catch {
            UIBridge.presentError(with: "Cannot open monitor")
        }
    }

    static func duplicate(_ machine: RDMachine.ID) {
        var copy = TamioStore.shared.machineGroup[machine]
        guard copy.isNotPlaceholder() else { return }
        copy.id = UUID()
        copy.name += " copy"
        TamioStore.shared.machineGroup.insert(copy)
    }

    /// For a server whose keys were replaced: its next host key is saved.
    @MainActor
    static func forgetHostKey(_ machine: RDMachine.ID) {
        let read = TamioStore.shared.machineGroup[machine]
        guard read.isNotPlaceholder() else { return }
        UIBridge.requiresConfirmation(message: "Forget the host key of \(read.name)? The key it presents next is saved as its key.") { confirmed in
            guard confirmed else { return }
            read.forgetHostKey()
        }
    }

    @MainActor
    static func delete(_ machine: RDMachine.ID) {
        let name = TamioStore.shared.machineGroup[machine].name
        UIBridge.requiresConfirmation(message: "Delete \(name)?") { confirmed in
            guard confirmed else { return }
            if let session = MonitorCenter.shared.session(for: machine) {
                MonitorCenter.shared.end(session.id)
            }
            TamioStore.shared.machineGroup.delete(machine)
            TamioStore.shared.cleanRecentIfNeeded()
        }
    }

    /// Pick servers, then open a terminal for each.
    static func batchStartup() {
        Task {
            let machines = await TamioUtil.selectMachine()
            // Terminals present themselves through PresentationQueue once
            // connected, so the picker sheet still animating out is fine.
            await MainActor.run {
                for machine in machines {
                    TerminalManager.shared.begin(for: machine, force: true)
                }
            }
        }
    }
}

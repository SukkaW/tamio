//
//  PortForwardTable.swift
//  MachineStatusView
//
//  Forwards: orientation, bind, through server, target, status and an on/off
//  switch; on a narrow page two lines per forward.
//

import SwiftUI
import TamioModule

/// Header and rows share these, so the columns line up.
private enum ForwardColumns {
    static let orientation: CGFloat = 120
    static let bind: CGFloat = 90
    static let status: CGFloat = 200
    static let toggle: CGFloat = 52
    static let compactWidth: CGFloat = 600
}

public struct PortForwardTable<Context: View>: View {
    let forwards: [RDPortForward]
    @Binding var selection: RDPortForward.ID?
    let edit: (RDPortForward.ID) -> Void
    let context: (RDPortForward) -> Context
    @State private var width: CGFloat = 900

    public init(
        forwards: [RDPortForward],
        selection: Binding<RDPortForward.ID?>,
        edit: @escaping (RDPortForward.ID) -> Void,
        @ViewBuilder context: @escaping (RDPortForward) -> Context
    ) {
        self.forwards = forwards
        _selection = selection
        self.edit = edit
        self.context = context
    }

    public var body: some View {
        let compact = width < ForwardColumns.compactWidth
        VStack(spacing: 0) {
            if !compact {
                HStack(spacing: 0) {
                    TableHeaderLabel("Orientation").frame(width: ForwardColumns.orientation)
                    TableHeaderLabel("Bind").frame(width: ForwardColumns.bind)
                    TableHeaderLabel("Through").frame(maxWidth: .infinity)
                    TableHeaderLabel("Target").frame(maxWidth: .infinity)
                    Color.clear.frame(width: ForwardColumns.status, height: 1)
                    Color.clear.frame(width: ForwardColumns.toggle, height: 1)
                }
                .padding(.horizontal, RX.Space.s3)
                .frame(height: RX.tableHeaderHeight)
                Hairline()
            }
            ForEach(Array(forwards.enumerated()), id: \.element.id) { index, forward in
                PortForwardRow(forward: forward, compact: compact, selected: selection == forward.id) {
                    selection = forward.id
                } edit: {
                    edit(forward.id)
                } context: {
                    context(forward)
                }
                .rxRise(index)
                .transition(.opacity)
                if compact, index < forwards.count - 1 {
                    Hairline().padding(.horizontal, RX.Space.s3)
                }
            }
        }
        .animation(.rxMove, value: forwards.map(\.id))
        .readWidth($width)
        .rxCard(padding: RX.Space.s2)
    }
}

private struct PortForwardRow<Context: View>: View {
    let forward: RDPortForward
    let compact: Bool
    let selected: Bool
    let select: () -> Void
    let edit: () -> Void
    @ViewBuilder let context: () -> Context

    @EnvironmentObject var store: TamioStore
    @ObservedObject var backend = PortForwardBackend.shared
    @State private var hovered = false

    var running: Bool { backend.sessionExists(withPortForwardID: forward.id) }

    var body: some View {
        let status = PortForwardPresentation(state: backend.lastStatus[forward.id], running: running)
        Group {
            if compact {
                compactRow(status)
            } else {
                wideRow(status)
            }
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: compact ? nil : RX.tableRowHeight)
        .rxRowBackground(selected: selected, hovered: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .gesture(TapGesture(count: 2).onEnded { if !running { edit() } })
        .simultaneousGesture(TapGesture(count: 1).onEnded(select))
        .contextMenu { context() }
    }

    func wideRow(_ status: PortForwardPresentation) -> some View {
        HStack(spacing: 0) {
            orientationTag
                .frame(width: ForwardColumns.orientation, alignment: .leading)
            bindText
                .frame(width: ForwardColumns.bind, alignment: .leading)
            throughText
                .frame(maxWidth: .infinity, alignment: .leading)
            targetText
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(status.status == .danger ? status.text : "")
                .font(.rxBody)
                .foregroundStyle(.rxDanger)
                .lineLimit(1)
                .frame(width: ForwardColumns.status, alignment: .leading)
            toggle
                .frame(width: ForwardColumns.toggle, alignment: .trailing)
        }
    }

    /// Orientation and bind port, the switch at the end; the route under
    /// them, whole.
    func compactRow(_ status: PortForwardPresentation) -> some View {
        HStack(alignment: .center, spacing: RX.Space.s3) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: RX.Space.s2) {
                    orientationTag
                    bindText
                }
                HStack(spacing: RX.Space.s2) {
                    throughText
                    Text("→").foregroundStyle(.rxInkTertiary)
                    targetText
                }
                .fixedSize(horizontal: false, vertical: true)
                if status.status == .danger {
                    Text(status.text)
                        .font(.rxHelp)
                        .foregroundStyle(.rxDanger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            toggle
        }
        .padding(.vertical, RX.Space.s2)
    }

    var orientationTag: some View {
        RXTag(forward.forwardOrientation == .listenLocal ? String(localized: "Listen local") : String(localized: "Listen remote"))
    }

    var bindText: some View {
        // Verbatim: a port is not a number to group with separators.
        Text(verbatim: ":\(forward.bindPort)")
            .font(.rxCode)
            .foregroundStyle(.rxInk)
    }

    var throughText: some View {
        RedactableText(forward.getMachineName() ?? String(localized: "No server"), redacted: store.machineRedacted == .all)
            .font(.rxBody)
            .foregroundStyle(forward.usingMachine == nil ? Color.rxInkSecondary : Color.rxInk)
            .lineLimit(1)
    }

    var targetText: some View {
        Text(verbatim: forward.targetHost.isEmpty ? "—" : "\(forward.targetHost):\(forward.targetPort)")
            .font(.rxCode)
            .foregroundStyle(.rxInk)
    }

    var toggle: some View {
        Toggle("Running", isOn: Binding(get: { running }, set: { on in
            if on {
                backend.createSession(withPortForwardID: forward.id)
            } else {
                backend.endSession(withPortForwardID: forward.id)
            }
        }))
        .labelsHidden()
        .rxSwitchToggle()
        .controlSize(.small)
        .tint(.rxAccent)
        .disabled(!forward.isValid())
        .help(forward.isValid() ? (running ? String(localized: "Stop") : String(localized: "Start")) : String(localized: "Incomplete"))
    }
}

//
//  ServerLive.swift
//  MachineStatusView
//
//  A server's live figures, read from its open monitor or the quiet session
//  behind the cards, and a view that redraws as they change.
//

import SwiftUI
import TamioModule

/// Live figures of a server while its monitor is open.
public struct ServerLiveState {
    public var cpu: Double?
    public var memory: Double?
    public var disk: Double?
    public var receive: Double?
    public var transmit: Double?

    public init(cpu: Double? = nil, memory: Double? = nil, disk: Double? = nil, receive: Double? = nil, transmit: Double? = nil) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.receive = receive
        self.transmit = transmit
    }

    /// From the server's open monitor, else its background status.
    @MainActor
    public static func of(_ machine: RDMachine.ID) -> ServerLiveState {
        guard let session = LiveStatusCenter.shared.session(for: machine),
              session.phase == .connected, session.status.hasData
        else { return ServerLiveState() }
        let status = session.status
        let root = status.fileSystem.elements.first { $0.mountPoint == "/" }
            ?? status.fileSystem.elements.max { $0.percent < $1.percent }
        let physical = status.network.elements.filter { !NetworkFilter.isVirtual($0.device) }
        return ServerLiveState(
            cpu: Double(status.processor.summary.sumUsed),
            memory: status.memoryUsedPercent,
            disk: root.map { Double($0.percent) },
            receive: Double(physical.map(\.rxBytesPerSec).reduce(0, +)),
            transmit: Double(physical.map(\.txBytesPerSec).reduce(0, +))
        )
    }
}

/// Re-renders its content as the server's status changes.
public struct ServerLiveReader<Content: View>: View {
    let machine: RDMachine.ID
    @ViewBuilder let content: (ServerLiveState) -> Content

    @ObservedObject private var live = LiveStatusCenter.shared
    @ObservedObject private var monitors = MonitorCenter.shared

    public init(machine: RDMachine.ID, @ViewBuilder content: @escaping (ServerLiveState) -> Content) {
        self.machine = machine
        self.content = content
    }

    public var body: some View {
        if let session = live.session(for: machine) {
            SessionReader(session: session) { content(ServerLiveState.of(machine)) }
        } else {
            content(ServerLiveState.of(machine))
        }
    }

    private struct SessionReader<Inner: View>: View {
        @ObservedObject var session: MonitorSession
        @ViewBuilder let inner: () -> Inner
        var body: some View { inner() }
    }
}

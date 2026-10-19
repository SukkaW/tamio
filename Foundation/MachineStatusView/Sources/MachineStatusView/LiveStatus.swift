//
//  LiveStatus.swift
//  MachineStatusView
//
//  Keeps every saved server's status current for the server cards and the
//  Servers table, without opening a monitor: one quiet background session per
//  server that has credentials. An open monitor is used instead of its own.
//

import Combine
import Foundation
import TamioModule

@MainActor
public final class LiveStatusCenter: ObservableObject {
    public static let shared = LiveStatusCenter()

    /// Settings › General: whether servers show live status.
    public static let enabledKey = "sb.moe.tamio.liveStatus"

    @Published public private(set) var sessions: [RDMachine.ID: MonitorSession] = [:]
    @Published public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            sync()
        }
    }

    /// What each session was started from, to restart it when the server's
    /// address, user or credentials change.
    private var startedFrom: [RDMachine.ID: Fingerprint] = [:]
    private var cancellables = Set<AnyCancellable>()

    private struct Fingerprint: Equatable {
        let address: String
        let port: String
        let username: String
        let identity: String?
        let secret: String
        let withoutCredentials: Bool

        init(_ machine: RDMachine, _ identity: RDIdentity?) {
            address = machine.remoteAddress
            port = machine.remotePort
            username = machine.loginUsername(with: identity)
            self.identity = machine.associatedIdentity
            secret = (identity?.password ?? "") + (identity?.privateKey ?? "")
            withoutCredentials = machine.signsInWithoutCredentials
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Starts following the store; call once at launch.
    public func start() {
        let store = TamioStore.shared
        store.$machineGroup
            .combineLatest(store.$identityGroup)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.sync() }
            .store(in: &cancellables)
        sync()
    }

    /// The freshest session for a server: its open monitor, else the
    /// background one.
    public func session(for machine: RDMachine.ID) -> MonitorSession? {
        MonitorCenter.shared.session(for: machine) ?? sessions[machine]
    }

    /// Whether a server can be followed: it has a password or key to sign in
    /// with, or signs in with neither.
    public static func canFollow(_ machine: RDMachine) -> Bool {
        machine.isNotPlaceholder() && (machine.signsInWithoutCredentials || TamioStore.shared.associatedIdentity(for: machine) != nil)
    }

    func sync() {
        let store = TamioStore.shared
        let wanted: [RDMachine] = isEnabled ? store.machineGroup.machines.filter(Self.canFollow) : []
        let wantedIDs = Set(wanted.map(\.id))
        for (id, session) in sessions where !wantedIDs.contains(id) {
            session.shutdown()
            sessions[id] = nil
            startedFrom[id] = nil
        }
        for machine in wanted {
            let identity = store.associatedIdentity(for: machine)
            let fingerprint = Fingerprint(machine, identity)
            if sessions[machine.id] != nil, startedFrom[machine.id] == fingerprint { continue }
            sessions[machine.id]?.shutdown()
            sessions[machine.id] = MonitorSession(machine: machine, identity: identity, recordsConnection: false)
            startedFrom[machine.id] = fingerprint
        }
    }
}

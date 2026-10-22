//
//  PortForwardBackend.swift
//  TamioModule
//
//  The session lifecycle lives in PortForwardContext; this backend keeps the
//  container, the per-forward states and validation, for both apps' rows.
//

import Combine
import Foundation

/// The backend and its container are main-thread state, like the rows
/// showing the forwards.
@MainActor
public final class PortForwardBackend: ObservableObject {
    public static let shared = PortForwardBackend()

    private init() {}

    @Published public private(set) var container = [PortForwardContext]()

    @Published public private(set) var lastStatus: [RDPortForward.ID: PortForwardContext.Lifecycle] = [:]

    /// Told of a forward that cannot start (incomplete, or its server gone);
    /// the app shows it as it shows other errors.
    public var reportProblem: ((String) -> Void)?

    public func createSession(withPortForwardID pid: RDPortForward.ID) {
        if sessionExists(withPortForwardID: pid) {
            // multiple start
            return
        }
        let portFwd = TamioStore.shared.portForwardGroup[pid]
        guard portFwd.isValid(),
              let mid = portFwd.usingMachine
        else {
            reportProblem?(String(localized: "Invalid Info"))
            return
        }
        let machine = TamioStore.shared.machineGroup[mid]
        guard machine.isNotPlaceholder() else {
            reportProblem?(String(localized: "Invalid Info"))
            return
        }
        let context = PortForwardContext(
            info: portFwd,
            machine: machine
        )
        context.lifecycleHandler = { [weak self] state in
            self?.putStatus(for: pid, with: state)
        }
        context.terminationHandler = { [weak self] context in
            self?.endLifecycle(for: context)
        }
        container.append(context)
        context.begin()
    }

    /// The lifecycle handler calls from the forward's own queue.
    nonisolated func putStatus(for pid: RDPortForward.ID, with state: PortForwardContext.Lifecycle) {
        // A plain enum value; the compiler cannot see it is one.
        nonisolated(unsafe) let state = state
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.lastStatus[pid] = state }
        }
    }

    /// Removes a finished session's context, so the row's switch turns off.
    /// Called on the main thread by the context's termination handler.
    private func endLifecycle(for context: PortForwardContext) {
        container.removeAll { $0.id == context.id }
    }

    public func sessionExists(withPortForwardID pid: RDPortForward.ID) -> Bool {
        container.first { $0.info.id == pid } != nil
    }

    public func endSession(withPortForwardID pid: RDPortForward.ID) {
        let index = container.firstIndex { $0.info.id == pid }
        putStatus(for: pid, with: .terminating)
        if let index = index {
            let context = container.remove(at: index)
            context.terminate()
        }
    }
}

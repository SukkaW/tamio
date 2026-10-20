//
//  TerminalManager.swift
//  Tamio (macOS)
//
//  Created by Lakr Aream on 2022/3/10.
//

import Combine
import Foundation
import TamioModule

/// The manager and its session list are main-thread state, like the
/// interface showing them.
@MainActor
class TerminalManager: ObservableObject {
    static let shared = TerminalManager()
    private init() {}

    @Published var sessionContexts: [Context] = []

    func createSession(
        withMachineObject machine: RDMachine,
        force: Bool = false,
        completion: @escaping (Context) -> Void = { _ in }
    ) {
        let index = sessionContexts.firstIndex { $0.machine.id == machine.id }
        if index != nil, !force {
            Dialogs.requiresConfirmation(
                message: String(localized: "\(machine.name) already has a terminal open"),
                confirmTitle: String(localized: "Open Another")
            ) { confirmed in
                if confirmed {
                    self.createSession(withMachineObject: machine, force: true, completion: completion)
                }
            }
            return
        }
        let context = Context(machine: machine)
        sessionContexts.append(context)
        completion(context)
    }

    func createSession(withMachineID machineId: RDMachine.ID, completion: @escaping (Context) -> Void = { _ in }) {
        let machine = TamioStore.shared.machineGroup[machineId]
        guard machine.isNotPlaceholder() else {
            Dialogs.presentError(with: String(localized: "This server's details could not be read."))
            return
        }
        createSession(withMachineObject: machine, completion: completion)
    }

    @discardableResult
    func createSession(withCommand command: SSHCommandReader) -> Context {
        let context = Context(command: command)
        sessionContexts.append(context)
        return context
    }

    /// A terminal with a shell on this Mac (#10): the user's login shell,
    /// run by the terminal itself.
    @discardableResult
    func createLocalSession() -> Context {
        let context = Context(localShell: ())
        sessionContexts.append(context)
        return context
    }

    /// A new shell in the place of a local terminal whose shell has exited:
    /// the surface cannot start another in the same one.
    @discardableResult
    func restartLocalSession(_ context: Context) -> Context {
        let fresh = Context(localShell: ())
        if let index = sessionContexts.firstIndex(where: { $0.id == context.id }) {
            sessionContexts[index] = fresh
        } else {
            sessionContexts.append(fresh)
        }
        context.processShutdown()
        return fresh
    }

    func sessionAlive(forContext contextId: Context.ID) -> Bool {
        !(
            sessionContexts
                .first { $0.id == contextId }?
                .closed ?? true
        )
    }

    func closeSession(withMachineID machineId: RDMachine.ID) {
        let index = sessionContexts.firstIndex { $0.machine.id == machineId }
        if let index = index {
            let context = sessionContexts.remove(at: index)
            context.processShutdown()
            context.shell.destroyPermanently()
        }
    }

    func closeSession(withContextID contextId: Context.ID) {
        let index = sessionContexts.firstIndex { $0.id == contextId }
        if let index = index {
            let context = sessionContexts.remove(at: index)
            context.processShutdown()
            context.shell.destroyPermanently()
        }
    }

    func closeAll() {
        for context in sessionContexts {
            context.processShutdown()
            context.shell.destroyPermanently()
        }
        sessionContexts = []
    }
}

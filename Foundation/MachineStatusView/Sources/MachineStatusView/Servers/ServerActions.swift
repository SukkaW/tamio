//
//  ServerActions.swift
//  MachineStatusView
//
//  What the shared server views (cards, table, inspector) ask the app to do:
//  open a tool on a server, edit it, copy text, ask a question. Each app
//  answers in its own way (routes and dialogs on the Mac, presented sheets
//  and alerts on iOS) and hands its answers down through the environment.
//

import SwiftUI
import TamioModule

public struct ServerActionHandlers {
    public var openTerminal: (RDMachine.ID) -> Void
    /// A new terminal that runs the command once signed in.
    public var openTerminalRunning: (RDMachine.ID, String) -> Void
    public var openFiles: (RDMachine.ID) -> Void
    public var openMonitor: (RDMachine.ID) -> Void
    public var edit: (RDMachine.ID) -> Void
    public var newServer: () -> Void
    public var copy: (String) -> Void
    /// A yes-or-no question: the message, a line of consequence, the verb on
    /// the confirming button, whether it is destructive, and the answer.
    public var confirm: (_ message: String, _ informative: String?, _ confirmTitle: String, _ destructive: Bool, _ completion: @escaping (Bool) -> Void) -> Void

    public init(
        openTerminal: @escaping (RDMachine.ID) -> Void,
        openTerminalRunning: @escaping (RDMachine.ID, String) -> Void,
        openFiles: @escaping (RDMachine.ID) -> Void,
        openMonitor: @escaping (RDMachine.ID) -> Void,
        edit: @escaping (RDMachine.ID) -> Void,
        newServer: @escaping () -> Void,
        copy: @escaping (String) -> Void,
        confirm: @escaping (_ message: String, _ informative: String?, _ confirmTitle: String, _ destructive: Bool, _ completion: @escaping (Bool) -> Void) -> Void
    ) {
        self.openTerminal = openTerminal
        self.openTerminalRunning = openTerminalRunning
        self.openFiles = openFiles
        self.openMonitor = openMonitor
        self.edit = edit
        self.newServer = newServer
        self.copy = copy
        self.confirm = confirm
    }

    /// Does nothing: a preview, or a view the app forgot to supply.
    public static let none = ServerActionHandlers(
        openTerminal: { _ in }, openTerminalRunning: { _, _ in }, openFiles: { _ in }, openMonitor: { _ in },
        edit: { _ in }, newServer: {}, copy: { _ in }, confirm: { _, _, _, _, completion in completion(false) }
    )
}

private struct ServerActionHandlersKey: EnvironmentKey {
    static let defaultValue = ServerActionHandlers.none
}

public extension EnvironmentValues {
    var serverActions: ServerActionHandlers {
        get { self[ServerActionHandlersKey.self] }
        set { self[ServerActionHandlersKey.self] = newValue }
    }
}

/// The three ways into a server. Every surface that opens one (cards, table
/// rows, context menus, the session switcher) uses these names, symbols and
/// descriptions, so a button means the same thing wherever it appears.
public enum ServerTool: CaseIterable, Identifiable, Sendable {
    case terminal
    case files
    case monitor

    public var id: Self { self }

    public var title: String {
        switch self {
        case .terminal: return String(localized: "Terminal")
        case .files: return String(localized: "Files")
        case .monitor: return String(localized: "Monitor")
        }
    }

    public var systemImage: String {
        switch self {
        case .terminal: return "terminal"
        case .files: return "folder"
        case .monitor: return "gauge.with.dots.needle.33percent"
        }
    }

    /// Tooltip: what the tool does, in a sentence.
    public var help: LocalizedStringKey {
        switch self {
        case .terminal: return "Open an SSH terminal on this server"
        case .files: return "Browse, upload and download files over SFTP"
        case .monitor: return "Watch CPU, memory, disk and network usage"
        }
    }

    public func show(_ machine: RDMachine.ID, with actions: ServerActionHandlers) {
        switch self {
        case .terminal: actions.openTerminal(machine)
        case .files: actions.openFiles(machine)
        case .monitor: actions.openMonitor(machine)
        }
    }
}

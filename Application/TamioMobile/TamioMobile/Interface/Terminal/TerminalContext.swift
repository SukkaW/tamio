//
//  TerminalContext.swift
//  TamioMobile
//
//  The session core lives in TamioModule.TerminalContext; this shell keeps
//  the platform surface, the stored font size and the auto-present modal.
//

import TamioModule
import SwiftUI
import UIKit
import TamioTerminal

/// Bridges the shared terminal session core to the platform renderer.
final class TerminalSurfaceBridge: TerminalSessionSurface {
    let termInterface = TamioTerminalView()

    func write(_ string: String) {
        termInterface.write(string)
    }

    func setupBellChain(_ callback: @escaping () -> Void) {
        termInterface.setupBellChain(callback: callback)
    }

    func setupBufferChain(_ callback: @escaping (String) -> Void) {
        termInterface.setupBufferChain(callback: callback)
    }

    func setupTitleChain(_ callback: @escaping (String) -> Void) {
        termInterface.setupTitleChain(callback: callback)
    }

    func setupSizeChain(_ callback: @escaping (CGSize) -> Void) {
        termInterface.setupSizeChain(callback: callback)
    }
}

final class TerminalContext: TamioModule.TerminalContext {
    private let surfaceBridge = TerminalSurfaceBridge()
    var termInterface: TamioTerminalView { surfaceBridge.termInterface }

    init(machine: RDMachine) {
        super.init(machine: machine, surface: surfaceBridge)
        termInterface.setTerminalFontSize(with: TamioStore.shared.terminalFontSize)
    }

    init(command: SSHCommandReader) {
        super.init(command: command, surface: surfaceBridge)
        termInterface.setTerminalFontSize(with: TamioStore.shared.terminalFontSize)
    }
}

extension TerminalContext {
    struct DefaultPresent: View {
        let context: TerminalContext

        var body: some View {
            DefaultModalPresenter {
                TerminalView(context: context)
            }
        }
    }
}

/// Bridges TamioModule's shared terminal core to UIKit UI.
final class IOSTerminalUIHandler: TerminalUIHandler {
    func autoOpenInterface(_ context: TamioModule.TerminalContext) {
        // Called on the main thread, as the protocol says; the context is
        // passed through as a Sendable so the compiler lets it cross.
        nonisolated(unsafe) let context = context
        MainActor.assumeIsolated { present(context) }
    }

    @MainActor private func present(_ context: TamioModule.TerminalContext) {
        guard let context = context as? TerminalContext else { return }
        let host = UIHostingController(
            rootView: TerminalContext.DefaultPresent(context: context)
        )
        host.modalTransitionStyle = .coverVertical
        // iPhone: the terminal is full screen with the key bar above the keyboard.
        host.modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .phone ? .fullScreen : .formSheet
        host.preferredContentSize = preferredPopOverSize
        // A batch of terminals can bootstrap while the picker sheet is
        // still animating out; the queue holds each present until the way
        // is clear instead of dropping it on the floor.
        PresentationQueue.present(next: host)
    }
}

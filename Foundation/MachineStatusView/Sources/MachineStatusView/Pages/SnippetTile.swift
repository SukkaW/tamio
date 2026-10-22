//
//  SnippetTile.swift
//  MachineStatusView
//
//  A snippet card: its SF Symbol, name, group and comment, the command on
//  `terminal-bg`, and Run…. A double click (a tap, on a phone) edits it.
//

import SwiftUI
import TamioModule

public struct SnippetTile<Context: View>: View {
    let snippet: RDSnippet
    let run: () -> Void
    let edit: () -> Void
    let context: () -> Context
    @State private var hovered = false

    public init(snippet: RDSnippet, run: @escaping () -> Void, edit: @escaping () -> Void, @ViewBuilder context: @escaping () -> Context) {
        self.snippet = snippet
        self.run = run
        self.edit = edit
        self.context = context
    }

    var detail: String {
        [snippet.group, snippet.comment].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s3) {
            HStack(alignment: .top, spacing: RX.Space.s3) {
                SymbolTile(snippet.getSFAvatar())
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.name.isEmpty ? String(localized: "Untitled") : snippet.name)
                        .font(.rxBodyStrong)
                        .foregroundStyle(.rxInk)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        HelpText(detail)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: RX.Space.s2)
                Button("Run…", action: run)
                    .buttonStyle(.rx(size: .small))
            }
            CodeBlock(snippet.code.trimmingCharacters(in: .whitespacesAndNewlines), lineLimit: 4)
        }
        .rxCard()
        .scaleEffect(hovered ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .contentShape(RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous))
        .onHover { hovered = $0 }
        #if os(macOS)
            .onTapGesture(count: 2, perform: edit)
        #else
            .onTapGesture(perform: edit)
        #endif
        .contextMenu { context() }
    }
}

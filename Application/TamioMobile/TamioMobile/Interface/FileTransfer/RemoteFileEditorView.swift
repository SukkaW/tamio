//
//  RemoteFileEditorView.swift
//  TamioMobile
//
//  Edits a text file on the server: reads it over SFTP, edits it in the
//  Runestone editor, and writes it back with Save (⌘S). Closing with unsaved
//  changes asks first.
//

import TamioEditor
import TamioModule
import SwiftUI

struct RemoteFileEditorView: View {
    @ObservedObject var context: FileTransferContext
    let remotePath: String

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case loading
        case editing
        case failed(String)
    }

    @State private var phase = Phase.loading
    @State private var text = ""
    @State private var savedText = ""
    @State private var language = EditorLanguage.plain
    @State private var caret = EditorCaret(line: 1, column: 1)
    @State private var wrapsLines = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var confirmClose = false

    private var name: String { (remotePath as NSString).lastPathComponent }
    private var isEdited: Bool { phase == .editing && text != savedText }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .interactiveDismissDisabled(isEdited)
        .confirmationDialog("Save changes to \(name)?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Save") { Task { if await save() { dismiss() } } }
            Button("Don't Save", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your changes are lost if you don't save them.")
        }
        .alert("Couldn't Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Opening \(name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            EmptyStateView(
                "Can't open \(name)",
                systemImage: "doc.badge.ellipsis",
                message: message,
                actionTitle: "Try Again"
            ) {
                Task { await load() }
            }
            .padding(RX.Space.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .editing:
            CodeEditor(text: $text, language: language, wrapsLines: wrapsLines) { caret = $0 }
                .ignoresSafeArea(.container, edges: .bottom)
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        }
    }

    /// Language, caret position and whether there are unsaved changes.
    private var statusBar: some View {
        HStack(spacing: RX.Space.s3) {
            Menu {
                Picker("Syntax", selection: $language) {
                    ForEach(EditorLanguage.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Text(language.title)
            }
            .help("Syntax highlighting")
            Text("Ln \(caret.line), Col \(caret.column)")
                .monospacedDigit()
            Spacer()
            if isEdited {
                Text("Edited")
                    .foregroundStyle(.rxWarning)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.rxInkSecondary)
        .padding(.horizontal, RX.Space.s4)
        .frame(height: 30)
        .background(.bar)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
                if isEdited { confirmClose = true } else { dismiss() }
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $wrapsLines) {
                Label("Wrap Lines", systemImage: "text.word.spacing")
            }
            .help("Wrap long lines")
            .disabled(phase != .editing)
            if saving {
                ProgressView()
            } else {
                Button("Save") { Task { await save() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isEdited)
            }
        }
    }

    private func load() async {
        phase = .loading
        // The transfer context serialises its own SFTP calls; the view only
        // hands it the path, so the hop off the main actor is safe.
        nonisolated(unsafe) let context = context
        do {
            let loaded = try await context.readText(at: remotePath)
            text = loaded
            savedText = loaded
            let firstLine = loaded.prefix { $0 != "\n" }
            language = EditorLanguage.detect(fileName: name, firstLine: String(firstLine))
            phase = .editing
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    private func save() async -> Bool {
        let snapshot = text
        saving = true
        defer { saving = false }
        nonisolated(unsafe) let context = context
        do {
            try await context.writeText(snapshot, to: remotePath)
            savedText = snapshot
            context.loadCurrentFileList()
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}

#if DEBUG
    /// The editor on a sample file, with no server: launch a debug build with
    /// TAMIO_PREVIEW_EDITOR=1 to check highlighting and layout.
    struct EditorPreviewScreen: View {
        @State private var text = """
        #!/usr/bin/env bash
        # Rotate logs and restart the service.
        set -euo pipefail

        LOG_DIR="/var/log/web"
        KEEP=7

        rotate() {
            local file="$1"
            if [[ -s "$file" ]]; then
                mv "$file" "$file.$(date +%Y%m%d)"
            fi
        }

        for log in "$LOG_DIR"/*.log; do
            rotate "$log"
        done
        find "$LOG_DIR" -name '*.log.*' -mtime +"$KEEP" -delete
        systemctl restart web.service   # pick up new log handles
        """
        @State private var caret = EditorCaret(line: 1, column: 1)

        var body: some View {
            NavigationStack {
                CodeEditor(text: $text, language: .bash) { caret = $0 }
                    .navigationTitle("rotate-logs.sh")
                    .navigationBarTitleDisplayMode(.inline)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        HStack {
                            Text("Shell")
                            Text("Ln \(caret.line), Col \(caret.column)").monospacedDigit()
                            Spacer()
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.rxInkSecondary)
                        .padding(.horizontal, RX.Space.s4)
                        .frame(height: 30)
                        .background(.bar)
                    }
            }
        }
    }
#endif

//
//  SSHAgentKeys.swift
//  Tamio (macOS)
//
//  The public keys an SSH agent holds, read with ssh-add -L, so an identity
//  can name the one to offer. Only public keys: an agent never hands out a
//  private one.
//

import Foundation

enum SSHAgentKeys {
    struct Key: Hashable {
        /// The whole line, "ssh-ed25519 AAAA… comment", as an identity keeps it.
        let line: String
        let type: String
        let comment: String

        /// "MacBook key · ed25519", or the end of the key when it has no comment.
        var title: String {
            let kind = type.replacingOccurrences(of: "ssh-", with: "").replacingOccurrences(of: "ecdsa-sha2-nistp", with: "ecdsa-")
            if !comment.isEmpty { return "\(comment) · \(kind)" }
            let body = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            return "\(kind) …\(body.suffix(8))"
        }

        init?(line: String) {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }
            self.line = line.trimmingCharacters(in: .whitespaces)
            type = parts[0]
            comment = parts.count > 2 ? parts[2] : ""
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The agent at `socket` ("~/…" allowed), or SSH_AUTH_SOCK's when nil.
    static func list(socket: String?) async throws -> [Key] {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
            process.arguments = ["-L"]
            var environment = ProcessInfo.processInfo.environment
            if let socket, !socket.isEmpty {
                environment["SSH_AUTH_SOCK"] = (socket as NSString).expandingTildeInPath
            }
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            // An agent that hangs must not hang the editor.
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning {
                process.terminate()
                throw Failure(message: String(localized: "The SSH agent did not answer."))
            }
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            switch process.terminationStatus {
            case 0:
                return text.split(whereSeparator: \.isNewline).compactMap { Key(line: String($0)) }
            case 1:
                // ssh-add says "The agent has no identities." this way.
                return []
            default:
                throw Failure(message: socket?.isEmpty == false
                    ? String(localized: "No SSH agent answers at this socket. Is it running?")
                    : String(localized: "No SSH agent answers at SSH_AUTH_SOCK. Is one running?"))
            }
        }.value
    }
}

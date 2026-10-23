//
//  SSHAgentAuthTests.swift
//  TamioModuleTests
//
//  Signing in with a key an SSH agent holds, or one the identity stores,
//  against a real sshd run as this user on a free local port, and a real
//  ssh-agent holding a fresh key.
//

#if os(macOS)
    import Foundation
    import NSRemoteShell
    @testable import TamioModule
    import XCTest

    final class SSHAgentAuthTests: XCTestCase {
        private var directory: URL!
        private var port = 0
        private var processes: [Process] = []
        private var agentSocket: String { directory.appendingPathComponent("a.sock").path }

        override func setUpWithError() throws {
            for tool in ["/usr/sbin/sshd", "/usr/bin/ssh-agent", "/usr/bin/ssh-add", "/usr/bin/ssh-keygen"] {
                try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool), "\(tool) is needed")
            }
            // Short, because a socket's path is limited to 104 bytes.
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("ta-\(UUID().uuidString.prefix(6))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try run("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", path("host"))
            try run("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "accepted", "-f", path("accepted"))
            try run("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "refused", "-f", path("refused"))
            try FileManager.default.copyItem(atPath: path("accepted.pub"), toPath: path("authorized_keys"))

            port = Int.random(in: 30000 ... 60000)
            try """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(path("host"))
            PidFile \(path("sshd.pid"))
            AuthorizedKeysFile \(path("authorized_keys"))
            StrictModes no
            UsePAM no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            """.write(toFile: path("sshd_config"), atomically: true, encoding: .utf8)
            try start("/usr/sbin/sshd", "-D", "-e", "-f", path("sshd_config"))
            try start("/usr/bin/ssh-agent", "-D", "-a", agentSocket)
            try waitFor { FileManager.default.fileExists(atPath: self.agentSocket) }
            try waitFor { self.portIsOpen() }
        }

        override func tearDown() {
            for process in processes where process.isRunning { process.terminate() }
            processes.forEach { $0.waitUntilExit() }
            if port > 0 { KnownHosts.shared.forget(host: "127.0.0.1", port: port) }
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }

        func testAKeyTheAgentHoldsSignsIn() throws {
            try addToAgent("accepted")
            let (shell, error) = signIn(with: agentIdentity())
            XCTAssertTrue(shell.isAuthenticated, error ?? "")
            shell.destroyPermanently()
        }

        func testEachKeyIsTriedUntilOneIsAccepted() throws {
            try addToAgent("refused")
            try addToAgent("accepted")
            let (shell, error) = signIn(with: agentIdentity())
            XCTAssertTrue(shell.isAuthenticated, error ?? "")
            shell.destroyPermanently()
        }

        // sshd takes RSA keys only with SHA-2 signatures, as OpenSSH has
        // since 8.8.
        func testAnRSAKeyTheAgentHoldsSignsIn() throws {
            try authorizeNewKey("rsa", type: "rsa")
            try addToAgent("rsa")
            let (shell, error) = signIn(with: agentIdentity())
            XCTAssertTrue(shell.isAuthenticated, error ?? "")
            shell.destroyPermanently()
        }

        func testAStoredKeySignsIn() throws {
            for type in ["ed25519", "rsa"] {
                try authorizeNewKey(type, type: type)
                var identity = RDIdentity()
                identity.privateKey = try String(contentsOfFile: path(type), encoding: .utf8)
                identity.publicKey = try String(contentsOfFile: path("\(type).pub"), encoding: .utf8)
                let (shell, error) = signIn(with: identity)
                XCTAssertTrue(shell.isAuthenticated, "\(type): \(error ?? "")")
                shell.destroyPermanently()
            }
        }

        func testANamedKeyIsTheOnlyOneOffered() throws {
            try addToAgent("accepted")
            try addToAgent("refused")
            var identity = agentIdentity()
            identity.publicKey = try String(contentsOfFile: path("refused.pub"), encoding: .utf8)
            let (shell, error) = signIn(with: identity)
            XCTAssertFalse(shell.isAuthenticated, "the accepted key is not offered when another is named")
            XCTAssertEqual(error, "The server did not accept the key from the SSH agent as \(NSUserName()).")
            shell.destroyPermanently()
        }

        func testWhatWentWrongIsSaid() throws {
            let (empty, emptyError) = signIn(with: agentIdentity())
            XCTAssertFalse(empty.isAuthenticated)
            XCTAssertEqual(emptyError, "The SSH agent holds no keys.")
            empty.destroyPermanently()

            try addToAgent("refused")
            var named = agentIdentity()
            named.publicKey = try String(contentsOfFile: path("accepted.pub"), encoding: .utf8)
            let (missing, missingError) = signIn(with: named)
            XCTAssertEqual(missingError, "The SSH agent does not hold the key this identity names.")
            missing.destroyPermanently()

            var nowhere = agentIdentity()
            nowhere.agentSocket = path("nothing.sock")
            let (unreachable, unreachableError) = signIn(with: nowhere)
            XCTAssertEqual(unreachableError, "No SSH agent answers at \(path("nothing.sock")). Is it running?")
            unreachable.destroyPermanently()
        }

        func testAnAgentIdentityIsKeptAndDescribed() {
            var identity = RDIdentity()
            XCTAssertFalse(identity.usesAgent)
            XCTAssertFalse(identity.hasCredentials)
            identity.agentSocket = ""
            XCTAssertTrue(identity.usesAgent, "an empty socket is SSH_AUTH_SOCK's agent")
            XCTAssertTrue(identity.hasCredentials)
            XCTAssertNil(identity.resolvedAgentSocket)
            identity.agentSocket = RDIdentity.onePasswordAgentSocket
            XCTAssertTrue(identity.resolvedAgentSocket?.hasPrefix(NSHomeDirectory()) == true, "~ is the home folder of this Mac")
            XCTAssertEqual(identity.authDescription, "1Password")
            identity.publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOa/gQlTokJ+1fxS7kIwkGUA work"
            XCTAssertEqual(identity.authDescription, "1Password · ed25519")
            identity.agentSocket = nil
            XCTAssertFalse(identity.usesAgent)
        }

        // MARK: - Harness

        private func agentIdentity() -> RDIdentity {
            var identity = RDIdentity()
            identity.agentSocket = agentSocket
            return identity
        }

        private func signIn(with identity: RDIdentity) -> (NSRemoteShell, String?) {
            let shell = NSRemoteShell.configured(host: "127.0.0.1", port: String(port), timeout: 5)
            shell.requestConnectAndWait()
            XCTAssertTrue(shell.isConnected)
            identity.callAuthenticationWith(remote: shell, username: NSUserName())
            return (shell, shell.getLastError())
        }

        private func addToAgent(_ key: String) throws {
            try run("/usr/bin/ssh-add", "-q", path(key), environment: ["SSH_AUTH_SOCK": agentSocket])
        }

        private func authorizeNewKey(_ name: String, type: String) throws {
            try run("/usr/bin/ssh-keygen", "-q", "-t", type, "-N", "", "-C", name, "-f", path(name))
            let line = try String(contentsOfFile: path("\(name).pub"), encoding: .utf8)
            let keys = try FileHandle(forWritingTo: URL(fileURLWithPath: path("authorized_keys")))
            defer { try? keys.close() }
            try keys.seekToEnd()
            try keys.write(contentsOf: Data(line.utf8))
        }

        private func path(_ name: String) -> String {
            directory.appendingPathComponent(name).path
        }

        private func run(_ tool: String, _ arguments: String..., environment: [String: String] = [:]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments.joined(separator: " "))")
        }

        private func start(_ tool: String, _ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            processes.append(process)
        }

        private func waitFor(_ condition: @escaping () -> Bool) throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() {
                guard Date() < deadline else { throw XCTSkip("the local sshd or ssh-agent did not start") }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        private func portIsOpen() -> Bool {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
    }
#endif

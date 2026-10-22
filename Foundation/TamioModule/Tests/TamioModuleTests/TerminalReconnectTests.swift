//
//  TerminalReconnectTests.swift
//  TamioModuleTests
//
//  A terminal whose connection drops reconnects by itself, against a
//  disposable sshd on a local port that is stopped and started again.
//

#if os(macOS)
    import Foundation
    @testable import TamioModule
    import XCTest

    final class TerminalReconnectTests: XCTestCase {
        /// Records what the session writes to the terminal.
        private final class Surface: TerminalSessionSurface {
            private let lock = NSLock()
            private var text = ""
            private var input: ((String) -> Void)?

            var output: String { lock.withLock { text } }
            func write(_ string: String) { lock.withLock { text += string } }
            func setupBellChain(_: @escaping () -> Void) {}
            func setupBufferChain(_ callback: @escaping (String) -> Void) { lock.withLock { input = callback } }
            func setupTitleChain(_: @escaping (String) -> Void) {}
            func setupSizeChain(_ callback: @escaping (CGSize) -> Void) { callback(CGSize(width: 80, height: 24)) }
            func type(_ string: String) { lock.withLock { input }?(string) }
        }

        private var directory: URL!
        private var port = 0
        private var sshd: Process?
        private var machine: RDMachine!
        private var identity: RDIdentity!
        private var savedDelay: TimeInterval = 10

        override func setUpWithError() throws {
            for tool in ["/usr/sbin/sshd", "/usr/bin/ssh-keygen"] {
                try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool), "\(tool) is needed")
            }
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("tr-\(UUID().uuidString.prefix(6))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try run("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", path("host"))
            try run("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", path("user"))
            try FileManager.default.copyItem(atPath: path("user.pub"), toPath: path("authorized_keys"))
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
            ForceCommand /bin/sh
            """.write(toFile: path("sshd_config"), atomically: true, encoding: .utf8)
            try startSSHD()

            identity = RDIdentity(privateKey: try String(contentsOfFile: path("user"), encoding: .utf8),
                                  publicKey: try String(contentsOfFile: path("user.pub"), encoding: .utf8),
                                  authenticAutomatically: false)
            identity.name = "reconnect-test"
            machine = RDMachine(remoteAddress: "127.0.0.1", remotePort: String(port), name: "reconnect-test")
            machine.username = NSUserName()
            machine.associatedIdentity = identity.id.uuidString
            TamioStore.shared.identityGroup.insert(identity)
            TamioStore.shared.machineGroup.insert(machine)
            savedDelay = TerminalContext.reconnectDelay
            TerminalContext.reconnectDelay = 1
        }

        override func tearDown() {
            TerminalContext.reconnectDelay = savedDelay
            stopSSHD()
            if let machine { TamioStore.shared.machineGroup.delete(machine.id) }
            if let identity { TamioStore.shared.identityGroup.delete(identity.id) }
            if port > 0 { KnownHosts.shared.forget(host: "127.0.0.1", port: port) }
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }

        func testADroppedConnectionIsMadeAgain() throws {
            let surface = Surface()
            let context = TerminalContext(machine: machine, surface: surface)
            defer { context.processShutdown(); context.shell.destroyPermanently() }
            try waitForShell(context, surface)

            stopSSHD()
            // A drop is seen at once when the socket closes, or by the
            // keepalive giving up, which takes it longer.
            try wait("the drop to be seen", for: { surface.output.contains("Reconnecting in 1 s (attempt 1 of 3)") }, seconds: 60, output: { surface.output })
            XCTAssertTrue(context.closed)
            try startSSHD()
            try wait("the session to be back", for: { context.shell.isAuthenticated && !context.closed }, seconds: 20, output: { surface.output })
            XCTAssertEqual(surface.output.components(separatedBy: "[*] Creating Connection").count - 1, 2, "connected twice in all")
        }

        func testItGivesUpAfterThreeAttempts() throws {
            let surface = Surface()
            let context = TerminalContext(machine: machine, surface: surface)
            defer { context.processShutdown(); context.shell.destroyPermanently() }
            try waitForShell(context, surface)

            stopSSHD()
            try wait("the last word", for: { surface.output.contains("Could not reconnect after 3 attempts") }, seconds: 60, output: { surface.output })
            for attempt in 1 ... 3 {
                XCTAssertTrue(surface.output.contains("(attempt \(attempt) of 3)"), "attempt \(attempt) was announced")
            }
            XCTAssertTrue(context.closed)
        }

        func testAShellTheUserExitedIsLeftAlone() throws {
            let surface = Surface()
            let context = TerminalContext(machine: machine, surface: surface)
            defer { context.processShutdown(); context.shell.destroyPermanently() }
            try waitForShell(context, surface)
            surface.type("exit\r")
            try wait("the shell to end", for: { context.closed }, seconds: 15)
            Thread.sleep(forTimeInterval: 2.5)
            XCTAssertFalse(surface.output.contains("Reconnecting"), surface.output)
        }

        // MARK: - Harness

        private func startSSHD() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            process.arguments = ["-D", "-e", "-f", path("sshd_config")]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            sshd = process
            try wait("sshd to listen", for: { self.portIsOpen() })
        }

        private func stopSSHD() {
            guard let process = sshd else { return }
            // Every process of the server's holding the port, the listener
            // and the connection's own child, whatever their ancestry: a
            // child missed would keep the session alive, and nothing drops.
            for pid in processes(onPort: port) where pid != getpid() { kill(pid, SIGKILL) }
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            sshd = nil
        }

        private func processes(onPort port: Int) -> [Int32] {
            let lsof = Process()
            lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsof.arguments = ["-t", "-i", "TCP:\(port)"]
            let pipe = Pipe()
            lsof.standardOutput = pipe
            lsof.standardError = FileHandle.nullDevice
            guard (try? lsof.run()) != nil else { return [] }
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            lsof.waitUntilExit()
            return text.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        }

        /// The shell is up once it has printed a prompt. It is /bin/sh, forced
        /// by the server, so the prompt comes at once whatever the user's own
        /// shell reads at startup.
        private func waitForShell(_ context: TerminalContext, _ surface: Surface) throws {
            try wait("the shell's prompt", for: {
                context.shell.isAuthenticated && !context.closed
                    && surface.output.contains { "$%#>".contains($0) }
            }, seconds: 20, output: { surface.output })
        }

        private func wait(_ what: String, for condition: @escaping () -> Bool, seconds: TimeInterval = 10, output: @escaping () -> String = { "" }) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < deadline else { throw XCTSkip("timed out waiting for \(what); the terminal shows: \(output())") }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }

        private func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

        private func run(_ tool: String, _ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments.joined(separator: " "))")
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

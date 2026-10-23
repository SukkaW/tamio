@testable import TamioModule
import XCTest

final class KnownHostsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var hosts: KnownHosts!

    private let first = KnownHosts.HostKey(type: "ssh-ed25519", key: Data([1, 2, 3, 4]))
    private let other = KnownHosts.HostKey(type: "ssh-ed25519", key: Data([9, 9, 9, 9]))

    override func setUp() {
        suite = "sb.moe.tamio.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        hosts = KnownHosts(defaults: defaults, storageKey: "knownHosts")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testTheFirstKeyIsSavedAndAcceptedAgain() {
        XCTAssertTrue(hosts.accepts(first, host: "example.com", port: 22))
        XCTAssertEqual(hosts.savedKey(host: "example.com", port: 22), first)
        XCTAssertTrue(hosts.accepts(first, host: "example.com", port: 22))
        XCTAssertNil(hosts.refusalMessage(host: "example.com", port: 22))
    }

    func testAChangedKeyIsRefusedAndTheSavedOneKept() {
        XCTAssertTrue(hosts.accepts(first, host: "example.com", port: 22))
        XCTAssertFalse(hosts.accepts(other, host: "example.com", port: 22))
        XCTAssertEqual(hosts.savedKey(host: "example.com", port: 22), first)
        XCTAssertEqual(hosts.refusedKey(host: "example.com", port: 22), other)
        let message = hosts.refusalMessage(host: "example.com", port: 22)
        XCTAssertTrue(message?.contains(first.fingerprint) == true)
        XCTAssertTrue(message?.contains(other.fingerprint) == true)
    }

    func testTheSameKeyOfAnotherTypeIsRefused() {
        XCTAssertTrue(hosts.accepts(first, host: "example.com", port: 22))
        let retyped = KnownHosts.HostKey(type: "ssh-rsa", key: first.key)
        XCTAssertFalse(hosts.accepts(retyped, host: "example.com", port: 22))
    }

    func testAKeyIsSavedPerAddressAndPort() {
        XCTAssertTrue(hosts.accepts(first, host: "example.com", port: 22))
        XCTAssertTrue(hosts.accepts(other, host: "example.com", port: 2222))
        XCTAssertTrue(hosts.accepts(other, host: "other.example.com", port: 22))
        XCTAssertTrue(hosts.accepts(first, host: " Example.COM ", port: 22), "an address is the same in any case")
        XCTAssertEqual(hosts.count, 3)
    }

    func testForgettingLetsTheNextKeyIn() {
        XCTAssertTrue(hosts.accepts(first, host: "example.com", port: 22))
        XCTAssertFalse(hosts.accepts(other, host: "example.com", port: 22))
        hosts.forget(host: "example.com", port: 22)
        XCTAssertNil(hosts.refusalMessage(host: "example.com", port: 22))
        XCTAssertTrue(hosts.accepts(other, host: "example.com", port: 22))
        XCTAssertEqual(hosts.savedKey(host: "example.com", port: 22), other)
    }

    func testSavedKeysOutliveTheObject() {
        XCTAssertTrue(hosts.accepts(first, host: "example.com", port: 22))
        let reopened = KnownHosts(defaults: defaults, storageKey: "knownHosts")
        XCTAssertFalse(reopened.accepts(other, host: "example.com", port: 22))
        reopened.forgetAll()
        XCTAssertEqual(reopened.count, 0)
    }

    func testTheSavedKeyIsAskedForByItsOwnName() throws {
        XCTAssertEqual(hosts.preferredAlgorithms(host: "example.com", port: 22), [], "nothing is preferred before a key is saved")

        // The key blobs OpenSSH writes: each opens with its algorithm's name.
        let ecdsa = try XCTUnwrap(Data(base64Encoded: "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHxk"))
        XCTAssertTrue(hosts.accepts(KnownHosts.HostKey(type: "ecdsa-sha2-nistp256", key: ecdsa), host: "example.com", port: 22))
        XCTAssertEqual(hosts.preferredAlgorithms(host: "example.com", port: 22), ["ecdsa-sha2-nistp256"])

        let rsa = try XCTUnwrap(Data(base64Encoded: "AAAAB3NzaC1yc2EAAAADAQABAAABAQ=="))
        XCTAssertEqual(KnownHosts.HostKey(type: "ssh-rsa", key: rsa).algorithms,
                       ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"], "one RSA key answers to each signature name")

        // A certificate's blob names the certificate, where the type the
        // library reports names only the key inside it.
        let certificate = try XCTUnwrap(Data(base64Encoded: "AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAIA=="))
        XCTAssertEqual(KnownHosts.HostKey(type: "ssh-ed25519", key: certificate).algorithms, ["ssh-ed25519-cert-v01@openssh.com"])

        XCTAssertEqual(first.algorithms, ["ssh-ed25519"], "a blob that names nothing falls back to the type")
    }

    func testTheFingerprintIsTheOneSSHPrints() {
        // SHA-256 of an empty key, base64 without padding.
        let empty = KnownHosts.HostKey(type: "ssh-ed25519", key: Data())
        XCTAssertEqual(empty.fingerprint, "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
    }
}

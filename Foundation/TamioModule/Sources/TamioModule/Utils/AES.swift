//
//  AES.swift
//  PTFoundation
//
//  Created by Lakr Aream on 12/15/20.
//

import CommonCrypto
import CryptoKit
import Foundation
import Keychain
import os

#if os(macOS) || targetEnvironment(macCatalyst)
    import IOKit
#endif

/// A keychain the app cannot reach through `SecItem`. A Mac Catalyst process
/// only sees the data-protection keychain, while the AppKit builds of Tamio kept
/// the master key in the login keychain; the app supplies this to carry the key
/// over. Set it before `AES.shared` (and so `TamioStore.shared`) is first used.
public struct LegacyKeyStore: Sendable {
    public enum ReadResult: Sendable {
        case found(String)
        /// There is no key: nothing was ever stored.
        case absent
        /// There may be a key, but it could not be read (access was denied).
        case unavailable
    }

    public let read: @Sendable () -> ReadResult
    public let write: @Sendable (String) -> Bool

    public init(read: @escaping @Sendable () -> ReadResult, write: @escaping @Sendable (String) -> Bool) {
        self.read = read
        self.write = write
    }
}

public struct AES: Sendable {
    private let key: Data
    private let iv: Data

    /// Key material for an engine tried when this one cannot open the data,
    /// so what older DEBUG builds stored under the constant key stays
    /// readable. It never writes: the next save moves the data to this
    /// engine's key.
    private var keyFallback: String?

    /// The key could not be read or saved, so it lasts for this run only.
    /// Nothing is written with such a key: it would replace data that the real
    /// key can still read.
    public private(set) var isEphemeral = false

    private static let legacyKeyStoreStorage = OSAllocatedUnfairLock<LegacyKeyStore?>(initialState: nil)

    /// Set before `AES.shared` (and so `TamioStore.shared`) is first used;
    /// the lock keeps a late read from racing the one-time registration.
    public static var legacyKeyStore: LegacyKeyStore? {
        get { legacyKeyStoreStorage.withLock { $0 } }
        set { legacyKeyStoreStorage.withLock { $0 = newValue } }
    }

    public static let shared: AES = {
        #if DEBUG && (os(macOS) || targetEnvironment(macCatalyst))
            var keyBuilder = legacyDebugKey
            let platformExpert = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching("IOPlatformExpertDevice")
            )
            if platformExpert > 0,
               let serialNumber = (
                   IORegistryEntryCreateCFProperty(
                       platformExpert,
                       kIOPlatformSerialNumberKey as CFString,
                       kCFAllocatorDefault,
                       0
                   )
                   .takeUnretainedValue() as? String
               )
            {
                keyBuilder = serialNumber
                IOObjectRelease(platformExpert)
            }
            return makeEngine(key: keyBuilder + keyBuilder + keyBuilder)
        #else
            let engine = makeKeychainEngine()
            #if DEBUG
                // iOS DEBUG builds stored under the constant key; keep it readable.
                return engine.withLegacyDebugKeyFallback()
            #else
                return engine
            #endif
        #endif
    }()

    #if DEBUG
        /// The master key DEBUG builds used before device-specific derivation:
        /// a constant anyone reading the source knows. Only kept to read what
        /// those builds stored; nothing is written with it any more.
        static let legacyDebugKey = "fdaisohfiuhfq34hifgraskhfiarhfgui34hibrfiuef"

        /// An engine that also reads data stored under `legacyDebugKey`.
        /// Writes still go to this engine's own key.
        func withLegacyDebugKeyFallback() -> AES {
            var copy = self
            copy.keyFallback = Self.legacyDebugKey + Self.legacyDebugKey + Self.legacyDebugKey
            return copy
        }
    #endif

    /// The keychain service and account the master key is kept under. A
    /// debug build launched with TAMIO_ISOLATED_KEY keeps a key of its own: a
    /// benchmark or UI-test copy must never read, replace or remove the key
    /// the user's own Tamio encrypts their servers and keys with.
    public static var masterKeyNames: (service: String, account: String) {
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAMIO_ISOLATED_KEY"] != nil {
                return ("sb.moe.tamio.isolated.kcAccess", "sb.moe.tamio.isolated.MasterCrypto")
            }
        #endif
        return ("sb.moe.tamio.kcAccess", "sb.moe.tamio.MasterCrypto")
    }

    /// A random master key persisted in the keychain, with bridges for the
    /// keys earlier builds kept elsewhere.
    private static func makeKeychainEngine() -> AES {
        let (keychainServiceID, masterKeyID) = masterKeyNames
        let keychain = Keychain(service: keychainServiceID)
            .label("Tamio Master Crypto Key")
            .comment("Tamio requires a master crypto key to access your encrypted data on disk and protects your accounts")

        func stored() throws -> String? {
            if let master = try keychain.getString(masterKeyID), master.count > 2 { return master }
            return nil
        }
        func store(_ new: String) -> Bool {
            do {
                try keychain.remove(masterKeyID)
                try keychain.set(new, key: masterKeyID)
                return true
            } catch {
                debugPrint("AES: keychain write failed: \(error.localizedDescription)")
                return false
            }
        }

        // A read that fails is not a missing key: the key may be there and
        // refused (the login keychain asks before handing it to a new build).
        var key: String?
        var readFailed = false
        for _ in 0 ..< 3 {
            do {
                key = try stored()
                readFailed = false
                break
            } catch {
                readFailed = true
                debugPrint("AES: keychain access failed: \(error.localizedDescription)")
            }
        }
        if let key { return makeEngine(key: key) }

        // The key of an earlier build, kept where this one cannot look.
        if let legacy = legacyKeyStore {
            switch legacy.read() {
            case let .found(master) where master.count > 2:
                // Copied so later launches need not ask for it again. If the
                // copy fails the key is still good, and is fetched again.
                if !readFailed { _ = store(master) }
                return makeEngine(key: master)
            case .unavailable:
                // A key exists and was not handed over. Making a new one
                // would orphan everything saved under the old one.
                debugPrint("AES: the stored master key is unavailable, using an ephemeral key")
                return makeEngine(key: UUID().uuidString, ephemeral: true)
            case .found, .absent:
                break
            }
        } else if readFailed {
            debugPrint("AES: the master key could not be read, using an ephemeral key")
            return makeEngine(key: UUID().uuidString, ephemeral: true)
        }

        // Persist before activating: a key that was never written is lost
        // on the next launch, with the data encrypted under it.
        let new = UUID().uuidString
        if (!readFailed && store(new)) || legacyKeyStore?.write(new) == true {
            return makeEngine(key: new)
        }
        // Without a persisted key, stay usable for this run only.
        debugPrint("AES: no persisted master key, falling back to an ephemeral key")
        return makeEngine(key: UUID().uuidString, ephemeral: true)
    }

    /// Builds an engine whose key doubles as IV. The initializer pads inputs
    /// to the required sizes, so any string of 16+ characters succeeds.
    private static func makeEngine(key: String, ephemeral: Bool = false) -> AES {
        guard var engine = AES(key: key, iv: key) else {
            preconditionFailure("unreachable: key length is sufficient")
        }
        engine.isEphemeral = ephemeral
        return engine
    }

    /// 初始化 AES 引擎
    /// - Parameters:
    ///   - initKey: 要求足够长 大于或等于 32
    ///   - initIV: 要求足够长 大于或等于 16
    internal init?(key initKey: String, iv initIV: String) {
        // 初始化密钥 核查长度要求
        if initKey.count < kCCKeySizeAES128 || initIV.count < kCCBlockSizeAES128 {
            return nil
        }
        // 修改 key 到指定长度
        var initKey = initKey
        while initKey.count < 32 { // 防止意外
            initKey += initKey
        }
        while initKey.count > 32 {
            initKey.removeLast()
        }
        let keyData = Data(initKey.utf8)
        // 修改 iv 到指定长度
        var initIV = initIV
        while initIV.count < kCCBlockSizeAES128 { // 防止意外
            initIV += initIV
        }
        while initIV.count > kCCBlockSizeAES128 {
            initIV.removeLast()
        }
        let ivData = Data(initIV.utf8)
        // 储存
        key = keyData
        iv = ivData
    }

    // MARK: - API

    /// Marks the current format: AES-256-GCM under a random nonce, version 1.
    /// Data without it is the legacy format and is only ever read; the next
    /// write stores it in the current format.
    private static let currentFormatPrefix = Data("RGCM1".utf8)

    public func encrypt(data: Data) -> Data? {
        guard let sealed = try? CryptoKit.AES.GCM.seal(
            data, using: SymmetricKey(data: key)
        ).combined else {
            debugPrint("Error: Failed to encrypt data.")
            return nil
        }
        var result = Self.currentFormatPrefix
        result.append(sealed)
        return result
    }

    public func decrypt(data: Data) -> Data? {
        if data.starts(with: Self.currentFormatPrefix) {
            // GCM refuses a wrong key on its own, so the new key goes first.
            if let plain = open(data: data) { return plain }
            if let plain = fallbackOpen(data: data) { return plain }
        } else {
            // CBC has no integrity: a wrong key still "decrypts" when the
            // last byte happens to pad out. What DEBUG builds stored in this
            // format is under the constant key, so that one goes first.
            if let plain = fallbackOpen(data: data) { return plain }
            if let plain = open(data: data) { return plain }
        }
        debugPrint("Error: Failed to decrypt data.")
        return nil
    }

    /// Decrypts under the fallback key material, if there is any.
    private func fallbackOpen(data: Data) -> Data? {
        guard let material = keyFallback,
              let fallback = AES(key: material, iv: material)
        else { return nil }
        return fallback.open(data: data)
    }

    /// Decrypts with this engine's own key, whichever format the data is in.
    private func open(data: Data) -> Data? {
        guard data.starts(with: Self.currentFormatPrefix) else {
            return legacyDecrypt(data: data)
        }
        guard let box = try? CryptoKit.AES.GCM.SealedBox(
            combined: data.dropFirst(Self.currentFormatPrefix.count)
        ),
            let plain = try? CryptoKit.AES.GCM.open(box, using: SymmetricKey(data: key))
        else {
            return nil
        }
        return plain
    }

    // MARK: - INTERNAL

    /// The legacy format: AES-CBC with PKCS7 padding, the key doubling as
    /// IV and no integrity check. Kept to read what was stored before the
    /// GCM format; it is never written any more.
    private func legacyDecrypt(data: Data) -> Data? {
        crypt(data: data, option: CCOperation(kCCDecrypt))
    }

    private func crypt(data: Data, option: CCOperation) -> Data? {
        let cryptLength = data.count + kCCBlockSizeAES128
        var cryptData = Data(count: cryptLength)

        let keyLength = key.count
        let options = CCOptions(kCCOptionPKCS7Padding)

        var bytesLength = Int(0)

        let status = cryptData.withUnsafeMutableBytes { cryptBytes in
            data.withUnsafeBytes { dataBytes in
                iv.withUnsafeBytes { ivBytes in
                    key.withUnsafeBytes { keyBytes in
                        CCCrypt(option, CCAlgorithm(kCCAlgorithmAES), options, keyBytes.baseAddress, keyLength, ivBytes.baseAddress, dataBytes.baseAddress, data.count, cryptBytes.baseAddress, cryptLength, &bytesLength)
                    }
                }
            }
        }

        guard UInt32(status) == UInt32(kCCSuccess) else {
            debugPrint("Error: Failed to crypt data. Status \(status)")
            return nil
        }

        cryptData.removeSubrange(bytesLength ..< cryptData.count)
        return cryptData
    }
}

//
//  SSI+NetworkInfo.swift
//
//
//  Created by Lakr Aream on 2022/3/2.
//

import Foundation

public extension ServerStatus {
    /// 服务器 NET 信息
    struct NetworkInfo: Codable, Equatable, Hashable {
        public let elements: [NetworkInfoElement]

        public struct NetworkInfoElement: Codable, Equatable, Hashable, Identifiable {
            /// Stable across refreshes: the parser keeps one row per device.
            public var id: String { device }

            public let device: String
            public let rxBytesPerSec: Int
            public let txBytesPerSec: Int
            /// The interface's counters: bytes since the server booted.
            public let rxBytesTotal: Int
            public let txBytesTotal: Int

            public init(device: String, rxBytesPerSec: Int, txBytesPerSec: Int, rxBytesTotal: Int = 0, txBytesTotal: Int = 0) {
                self.device = device
                self.rxBytesPerSec = rxBytesPerSec
                self.txBytesPerSec = txBytesPerSec
                self.rxBytesTotal = rxBytesTotal
                self.txBytesTotal = txBytesTotal
            }

            public func description() -> String {
                """
                interface: \(device)
                rxBytes: \(rxBytesPerSec)/s txBytes: \(txBytesPerSec)/s
                """
            }
        }

        public init() {
            elements = []
        }

        public init(elements: [NetworkInfoElement]) {
            self.elements = elements
        }

        /// Builds from two `/proc/net/dev` payloads sampled `interval`
        /// seconds apart.
        public init?(netDevBefore: String?, netDevAfter: String?, interval: Double = 1) {
            guard let netDevBefore, let netDevAfter else { return nil }

            typealias RxTxPair = (Int, Int)

            func build(str: String) -> [String: RxTxPair] {
                var result = [String: RxTxPair]()
                go: for item in str.components(separatedBy: "\n") where item.contains(":") {
                    let sepName = item.components(separatedBy: ":")
                    if sepName.count != 2 {
                        continue go
                    }
                    guard let name = sepName.first,
                          let payload = sepName.last
                    else {
                        continue go
                    }
                    let key = name.trimmingCharacters(in: .whitespaces)
                    let split = ProcParsers.splitWhitespaceRuns(payload)
                    if split.count < 10 {
                        continue go
                    }
                    // 0     1       2    3    4    5     6          7
                    // bytes packets errs drop fifo frame compressed multicast
                    // 8     9       10   11   12   13    14      15
                    // bytes packets errs drop fifo colls carrier compressed
                    guard let rxBytes = Int(split[0]), // string
                          let txBytes = Int(split[8]) // string
                    else {
                        continue go
                    }
                    if result[key] != nil {
                        result.removeValue(forKey: key)
                        continue
                    }
                    result[key] = (rxBytes, txBytes)
                }
                return result
            }

            let getPriv = build(str: netDevBefore)
            let getCurr = build(str: netDevAfter)
            var result = [NetworkInfoElement]()
            for item in getPriv {
                if let target = getCurr[item.key] {
                    let rxIncrease = target.0 - item.value.0
                    let txIncrease = target.1 - item.value.1
                    if rxIncrease < 0 || txIncrease < 0 {
                        continue
                    }
                    result.append(NetworkInfoElement(
                        device: item.key,
                        rxBytesPerSec: Self.perSecond(rxIncrease, over: interval),
                        txBytesPerSec: Self.perSecond(txIncrease, over: interval),
                        rxBytesTotal: target.0, txBytesTotal: target.1
                    ))
                }
            }

            self.init(elements: result.sorted(by: { a, b in
                a.device < b.device
            }))
        }

        /// Builds from two macOS `netstat -ibn` samples. Only link-level
        /// rows are used so each interface appears once, without its IPv4 and
        /// IPv6 aliases duplicating the same counters.
        public init?(netstatBefore: String?, netstatAfter: String?, interval: Double = 1) {
            guard let netstatBefore, let netstatAfter else { return nil }
            let before = ProcParsers.parseDarwinNetstat(netstatBefore)
            let after = ProcParsers.parseDarwinNetstat(netstatAfter)
            let result = before.compactMap { device, previous -> NetworkInfoElement? in
                guard let current = after[device] else { return nil }
                let rxIncrease = current.rx - previous.rx
                let txIncrease = current.tx - previous.tx
                guard rxIncrease >= 0, txIncrease >= 0 else { return nil }
                return NetworkInfoElement(
                    device: device,
                    rxBytesPerSec: Self.perSecond(rxIncrease, over: interval),
                    txBytesPerSec: Self.perSecond(txIncrease, over: interval),
                    rxBytesTotal: current.rx, txBytesTotal: current.tx
                )
            }
            self.init(elements: result.sorted { $0.device < $1.device })
        }

        /// A counter's growth over `interval` seconds, per second.
        static func perSecond(_ delta: Int, over interval: Double) -> Int {
            guard interval > 0, interval != 1 else { return delta }
            return Int((Double(delta) / interval).rounded())
        }
    }
}

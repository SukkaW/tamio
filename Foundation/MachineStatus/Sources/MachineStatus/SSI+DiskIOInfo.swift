//
//  SSI+DiskIOInfo.swift
//  MachineStatus
//
//  Block device throughput from two /proc/diskstats samples a second apart.
//

import Foundation

public extension ServerStatus {
    struct DiskIOInfo: Codable, Equatable, Hashable {
        public struct Device: Codable, Equatable, Hashable, Identifiable {
            public var id: String { name }

            public let name: String
            public let readBytesPerSec: Int
            public let writeBytesPerSec: Int
            public let readOpsPerSec: Int
            public let writeOpsPerSec: Int
            /// Since the server booted.
            public let readBytesTotal: Int
            public let writeBytesTotal: Int
            /// Milliseconds spent per completed request in the sample, 0 when idle.
            public let readWaitMs: Double
            public let writeWaitMs: Double

            public init(name: String, readBytesPerSec: Int, writeBytesPerSec: Int, readOpsPerSec: Int = 0, writeOpsPerSec: Int = 0,
                        readBytesTotal: Int = 0, writeBytesTotal: Int = 0, readWaitMs: Double = 0, writeWaitMs: Double = 0)
            {
                self.name = name
                self.readBytesPerSec = readBytesPerSec
                self.writeBytesPerSec = writeBytesPerSec
                self.readOpsPerSec = readOpsPerSec
                self.writeOpsPerSec = writeOpsPerSec
                self.readBytesTotal = readBytesTotal
                self.writeBytesTotal = writeBytesTotal
                self.readWaitMs = readWaitMs
                self.writeWaitMs = writeWaitMs
            }
        }

        public let devices: [Device]

        public init() { devices = [] }

        public init(devices: [Device]) { self.devices = devices }

        public var readBytesPerSec: Int { devices.map(\.readBytesPerSec).reduce(0, +) }
        public var writeBytesPerSec: Int { devices.map(\.writeBytesPerSec).reduce(0, +) }

        /// One sample's counters for one device.
        struct Counters {
            var reads = 0, sectorsRead = 0, msReading = 0
            var writes = 0, sectorsWritten = 0, msWriting = 0
        }

        /// /proc/diskstats: major minor name, then reads completed, reads
        /// merged, sectors read, ms reading, writes completed, writes merged,
        /// sectors written, ms writing, … Sectors are 512 bytes whatever the
        /// device's own sector size.
        static func parse(_ payload: String) -> [String: Counters] {
            var result: [String: Counters] = [:]
            for line in payload.split(separator: "\n") {
                let fields = ProcParsers.splitWhitespaceRuns(String(line))
                guard fields.count >= 11 else { continue }
                let numbers = fields[3 ... 10].map { Int($0) ?? 0 }
                result[String(fields[2])] = Counters(
                    reads: numbers[0], sectorsRead: numbers[2], msReading: numbers[3],
                    writes: numbers[4], sectorsWritten: numbers[6], msWriting: numbers[7]
                )
            }
            return result
        }

        /// Whole disks only: no loop, ram or zram devices, and no partition
        /// whose disk is listed too (sda1 of sda, nvme0n1p2 of nvme0n1).
        static func isWholeDisk(_ name: String, among names: Set<String>) -> Bool {
            if name.hasPrefix("loop") || name.hasPrefix("ram") || name.hasPrefix("zram") || name.hasPrefix("fd") || name.hasPrefix("sr") {
                return false
            }
            for other in names where other != name && name.hasPrefix(other) {
                let rest = name.dropFirst(other.count)
                let digits = rest.hasPrefix("p") ? rest.dropFirst() : rest
                if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return false }
            }
            return true
        }

        /// Builds from two `/proc/diskstats` payloads sampled `interval`
        /// seconds apart.
        public init(diskstatsBefore: String?, diskstatsAfter: String?, interval: Double = 1) {
            guard let diskstatsBefore, let diskstatsAfter else {
                self.init()
                return
            }
            let before = Self.parse(diskstatsBefore)
            let after = Self.parse(diskstatsAfter)
            let names = Set(after.keys)
            let devices = after.compactMap { name, now -> Device? in
                guard Self.isWholeDisk(name, among: names), let then = before[name] else { return nil }
                // A device never read nor written (an empty card reader) is noise.
                guard now.reads + now.writes > 0 else { return nil }
                let reads = max(0, now.reads - then.reads)
                let writes = max(0, now.writes - then.writes)
                let perSecond = NetworkInfo.perSecond
                return Device(
                    name: name,
                    readBytesPerSec: perSecond(max(0, now.sectorsRead - then.sectorsRead) * 512, interval),
                    writeBytesPerSec: perSecond(max(0, now.sectorsWritten - then.sectorsWritten) * 512, interval),
                    readOpsPerSec: perSecond(reads, interval),
                    writeOpsPerSec: perSecond(writes, interval),
                    readBytesTotal: now.sectorsRead * 512,
                    writeBytesTotal: now.sectorsWritten * 512,
                    readWaitMs: reads > 0 ? Double(max(0, now.msReading - then.msReading)) / Double(reads) : 0,
                    writeWaitMs: writes > 0 ? Double(max(0, now.msWriting - then.msWriting)) / Double(writes) : 0
                )
            }
            self.init(devices: devices.sorted { $0.name < $1.name })
        }
    }
}

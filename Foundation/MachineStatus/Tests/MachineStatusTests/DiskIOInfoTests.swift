//
//  DiskIOInfoTests.swift
//  MachineStatusTests
//

@testable import MachineStatus
import XCTest

final class DiskIOInfoTests: XCTestCase {
    let before = """
       7       0 loop0 41 0 2210 12 0 0 0 0 0 20 12 0 0 0 0 0 0
     259       0 nvme0n1 1000 10 80000 500 2000 20 160000 4000 0 900 4500 0 0 0 0 0 0
     259       1 nvme0n1p1 900 10 70000 450 1900 20 150000 3900 0 850 4350 0 0 0 0 0 0
       8       0 sda 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
     253       0 dm-0 500 0 40000 200 600 0 48000 1200 0 300 1400 0 0 0 0 0 0
    """
    let after = """
       7       0 loop0 41 0 2210 12 0 0 0 0 0 20 12 0 0 0 0 0 0
     259       0 nvme0n1 1010 10 80400 530 2020 20 164096 4100 0 910 4630 0 0 0 0 0 0
     259       1 nvme0n1p1 910 10 70400 480 1920 20 154096 4000 0 860 4480 0 0 0 0 0 0
       8       0 sda 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
     253       0 dm-0 500 0 40000 200 600 0 48000 1200 0 300 1400 0 0 0 0 0 0
    """

    func testRatesAreSectorDeltasOfWholeDisks() throws {
        let info = ServerStatus.DiskIOInfo(diskstatsBefore: before, diskstatsAfter: after)
        // loop0 and the never-used sda are dropped, and so is the partition of nvme0n1.
        XCTAssertEqual(info.devices.map(\.name), ["dm-0", "nvme0n1"])
        let nvme = try XCTUnwrap(info.devices.first { $0.name == "nvme0n1" })
        XCTAssertEqual(nvme.readBytesPerSec, 400 * 512)
        XCTAssertEqual(nvme.writeBytesPerSec, 4096 * 512)
        XCTAssertEqual(nvme.readOpsPerSec, 10)
        XCTAssertEqual(nvme.writeOpsPerSec, 20)
        XCTAssertEqual(nvme.readWaitMs, 3, accuracy: 0.001)
        XCTAssertEqual(nvme.writeWaitMs, 5, accuracy: 0.001)
        XCTAssertEqual(nvme.writeBytesTotal, 164_096 * 512)
        XCTAssertEqual(info.writeBytesPerSec, 4096 * 512)
    }

    func testRatesScaleToTheSamplingInterval() throws {
        // Samples five seconds apart: the same deltas are a fifth per second.
        let info = ServerStatus.DiskIOInfo(diskstatsBefore: before, diskstatsAfter: after, interval: 5)
        let nvme = try XCTUnwrap(info.devices.first { $0.name == "nvme0n1" })
        XCTAssertEqual(nvme.readBytesPerSec, 400 * 512 / 5)
        XCTAssertEqual(nvme.readOpsPerSec, 2)
        XCTAssertEqual(nvme.writeOpsPerSec, 4)
        // Waits are per operation, not per second.
        XCTAssertEqual(nvme.readWaitMs, 3, accuracy: 0.001)
        let a = "Inter-|Receive\n face |bytes\n  eth0: 1000 10 0 0 0 0 0 0 5000 20 0 0 0 0 0 0\n"
        let b = "Inter-|Receive\n face |bytes\n  eth0: 4000 10 0 0 0 0 0 0 5600 20 0 0 0 0 0 0\n"
        let network = try XCTUnwrap(ServerStatus.NetworkInfo(netDevBefore: a, netDevAfter: b, interval: 3))
        XCTAssertEqual(network.elements.first?.rxBytesPerSec, 1000)
        XCTAssertEqual(network.elements.first?.txBytesPerSec, 200)
        XCTAssertEqual(network.elements.first?.rxBytesTotal, 4000)
    }

    func testMissingSamplesGiveNoDevices() {
        XCTAssertTrue(ServerStatus.DiskIOInfo(diskstatsBefore: nil, diskstatsAfter: after).devices.isEmpty)
    }

    func testNetworkTotalsAreTheLaterCounters() throws {
        let a = "Inter-|Receive\n face |bytes\n  eth0: 1000 10 0 0 0 0 0 0 5000 20 0 0 0 0 0 0\n"
        let b = "Inter-|Receive\n face |bytes\n  eth0: 1600 12 0 0 0 0 0 0 5900 23 0 0 0 0 0 0\n"
        let info = try XCTUnwrap(ServerStatus.NetworkInfo(netDevBefore: a, netDevAfter: b))
        let eth = try XCTUnwrap(info.elements.first)
        XCTAssertEqual(eth.rxBytesPerSec, 600)
        XCTAssertEqual(eth.txBytesPerSec, 900)
        XCTAssertEqual(eth.rxBytesTotal, 1600)
        XCTAssertEqual(eth.txBytesTotal, 5900)
    }
}

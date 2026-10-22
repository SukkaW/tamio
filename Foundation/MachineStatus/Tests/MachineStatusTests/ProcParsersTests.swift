//
//  ProcParsersTests.swift
//  MachineStatusTests
//
//  Fixture-driven tests for the Linux /proc and os-release parsers.
//

@testable import MachineStatus
import XCTest

final class ProcParsersTests: XCTestCase {
    // MARK: - /proc/meminfo

    private let meminfoFixture = """
    MemTotal:       16384000 kB
    MemFree:         1024000 kB
    MemAvailable:    8192000 kB
    Buffers:          512000 kB
    Cached:          4096000 kB
    SwapCached:            0 kB
    SwapTotal:       2097152 kB
    SwapFree:        1048576 kB
    HugePages_Total:       0
    Hugepagesize:       2048 kB
    """

    func testMeminfoParsesKeyedValues() {
        let info = ProcParsers.parseMeminfo(meminfoFixture)
        XCTAssertEqual(info["MEMTOTAL"], 16_384_000)
        XCTAssertEqual(info["MEMFREE"], 1_024_000)
        XCTAssertEqual(info["BUFFERS"], 512_000)
        XCTAssertEqual(info["CACHED"], 4_096_000)
        XCTAssertEqual(info["SWAPTOTAL"], 2_097_152)
        XCTAssertEqual(info["SWAPFREE"], 1_048_576)
        // A kB-suffixed line parses under its uppercased, colon-stripped key.
        XCTAssertEqual(info["HUGEPAGESIZE"], 2048)
        // Lines without a kB suffix are ignored.
        XCTAssertNil(info["HUGEPAGES_TOTAL"])
    }

    func testSwapUsageIsRelativeToSwapTotal() {
        // Regression: swap usage was divided by physical memory total,
        // making the reported swap percentage always wrong.
        let info = ServerStatus.MemoryInfo(
            total: 16_384_000, free: 1_024_000, buffers: 512_000, cached: 4_096_000,
            swapTotal: 2_097_152, swapFree: 1_048_576
        )
        XCTAssertEqual(info.swapUsed, 0.5, accuracy: 0.001)
        XCTAssertEqual(info.phyUsed, (16_384_000 - 1_024_000 - 4_096_000 - 512_000) / 16_384_000, accuracy: 0.001)
    }

    func testZeroSwapDoesNotDivideByZero() {
        let info = ServerStatus.MemoryInfo(
            total: 16_384_000, free: 1_024_000, buffers: 0, cached: 0,
            swapTotal: 0, swapFree: 0
        )
        XCTAssertEqual(info.swapUsed, 0)
        XCTAssertFalse(info.swapUsed.isNaN)
    }

    // MARK: - /proc/stat

    private let procStatFixture = """
    cpu  100 0 200 1600 50 0 10 0 0 0
    cpu0 50 0 100 800 25 0 5 0 0 0
    cpu1 50 0 100 800 25 0 5 0 0 0
    intr 123456
    """

    func testProcStatParsesSummaryAndCores() {
        let (summary, cores) = ProcParsers.parseProcStat(procStatFixture)
        XCTAssertEqual(summary?.user, 100)
        XCTAssertEqual(summary?.idle, 1600)
        XCTAssertEqual(cores["cpu0"]?.system, 100)
        XCTAssertEqual(cores["cpu1"]?.iowait, 25)
        XCTAssertEqual(cores.count, 2)
    }

    func testPercentageBetweenSamples() {
        let (privSum, _) = ProcParsers.parseProcStat(procStatFixture)
        let currRaw = procStatFixture
            .replacingOccurrences(of: "cpu  100", with: "cpu  200") // user +100
        let (currSum, _) = ProcParsers.parseProcStat(currRaw)
        guard let priv = privSum, let curr = currSum else {
            XCTFail("missing summary rows")
            return
        }
        let percent = ProcParsers.calculatePercent(priv: priv, curr: curr)
        // total delta is 100, all of it user time
        XCTAssertEqual(percent.sumUser, 100, accuracy: 0.01)
        XCTAssertEqual(percent.sumUsed, 100, accuracy: 0.01)
    }

    func testIdenticalSamplesYieldZeroNotNaN() {
        // Regression: an idle machine can report identical counters twice;
        // dividing by the zero delta produced NaN/inf percentages.
        let (sum, _) = ProcParsers.parseProcStat(procStatFixture)
        guard let sum else {
            XCTFail("missing summary row")
            return
        }
        let percent = ProcParsers.calculatePercent(priv: sum, curr: sum)
        XCTAssertEqual(percent.sumUsed, 0)
        XCTAssertFalse(percent.sumUsed.isNaN)
        XCTAssertFalse(percent.sumSystem.isInfinite)
    }

    // MARK: - /etc/os-release

    func testOsReleasePrefersPrettyNameAndStripsDoubleQuotes() {
        let fixture = """
        NAME="Ubuntu"
        VERSION_ID="22.04"
        PRETTY_NAME="Ubuntu 22.04.1 LTS"
        """
        XCTAssertEqual(ProcParsers.parseOsReleaseName(fixture), "Ubuntu 22.04.1 LTS")
    }

    func testOsReleaseFallsBackToName() {
        XCTAssertEqual(ProcParsers.parseOsReleaseName("NAME=\"Debian GNU/Linux\""), "Debian GNU/Linux")
    }

    func testOsReleaseStripsSingleQuotes() {
        // Regression: the old condition compared prefixes against double
        // quotes but suffixes against single quotes, so nothing was stripped.
        XCTAssertEqual(ProcParsers.parseOsReleaseName("NAME='Fedora Linux'"), "Fedora Linux")
    }

    func testOsReleaseUnquotedAndMissing() {
        XCTAssertEqual(ProcParsers.parseOsReleaseName("NAME=Alpine Linux"), "Alpine Linux")
        XCTAssertEqual(ProcParsers.parseOsReleaseName(""), "Generic Linux")
    }

    // MARK: - /proc/loadavg

    func testLoadavgParses() {
        let load = ProcParsers.parseLoadavg("0.27 0.34 0.39 2/916 23817")
        XCTAssertEqual(load.load1avg, 0.27, accuracy: 0.001)
        XCTAssertEqual(load.load5avg, 0.34, accuracy: 0.001)
        XCTAssertEqual(load.load15avg, 0.39, accuracy: 0.001)
        XCTAssertEqual(load.runningProcess, 2)
        XCTAssertEqual(load.totalProcess, 916)
    }

    func testLoadavgMalformedReturnsZero() {
        let load = ProcParsers.parseLoadavg("garbage")
        XCTAssertEqual(load.load1avg, 0)
        XCTAssertEqual(load.totalProcess, 0)
    }

    // MARK: - merged monitor script

    private let mergedOutputFixture = """
    <<<TAMIO-SECTION:cpu-a>>>
    cpu  100 0 200 1600 50 0 10 0 0 0
    cpu0 50 0 100 800 25 0 5 0 0 0
    <<<TAMIO-SECTION:net-a>>>
    Inter-|   Receive                                                |  Transmit
     face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        lo: 1000      10    0    0    0     0          0         0     1000      10    0    0    0     0       0          0
      eth0: 5000      50    0    0    0     0          0         0     2000      20    0    0    0     0       0          0
    <<<TAMIO-SECTION:wait>>>
    <<<TAMIO-SECTION:cpu-b>>>
    cpu  200 0 300 3200 100 0 20 0 0 0
    cpu0 100 0 150 1600 50 0 10 0 0 0
    <<<TAMIO-SECTION:uptime>>>
    773229.50 1531748.20
    <<<TAMIO-SECTION:hostname>>>
    web-01
    """

    func testSplitMonitorSectionsAssignsPayloads() {
        let sections = ProcParsers.splitMonitorSections(mergedOutputFixture)
        XCTAssertTrue(sections["cpu-a"]?.contains("cpu0 50") == true)
        XCTAssertTrue(sections["net-a"]?.contains("eth0:") == true)
        XCTAssertEqual(sections["uptime"]?.trimmingCharacters(in: .whitespacesAndNewlines), "773229.50 1531748.20")
        XCTAssertEqual(sections["hostname"]?.trimmingCharacters(in: .whitespacesAndNewlines), "web-01")
        // The sleep marker opens a section with no payload.
        XCTAssertEqual(sections["wait"]?.trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertFalse(sections["cpu-b"]?.contains("cpu0 50") == true)
    }

    func testSplitMonitorSectionsIgnoresInlineMarkerLookalikes() {
        // Only a full-line marker opens a section; payload text containing
        // the marker inside a longer line must not split.
        let raw = """
        <<<TAMIO-SECTION:df>>>
        /dev/sda1 100 50 50 50% /mnt/<<<TAMIO-SECTION:mem>>>-disk
        """
        let sections = ProcParsers.splitMonitorSections(raw)
        XCTAssertNil(sections["mem"])
        XCTAssertTrue(sections["df"]?.contains("/mnt/<<<TAMIO-SECTION:mem>>>-disk") == true)
    }

    func testSplitMonitorSectionsToleratesCarriageReturns() {
        let raw = "<<<TAMIO-SECTION:hostname>>>\r\nweb-01\r\n<<<TAMIO-SECTION:uptime>>>\r\n42 84\r\n"
        let sections = ProcParsers.splitMonitorSections(raw)
        XCTAssertEqual(sections["hostname"]?.trimmingCharacters(in: .whitespacesAndNewlines), "web-01")
        XCTAssertEqual(ProcParsers.parseUptime(sections["uptime"] ?? ""), 42)
    }

    private func count(_ needle: String, in script: String) -> Int {
        script.components(separatedBy: needle).count - 1
    }

    private func marker(_ section: String) -> String {
        "echo '\(ServerStatus.sectionMarkerPrefix)\(section)\(ServerStatus.sectionMarkerSuffix)'"
    }

    func testMonitorScriptSamplesCountersTwiceAroundOneSleep() {
        let script = ServerStatus.monitorScript(includeStatic: true)
        XCTAssertEqual(count("< /proc/stat", in: script), 2)
        XCTAssertEqual(count("/bin/cat /proc/net/dev", in: script), 2)
        XCTAssertEqual(count("/bin/cat /proc/diskstats", in: script), 2)
        XCTAssertEqual(count("/bin/sleep 1", in: script), 1)
        for section in ["cpu-a", "net-a", "disk-a", "cpu-b", "net-b", "disk-b", "mem", "df", "uptime", "loadavg", "ncpu", "snmp", "addr", "hostname", "os-release"] {
            XCTAssertTrue(script.contains(marker(section)), "missing marker for \(section)")
        }
        // Only the cpu rows: the intr row is long and unused.
        XCTAssertTrue(script.contains("case \"$TAMIO_LINE\" in cpu*)"))
    }

    func testMonitorScriptSampledRoundReadsCountersOnceWithoutSleeping() {
        let script = ServerStatus.monitorScript(includeStatic: false, sampled: true)
        XCTAssertEqual(count("< /proc/stat", in: script), 1)
        XCTAssertEqual(count("/bin/cat /proc/net/dev", in: script), 1)
        XCTAssertEqual(count("/bin/cat /proc/diskstats", in: script), 1)
        XCTAssertEqual(count("/bin/sleep", in: script), 0)
        for section in ["cpu-a", "net-a", "disk-a", "wait"] {
            XCTAssertFalse(script.contains(marker(section)), "unexpected marker for \(section)")
        }
        for section in ["cpu-b", "net-b", "disk-b", "mem", "df", "uptime", "loadavg", "ncpu"] {
            XCTAssertTrue(script.contains(marker(section)), "missing marker for \(section)")
        }
        // The Mac's top samples twice on its own.
        XCTAssertTrue(script.contains("/usr/bin/top -l 2 -n 0 -s 1"))
    }

    func testMonitorScriptSummaryReadsOnlyWhatTheCardsShow() {
        let script = ServerStatus.monitorScript(includeStatic: false, scope: .summary)
        for section in ["disk-a", "disk-b", "snmp", "addr"] {
            XCTAssertFalse(script.contains(marker(section)), "unexpected marker for \(section)")
        }
        XCTAssertFalse(script.contains("diskstats"))
        XCTAssertFalse(script.contains("ip -o -4"))
        // The first row of /proc/stat is the total; no per-core rows.
        XCTAssertTrue(script.contains("read -r TAMIO_LINE < /proc/stat"))
        XCTAssertFalse(script.contains("case \"$TAMIO_LINE\" in cpu*)"))
        for section in ["cpu-a", "net-a", "cpu-b", "net-b", "mem", "df", "uptime", "loadavg", "ncpu"] {
            XCTAssertTrue(script.contains(marker(section)), "missing marker for \(section)")
        }
    }

    func testMonitorScriptOmitsStaticsUnlessAsked() {
        let script = ServerStatus.monitorScript(includeStatic: false)
        XCTAssertFalse(script.contains("os-release"))
        XCTAssertFalse(script.contains("hostname"))
        XCTAssertEqual(count("/bin/sleep 1", in: script), 1)
    }

    func testMonitorScriptCpuRowsRunInShell() throws {
        // The cpu rows come out of /bin/sh's builtins alone, as the script
        // writes them; the Mac's sh is the same POSIX shell a server runs.
        let stat = """
        cpu  100 0 200 1600 50 0 10 0 0 0
        cpu0 50 0 100 800 25 0 5 0 0 0
        intr 12345 0 0 0 0 0 0 0 0 0 0 0
        ctxt 999
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tamio-stat-\(UUID().uuidString)")
        try stat.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        for (scope, expected) in [(ServerStatus.Scope.full, "cpu  100 0 200 1600 50 0 10 0 0 0\ncpu0 50 0 100 800 25 0 5 0 0 0"), (.summary, "cpu  100 0 200 1600 50 0 10 0 0 0")] {
            // The whole script, told it is on Linux; the other /proc reads
            // fail quietly here and only the cpu section is checked.
            let script = ServerStatus.monitorScript(includeStatic: false, scope: scope, sampled: true)
                .replacingOccurrences(of: "$(/usr/bin/uname -s)", with: "Linux")
                .replacingOccurrences(of: "/proc/stat", with: file.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let cpu = try XCTUnwrap(ProcParsers.splitMonitorSections(output)["cpu-b"])
            XCTAssertEqual(cpu.trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
    }

    // MARK: - /proc/uptime

    func testParseUptimeReadsFirstField() {
        XCTAssertEqual(ProcParsers.parseUptime("773229.50 1531748.20\n"), 773_229.5, accuracy: 0.001)
        XCTAssertEqual(ProcParsers.parseUptime("42"), 42)
        XCTAssertEqual(ProcParsers.parseUptime("garbage"), 0)
        XCTAssertEqual(ProcParsers.parseUptime(""), 0)
    }

    // MARK: - df -Pk

    private let dfPkFixture = """
    Filesystem                        1024-blocks     Used Available Capacity Mounted on
    udev                                 8192000        0   8192000       0% /dev
    tmpfs                                1638400   124928   1513472       8% /run
    /dev/mapper/ubuntu--vg-ubuntu--lv   51281224 15994688  32923552      33% /
    tmpfs                                8192000        0   8192000       0% /dev/shm
    tmpfs                                   5120        0      5120       0% /run/lock
    none                                       0        0         0       0% /sys/fs/cgroup
    /dev/sda2                            1959920   251792   1606088      14% /boot
    /dev/sdb1                          976762532 6185396 920562116       1% /media/My Passport
    """

    func testDfPkParsesNumericColumns() {
        let elements = ProcParsers.parseDfPk(dfPkFixture)
        let root = elements.first { $0.mountPoint == "/" }
        XCTAssertEqual(root?.size, "49G")
        XCTAssertEqual(root?.used, "15G")
        XCTAssertEqual(root?.free, "31G")
        XCTAssertEqual(root?.percent, 33)
    }

    func testDfPkKeepsLongDeviceNames() {
        // Regression: df -h wraps a long device name onto its own line, and
        // the old space-splitting parser silently dropped both halves; -P
        // keeps one filesystem per line.
        let elements = ProcParsers.parseDfPk(dfPkFixture)
        XCTAssertTrue(elements.contains { $0.mountPoint == "/" })
        XCTAssertEqual(elements.map(\.mountPoint), ["/", "/boot", "/media/My Passport"])
    }

    func testDfPkLeavesOutContainerSnapAndSystemMounts() {
        let raw = """
        Filesystem     1024-blocks     Used Available Capacity Mounted on
        /dev/vda1         82045336 41022668  37661772      53% /
        overlay           82045336 41022668  37661772      53% /var/lib/docker/overlay2/4f1c2b0e9d/merged
        overlay           82045336 41022668  37661772      53% /var/lib/docker/overlay2/a77e01c3f2/merged
        shm                  65536        0     65536       0% /var/lib/docker/containers/4f1c2b0e9d/mounts/shm
        tmpfs              1007500     1240   1006260       1% /run
        tmpfs              5037496        0   5037496       0% /dev/shm
        tmpfs                 5120        0      5120       0% /run/lock
        /dev/loop0           65536    65536         1     100% /snap/core20/2318
        /dev/vda15          106858     6186    100672       6% /boot/efi
        /dev/vda1         82045336 41022668  37661772      53% /var/lib/kubelet/pods/9c1e/volumes/x
        /dev/vdb1        515928320 12345678 477298176       3% /data
        tmpfs              1007496        4   1007492       1% /run/user/1000
        """
        XCTAssertEqual(ProcParsers.parseDfPk(raw).map(\.mountPoint), ["/", "/boot/efi", "/data"])
    }

    func testDfPkKeepsTheMacsDataVolumeOnly() {
        let raw = """
        Filesystem     1024-blocks      Used Available Capacity Mounted on
        /dev/disk3s1s1  971350180  10520936 430132872       3% /
        devfs                 213       213         0     100% /dev
        /dev/disk3s6    971350180   2097172 430132872       1% /System/Volumes/VM
        /dev/disk3s2    971350180   6851420 430132872       2% /System/Volumes/Preboot
        /dev/disk3s4    971350180      5576 430132872       1% /System/Volumes/Update
        /dev/disk3s5    971350180 520073712 430132872      55% /System/Volumes/Data
        map auto_home           0         0         0     100% /System/Volumes/Data/home
        /dev/disk7s1   1953513984 1789235200  97436672      95% /Volumes/.timemachine/2BD27D3E/2026-10-08-081719.backup
        /dev/disk8s1   1953513984 1789235200  97436672      95% /Volumes/Samsung SSD 990 EVO 2TB
        /dev/disk5s1      2097152   2023424     73728      97% /private/var/run/com.apple.security.cryptexd/mnt/x
        """
        XCTAssertEqual(ProcParsers.parseDfPk(raw).map(\.mountPoint), ["/", "/System/Volumes/Data", "/Volumes/Samsung SSD 990 EVO 2TB"])
    }

    func testDfPkKeepsSpacesInMountPointAndSkipsEmptyFilesystems() {
        let elements = ProcParsers.parseDfPk(dfPkFixture)
        let mounted = elements.first { $0.mountPoint == "/media/My Passport" }
        XCTAssertEqual(mounted?.size, "932G")
        XCTAssertEqual(mounted?.used, "5.9G")
        XCTAssertFalse(elements.contains { $0.mountPoint == "/sys/fs/cgroup" })
    }

    func testDfPkFormatsKilobytesLikeDfH() {
        XCTAssertEqual(ProcParsers.formatKilobytes(957_440), "935M")
        XCTAssertEqual(ProcParsers.formatKilobytes(512), "512K")
        XCTAssertEqual(ProcParsers.formatKilobytes(1_945_600), "1.9G")
    }
}

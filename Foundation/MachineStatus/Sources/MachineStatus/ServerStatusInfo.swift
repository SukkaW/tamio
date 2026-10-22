//
//  ServerInfo.swift
//  Tamio
//
//  Created by Lakr Aream on 2022/2/12.
//

import Combine
import Foundation
import NSRemoteShell

/// Mirror of TamioModule's `onMainThread`; MachineStatus sits below
/// TamioModule in the package graph and cannot import it.
/// - Parameter run: the job to be fired on the main thread
func onMainThread(delay: Double = 0, run: @escaping () -> Void) {
    // Preserve the legacy model callbacks without claiming the models are Sendable.
    nonisolated(unsafe) let run = run
    guard delay == 0, Thread.isMainThread else {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            run()
        }
        return
    }
    run()
}

/// Hands a value out of a @Sendable dispatch block without capturing a
/// var, which Swift 6 diagnoses.
private final class ConcurrentValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func store(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public class ServerStatus: ObservableObject, Equatable {
    public init() {}

    /// The merged monitor script echoes this marker on its own line ahead
    /// of each section; `ProcParsers.splitMonitorSections` only opens a
    /// section on a full-line match, which kernel /proc payloads, df rows
    /// and os-release assignments can never produce. That is what the old
    /// "[*******]" token could not promise inside two samples of one file.
    static let sectionMarkerPrefix = "<<<TAMIO-SECTION:"
    static let sectionMarkerSuffix = ">>>"

    /// `nvidia-smi` stays a command of its own: it is slow and missing on
    /// most machines, and its failure must not cost the other sections.
    static let graphicsScript = "nvidia-smi -q -x | tr -d \"[\\t\\n]\" || echo \"no nvidia gpu available\""

    /// How much a refresh reads.
    public enum Scope: Sendable {
        /// What a server card, the Servers table and the menu bar show: the
        /// CPU total, memory, file systems, network rates, load and uptime.
        case summary
        /// Every reading: each core, disk I/O, TCP counters, addresses and
        /// the GPU, for the monitor page and the inspector.
        case full
    }

    /// One remote run that reads every payload behind markers, so a
    /// refresh costs one exec channel instead of nine. Linux reads /proc;
    /// Darwin uses its native tools.
    ///
    /// The CPU, network and disk counters are rates, so they need two
    /// samples. The first round takes both itself, a second apart; the
    /// rounds after it (`sampled`) read the counters once and the rates
    /// come from the previous round's sample, so a refresh takes no remote
    /// time at all and holds the channel for the reads alone. Linux reads
    /// only the cpu rows of /proc/stat: its intr row can run to tens of
    /// kilobytes on a large server, and nothing uses it. A `summary` read
    /// skips the per-core rows, the disk, TCP and address payloads.
    /// Static payloads join only while `includeStatic` — they cannot change
    /// while a connection stays up.
    static func monitorScript(includeStatic: Bool, scope: Scope = .full, sampled: Bool = false) -> String {
        let linux = "if [ \"$TAMIO_KERNEL\" != Darwin ]; then"
        let darwin = "if [ \"$TAMIO_KERNEL\" = Darwin ]; then"
        // Shell builtins alone: no process for the kernel's own files.
        let cpu = switch scope {
        case .summary: "\(linux) read -r TAMIO_LINE < /proc/stat; echo \"$TAMIO_LINE\"; fi"
        case .full: "\(linux) while read -r TAMIO_LINE; do case \"$TAMIO_LINE\" in cpu*) echo \"$TAMIO_LINE\";; esac; done < /proc/stat; fi"
        }
        let net = "\(darwin) /usr/sbin/netstat -ibn; else /bin/cat /proc/net/dev; fi"
        let disk = "\(linux) /bin/cat /proc/diskstats 2>/dev/null; fi"
        var sections: [(String, String)] = [("platform", "echo \"$TAMIO_KERNEL\"")]
        if !sampled {
            sections += [("cpu-a", cpu), ("net-a", net)]
            if scope == .full { sections.append(("disk-a", disk)) }
        }
        // top's first sample is the average since boot; the second is live.
        sections += [
            ("darwin-top", "\(darwin) /usr/bin/top -l 2 -n 0 -s 1; fi"),
        ]
        if !sampled {
            sections.append(("wait", "\(linux) /bin/sleep 1; fi"))
        }
        sections += [("cpu-b", cpu)]
        if scope == .full { sections.append(("disk-b", disk)) }
        sections += [
            ("net-b", net),
            ("mem", "\(darwin) /usr/sbin/sysctl hw.memsize hw.pagesize vm.swapusage; /usr/bin/vm_stat; else /bin/cat /proc/meminfo; fi"),
            ("df", "/bin/df -Pk"),
            ("uptime", "\(darwin) /bin/date +%s; /usr/sbin/sysctl -n kern.boottime; else /bin/cat /proc/uptime; fi"),
            ("loadavg", "\(linux) /bin/cat /proc/loadavg; fi"),
            ("ncpu", "getconf _NPROCESSORS_ONLN 2>/dev/null || /usr/sbin/sysctl -n hw.ncpu 2>/dev/null"),
        ]
        if scope == .full {
            sections += [
                ("snmp", "\(linux) /bin/cat /proc/net/snmp 2>/dev/null; fi"),
                ("addr", "\(linux) ip -o -4 addr show 2>/dev/null; fi"),
            ]
        }
        if includeStatic {
            sections += [
                ("hostname", "/bin/hostname 2>/dev/null || hostname 2>/dev/null || echo \"localhost\""),
                ("os-release", "if [ \"$TAMIO_KERNEL\" = Darwin ]; then /usr/bin/sw_vers; else /bin/cat /etc/os-release; fi"),
            ]
        }
        let commands = sections.map { name, command in
            "echo '\(sectionMarkerPrefix)\(name)\(sectionMarkerSuffix)'\n\(command)"
        }
        return (["TAMIO_KERNEL=\"$(/usr/bin/uname -s)\""] + commands)
            .joined(separator: "\n")
    }

    /// Runs one command on an open shell and returns what it printed.
    public static func downloadResultFrom(shell: NSRemoteShell, command: String, timeout: Double) -> String {
        guard shell.isConnected, shell.isAuthenticated else {
            return ""
        }
        var result = ""
        shell.beginExecute(
            withCommand: command,
            withTimeout: NSNumber(value: timeout),
            withOnCreate: {},
            withOutput: { result.append($0) },
            withContinuationHandler: nil
        )
        return result
    }

    // Not @Published on purpose: a refresh replaces every group in one
    // batch and sends a single objectWillChange (see requestInfoAndWait),
    // where six per-property publishes used to redraw every card six
    // times per round.
    public var processor: ProcessorInfo = .init()
    public var fileSystem: FileSystemInfo = .init()
    public var memory: MemoryInfo = .init()
    public var system: SystemInfo = .init()
    public var network: NetworkInfo = .init()
    /// Linux only; empty on Darwin.
    public var diskIO: DiskIOInfo = .init()
    /// Online CPUs, for scaling the load; 0 when unknown.
    public var cpuCount = 0
    /// Linux only.
    public var tcp: TCPInfo = .init()
    /// Each interface's first IPv4 address; Linux only.
    public var addresses: [String: String] = [:]

    // not all server have gpu, bro
    public var graphics: GraphicsInfo? = nil

    public static func == (lhs: ServerStatus, rhs: ServerStatus) -> Bool {
        lhs.processor == rhs.processor &&
            lhs.fileSystem == rhs.fileSystem &&
            lhs.memory == rhs.memory &&
            lhs.system == rhs.system &&
            lhs.network == rhs.network &&
            lhs.diskIO == rhs.diskIO &&
            lhs.tcp == rhs.tcp &&
            lhs.cpuCount == rhs.cpuCount &&
            lhs.addresses == rhs.addresses &&
            lhs.graphics == rhs.graphics
    }

    private static let queue = DispatchQueue(label: "sb.moe.tamio.info", attributes: .concurrent)

    /// Hostname and os-release cannot change while a connection stays up,
    /// so they are read once and reused until the monitor reports a
    /// reconnect via `resetSessionStatics`.
    private let staticsLock = NSLock()
    private var sessionHostname: String?
    private var sessionReleaseName: String?

    /// The counters the last round read, for the rates of the next one.
    private struct Sample {
        let scope: Scope
        let cpu: String?
        let net: String?
        let disk: String?
        /// When the read finished, by this Mac's clock: the remote spacing
        /// between two reads is the same to within the round trip.
        let at: Date
    }

    private var previousSample: Sample?

    /// Drops the once-per-connection static readings so the next refresh
    /// pulls them again, and the last counters: the rates of a new
    /// connection start from a fresh pair of samples.
    public func resetSessionStatics() {
        staticsLock.lock()
        sessionHostname = nil
        sessionReleaseName = nil
        previousSample = nil
        staticsLock.unlock()
    }

    /// Runs the merged monitor script and the GPU probe on two channels,
    /// then parses every section on its own: one section going missing
    /// (a hung `nvidia-smi`, an unsupported system probe) empties only its
    /// model. `timeout` bounds each channel so a hung probe cannot freeze
    /// the monitor loop forever.
    ///
    /// False when the round brought nothing back (a connection that died
    /// while the Mac slept, say): the last readings are then kept, not
    /// replaced by empty ones, which would blank every view showing them.
    @discardableResult
    public func requestInfoAndWait(with remote: NSRemoteShell, timeout: Double, scope: Scope = .full) -> Bool {
        // The shell multiplexes channels internally; claiming it Sendable
        // is for the compiler, like the legacy model callbacks.
        nonisolated(unsafe) let remote = remote
        staticsLock.lock()
        let includeStatic = sessionHostname == nil || sessionReleaseName == nil
        let previous = previousSample
        staticsLock.unlock()
        let group = DispatchGroup()
        let queue = Self.queue

        let mergedOutput = ConcurrentValue("")
        let readAt = ConcurrentValue(Date())
        group.enter()
        queue.async {
            defer { group.leave() }
            // A summary sample has no per-core or disk rows to rate a full
            // round against, so a round that widens the scope samples twice.
            let sampled = previous.map { $0.scope == .full || scope == .summary } ?? false
            let script = Self.monitorScript(includeStatic: includeStatic, scope: scope, sampled: sampled)
            mergedOutput.store(Self.downloadResultFrom(shell: remote, command: script, timeout: timeout))
            readAt.store(Date())
        }

        // A GPU is a monitor page's reading; the cards never show one.
        let graphicsResult = ConcurrentValue<GraphicsInfo?>(nil)
        if scope == .full {
            group.enter()
            queue.async {
                defer { group.leave() }
                graphicsResult.store(GraphicsInfo(withRemote: remote, timeout: timeout))
            }
        }

        group.wait()

        var sections = ProcParsers.splitMonitorSections(mergedOutput.load())
        guard sections["mem"] != nil || sections["uptime"] != nil else { return false }
        let isDarwin = sections["platform"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "Darwin"
        // A sampled round's "before" is the last round's "after". The rates
        // are then per second of the gap between the two reads; a first
        // round's gap is the script's own second.
        var interval = 1.0
        if let previous, previous.scope == .full || scope == .summary {
            sections["cpu-a"] = previous.cpu
            sections["net-a"] = previous.net
            sections["disk-a"] = previous.disk
            interval = max(0.5, readAt.load().timeIntervalSince(previous.at))
        }
        staticsLock.lock()
        previousSample = Sample(scope: scope, cpu: sections["cpu-b"], net: sections["net-b"], disk: sections["disk-b"], at: readAt.load())
        staticsLock.unlock()
        if includeStatic {
            // Only a non-empty reading is cached; a failed probe is retried
            // on the next round instead of sticking a placeholder.
            let hostname = (sections["hostname"] ?? "").replacingOccurrences(of: "\n", with: "")
            let releasePayload = (sections["os-release"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            staticsLock.lock()
            if !hostname.isEmpty { sessionHostname = hostname }
            if !releasePayload.isEmpty {
                sessionReleaseName = isDarwin
                    ? ProcParsers.parseDarwinReleaseName(releasePayload)
                    : ProcParsers.parseOsReleaseName(releasePayload)
            }
            staticsLock.unlock()
        }
        staticsLock.lock()
        let hostname = sessionHostname ?? ""
        let releaseName = sessionReleaseName ?? ""
        staticsLock.unlock()

        let processor: ProcessorInfo
        let network: NetworkInfo
        let memory: MemoryInfo
        let load: SystemLoadInternal
        let uptime: Double
        if isDarwin {
            processor = ProcessorInfo(darwinTop: sections["darwin-top"]) ?? .init()
            network = NetworkInfo(netstatBefore: sections["net-a"], netstatAfter: sections["net-b"], interval: interval) ?? .init()
            memory = MemoryInfo(darwinMemory: sections["mem"] ?? "")
            load = ProcParsers.parseDarwinTopLoad(sections["darwin-top"] ?? "")
            uptime = ProcParsers.parseDarwinUptime(sections["uptime"] ?? "")
        } else {
            processor = ProcessorInfo(statBefore: sections["cpu-a"], statAfter: sections["cpu-b"]) ?? .init()
            network = NetworkInfo(netDevBefore: sections["net-a"], netDevAfter: sections["net-b"], interval: interval) ?? .init()
            memory = MemoryInfo(meminfo: sections["mem"] ?? "")
            load = ProcParsers.parseLoadavg(sections["loadavg"] ?? "")
            uptime = ProcParsers.parseUptime(sections["uptime"] ?? "")
        }
        let fileSystem = FileSystemInfo(dfPk: sections["df"] ?? "")
        let diskIO = isDarwin ? DiskIOInfo() : DiskIOInfo(diskstatsBefore: sections["disk-a"], diskstatsAfter: sections["disk-b"], interval: interval)
        let tcp = TCPInfo(snmp: sections["snmp"] ?? "")
        let cpuCount = Int((sections["ncpu"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let addresses = Self.parseIPv4Addresses(sections["addr"] ?? "")
        let system = SystemInfo(
            release: releaseName,
            uptimeInSec: uptime,
            hostname: hostname,
            runningProcs: load.runningProcess,
            totalProcs: load.totalProcess,
            load1: load.load1avg,
            load5: load.load5avg,
            load15: load.load15avg
        )
        let graphics = graphicsResult.load()

        onMainThread { [weak self] in
            guard let self else { return }
            // One publish per refresh: the whole batch lands behind a
            // single objectWillChange.
            objectWillChange.send()
            self.processor = processor
            self.fileSystem = fileSystem
            self.memory = memory
            self.system = system
            self.network = network
            self.diskIO = diskIO
            self.tcp = tcp
            self.cpuCount = cpuCount
            self.addresses = addresses
            self.graphics = graphics
        }
        return true
    }
}

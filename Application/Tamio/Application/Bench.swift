//
//  Bench.swift
//  Tamio (macOS)
//
//  Measurements for the Files page, in debug builds only. Launch with
//  TAMIO_BENCH_FILES=<count> to fill a page with that many entries and time
//  showing them, selecting, filtering, a transfer's progress ticks and scrolling.
//  Results go to the log, one "BENCH" line each.
//

#if DEBUG
    import MachineStatusView
    import NSRemoteShell
    import TamioModule
    import TamioTerminal
import SwiftUI
    import AppKit

    extension Notification.Name {
        /// userInfo: "select" (Int, an index into the sorted list) or "filter" (String).
        static let benchFiles = Notification.Name("sb.moe.tamio.bench.files")
    }

    /// What the run loop observer in `settle` records: written on the main
    /// run loop only, read after the observer is removed. The box hands the
    /// capture to the C callback as one Sendable object.
    private final class RunLoopLoad: @unchecked Sendable {
        var busy = 0.0
        var stretch = 0.0
        var woke = CACurrentMediaTime()
    }

    @MainActor
    enum Bench {
        static func runIfRequested() {
            if ProcessInfo.processInfo.environment["TAMIO_PREVIEW_FILES"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Task { await previewFiles() } }
            }
            if let pages = ProcessInfo.processInfo.environment["TAMIO_BENCH_SIDEBAR"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { await sidebar(pages) } }
            }
            if ProcessInfo.processInfo.environment["TAMIO_BENCH_SETTINGS"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Task { await settings() } }
            }
            guard let value = ProcessInfo.processInfo.environment["TAMIO_BENCH_FILES"], let count = Int(value) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Task { await files(count) } }
        }

        /// How long the main thread worked in the 0.4 s after the action: the
        /// state change, SwiftUI's update, layout and the commit to the render
        /// server, wherever in that window they ran.
        /// The longest single stretch of work in the last `settle`: the hitch.
        static var longest = 0.0

        static func settle(for seconds: Double = 0.4, _ action: () -> Void) async -> Double {
            let load = RunLoopLoad()
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { _, activity in
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { load.woke = now } else { load.busy += now - load.woke; load.stretch = max(load.stretch, now - load.woke); load.woke = now }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            action()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            longest = load.stretch * 1000
            return load.busy * 1000
        }

        /// Collapses and expands the sidebar the way its toolbar button does,
        /// on each page named in TAMIO_BENCH_SIDEBAR ("home,servers,settings,
        /// terminal"). TAMIO_BENCH_SERVERS=<n> first adds n servers no one
        /// answers at (for a copy of the app with its own store only), and
        /// TAMIO_BENCH_TERMINALS=<n> opens n terminals to them.
        static func sidebar(_ pages: String) async {
            let environment = ProcessInfo.processInfo.environment
            let servers = Int(environment["TAMIO_BENCH_SERVERS"] ?? "") ?? 0
            if servers > 0, TamioStore.shared.machineGroup.machines.isEmpty {
                LiveStatusCenter.shared.isEnabled = false
                for index in 0 ..< servers {
                    TamioStore.shared.machineGroup.insert(RDMachine(
                        remoteAddress: "203.0.113.\(index + 1)", remotePort: "22", name: "bench-\(index + 1)", group: index % 3 == 0 ? "Web" : "DB"
                    ))
                }
            }
            for machine in TamioStore.shared.machineGroup.machines.prefix(Int(environment["TAMIO_BENCH_TERMINALS"] ?? "") ?? 0) {
                TerminalManager.shared.createSession(withMachineID: machine.id)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // The toggle goes to the key window's responder chain.
            MainWindow.show()
            try? await Task.sleep(nanoseconds: 500_000_000)
            let router = AppRouter.shared
            for page in pages.split(separator: ",").map(String.init) {
                switch page {
                case "servers": router.route = .servers
                // Nothing in the content column, not even a page's toolbar.
                case "blank": router.route = .terminal(UUID())
                case "settings": router.route = .settings
                case "terminal":
                    guard let context = TerminalManager.shared.sessionContexts.first else { continue }
                    router.route = .terminal(context.id)
                default: router.route = .home
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                var collapse: [Double] = [], expand: [Double] = []
                var collapseHitch: [Double] = [], expandHitch: [Double] = []
                for _ in 0 ..< 5 {
                    collapse.append(await settle(for: 0.8) { toggleSidebar() })
                    collapseHitch.append(longest)
                    let collapsed = sidebarWidth()
                    expand.append(await settle(for: 0.8) { toggleSidebar() })
                    expandHitch.append(longest)
                    NSLog("BENCH %@ sidebar width collapsed %.0f expanded %.0f", page, collapsed, sidebarWidth())
                }
                report("\(page) collapse busy", collapse)
                report("\(page) collapse hitch", collapseHitch)
                report("\(page) expand busy", expand)
                report("\(page) expand hitch", expandHitch)
            }
            NSLog("BENCH done")
        }

        /// The width of the split view's first pane, 0 when the sidebar is away.
        private static func sidebarWidth() -> CGFloat {
            func split(in view: NSView) -> NSSplitView? {
                if let split = view as? NSSplitView { return split }
                for child in view.subviews { if let found = split(in: child) { return found } }
                return nil
            }
            guard let content = Mac.mainWindow?.contentView, let split = split(in: content),
                  let first = split.arrangedSubviews.first
            else { return -1 }
            return split.isSubviewCollapsed(first) ? 0 : first.frame.width
        }

        private static func logPanes(_ delay: Double) {
            func split(in view: NSView) -> NSSplitView? {
                if let split = view as? NSSplitView { return split }
                for child in view.subviews { if let found = split(in: child) { return found } }
                return nil
            }
            guard let content = Mac.mainWindow?.contentView, let split = split(in: content) else { return }
            let panes = split.arrangedSubviews.map { String(format: "x %.0f w %.0f", $0.frame.minX, $0.frame.width) }.joined(separator: " | ")
            NSLog("BENCH panes +%.2fs window %.0f: %@", delay, Mac.mainWindow?.frame.width ?? 0, panes)
        }

        private static func toggleSidebar() {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            if ProcessInfo.processInfo.environment["TAMIO_BENCH_PANES"] != nil {
                for delay in [0.03, 0.08, 0.15, 0.4] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { logPanes(delay) } }
                }
            }
        }

        static func report(_ name: String, _ samples: [Double]) {
            let sorted = samples.sorted()
            let median = sorted[sorted.count / 2]
            NSLog("BENCH %@ median %.2f ms  max %.2f ms  n=%d", name, median, sorted.last ?? 0, samples.count)
        }

        /// A Files page with no server behind it, to be filled by hand.
        static func emptyFilesPage() async -> FileTransferContext {
            let machine = RDMachine(remoteAddress: "203.0.113.10", remotePort: "22", name: "web-01")
            let context = FileTransferContext(machine: machine)
            FileTransferManager.shared.transfers.append(context)
            AppRouter.shared.route = .transfer(context.id)
            // Once the connection attempt has given up.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while context.processConnection { try? await Task.sleep(nanoseconds: 200_000_000) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            context.connected = true
            context.isProgressRunning = false
            try? await Task.sleep(nanoseconds: 500_000_000)
            return context
        }

        /// A folder of sample entries: launch with TAMIO_PREVIEW_FILES=1 to check
        /// the table's layout.
        static func previewFiles() async {
            let context = await emptyFilesPage()
            context.currentDir = "/var/log"
            let base = URL(fileURLWithPath: "/var/log")
            let names = ["nginx", "journal", "apt", "private", "auth.log", "syslog", "kern.log", "dpkg.log", "boot.log",
                         "a-very-long-file-name-that-does-not-fit-in-the-name-column-of-the-table-and-is-truncated-in-the-middle-2026-10-11.log.gz",
                         "fail2ban.log", "alternatives.log", "cloud-init.log", "wtmp", "btmp", "lastlog", "ufw.log", "mail.log"]
            context.currentFileList = names.enumerated().map { index, name in
                let file = NSRemoteFile(filename: name)
                var attributes = LIBSSH2_SFTP_ATTRIBUTES()
                attributes.flags = 0xF
                attributes.filesize = UInt64(index * index * 4321 + 17)
                attributes.uid = index < 4 ? 0 : 1000
                attributes.gid = 0
                attributes.permissions = index < 4 ? 0o040755 : 0o100644
                attributes.mtime = UInt(1_780_000_000 + index * 86400 * 3)
                attributes.atime = attributes.mtime
                file.populateAttributes(attributes)
                return FileTransferContext.RemoteFile(base: base, name: name, fstat: file)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            NotificationCenter.default.post(name: .benchFiles, object: nil, userInfo: ["select": 6])
        }

        static func files(_ count: Int) async {
            let context = await emptyFilesPage()

            let base = URL(fileURLWithPath: "/var/log")
            var generator = SystemRandomNumberGenerator()
            let list = (0 ..< count).map { _ in
                let name = "file-\(Int.random(in: 0 ..< 10_000_000, using: &generator)).log"
                return FileTransferContext.RemoteFile(base: base, name: name, fstat: NSRemoteFile(filename: name))
            }
            report("show \(count)", [await settle { context.currentFileList = list }])
            try? await Task.sleep(nanoseconds: 500_000_000)

            var samples: [Double] = []
            for index in 0 ..< 6 {
                samples.append(await settle {
                    context.currentDir = "/var/log/\(index)"
                    context.currentFileList = list.shuffled()
                })
            }
            report("enter folder", samples)

            samples = []
            for index in 0 ..< 20 {
                samples.append(await settle {
                    NotificationCenter.default.post(name: .benchFiles, object: nil, userInfo: ["select": index % 12])
                })
            }
            report("select", samples)

            samples = []
            for index in 0 ..< 20 {
                samples.append(await settle { context.currentSpeed = 1000 + index })
            }
            report("progress tick", samples)

            samples = []
            for text in Array(repeating: ["1", "12", "123", "12", "1", ""], count: Int(ProcessInfo.processInfo.environment["TAMIO_BENCH_REPEAT"] ?? "1") ?? 1).flatMap({ $0 }) {
                samples.append(await settle {
                    NotificationCenter.default.post(name: .benchFiles, object: nil, userInfo: ["filter": text])
                })
            }
            report("filter keystroke", samples)

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            report("idle 0.4 s", [await settle {}, await settle {}, await settle {}])
            await scroll()
            NSLog("BENCH done")
        }

        /// Opens Settings, goes through its categories and scrolls the longest.
        static func settings() async {
            let router = AppRouter.shared
            router.settingsSelection = "general"
            report("open settings", [await settle { router.route = .settings }])
            report("open settings hitch", [longest])
            try? await Task.sleep(nanoseconds: 500_000_000)
            let ids = ["general", "connection", "text", "colors", "cursor", "window", "input", "keyboard", "advanced", "about"]
            var samples: [Double] = []
            var hitches: [Double] = []
            let rounds = Int(ProcessInfo.processInfo.environment["TAMIO_BENCH_REPEAT"] ?? "2") ?? 2
            for id in Array(repeating: ids, count: rounds).flatMap({ $0 }) {
                let sample = await settle { router.settingsSelection = id }
                NSLog("BENCH category %@ %.2f ms  hitch %.2f ms", id, sample, longest)
                samples.append(sample)
                hitches.append(longest)
            }
            report("switch category", samples)
            report("switch category hitch", hitches)
            await edits()
            var reopen: [Double] = []
            // TAMIO_BENCH_BLANK leaves for a page with nothing on it, so what
            // is measured is Settings going and coming and nothing else.
            let away: Route = ProcessInfo.processInfo.environment["TAMIO_BENCH_BLANK"] != nil ? .terminal(UUID()) : .servers
            var leave: [Double] = []
            var leaveHitch: [Double] = []
            var reopenHitch: [Double] = []
            for _ in 0 ..< (Int(ProcessInfo.processInfo.environment["TAMIO_BENCH_REOPEN"] ?? "3") ?? 3) {
                leave.append(await settle { router.route = away })
                leaveHitch.append(longest)
                reopen.append(await settle { router.route = .settings })
                reopenHitch.append(longest)
            }
            if ProcessInfo.processInfo.environment["TAMIO_BENCH_NOPLACES"] == nil { await places() }
            report("leave settings", leave)
            report("leave settings hitch", leaveHitch)
            report("reopen settings", reopen)
            report("reopen settings hitch", reopenHitch)
            router.settingsSelection = "advanced"
            try? await Task.sleep(nanoseconds: 800_000_000)
            report("idle 0.4 s", [await settle {}, await settle {}, await settle {}])
            await scroll()
            router.settingsSelection = "colors"
            try? await Task.sleep(nanoseconds: 800_000_000)
            await scroll()
            NSLog("BENCH done")
        }

        /// Goes between the places of the sidebar that are not Settings.
        static func places() async {
            let router = AppRouter.shared
            var samples: [Double] = []
            var hitches: [Double] = []
            for route in [Route.home, .servers, .identities, .snippets, .home, .servers, .identities, .snippets] {
                let sample = await settle { router.route = route }
                NSLog("BENCH place %@ %.2f ms  hitch %.2f ms", String(describing: route), sample, longest)
                samples.append(sample)
                hitches.append(longest)
            }
            report("change place", samples)
            report("change place hitch", hitches)
        }

        /// Changes a setting again and again, as dragging its control would,
        /// then puts back what it had.
        static func edits() async {
            let router = AppRouter.shared
            router.settingsSelection = "cursor"
            try? await Task.sleep(nanoseconds: 800_000_000)
            let key = "cursor-opacity"
            let before = ConfigBenchmark.value(key)
            var samples: [Double] = []
            var hitches: [Double] = []
            let count = Int(ProcessInfo.processInfo.environment["TAMIO_BENCH_EDITS"] ?? "12") ?? 12
            for step in 0 ..< count {
                let value = String(format: "%.2f", 0.4 + Double(step % 6) * 0.1)
                samples.append(await settle { ConfigBenchmark.edit(key, value) })
                hitches.append(longest)
            }
            report("edit a setting", samples)
            report("edit a setting hitch", hitches)
            ConfigBenchmark.edit(key, before)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        /// Scrolls the file list from top to bottom and back at a steady pace
        /// and reports how long frames took.
        static func scroll() async {
            guard let window = Mac.mainWindow, let content = window.contentView,
                  let scroller = largestScrollView(in: content)
            else { return NSLog("BENCH scroll: no scroll view") }
            let height = scroller.documentView?.frame.height ?? 0
            NSLog("BENCH scroll view %@ content %.0f", String(describing: type(of: scroller)), height)
            let recorder = FrameRecorder()
            // A fast flick, about 6000 pt a second, rather than the whole list.
            let distance = min(12000, max(0, height - scroller.contentView.bounds.height))
            let duration = 4.0
            recorder.start(in: content) { progress in
                // There and back.
                let phase = progress < 0.5 ? progress * 2 : (1 - progress) * 2
                scroller.contentView.scroll(to: NSPoint(x: 0, y: distance * phase))
                scroller.reflectScrolledClipView(scroller.contentView)
            }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            let frames = recorder.stop()
            guard frames.count > 2 else { return }
            let sorted = frames.sorted()
            let slow = frames.filter { $0 > 1000.0 / 60 * 1.5 }.count
            NSLog(
                "BENCH scroll %.0f pt  frames %d  median %.2f ms  p95 %.2f ms  max %.2f ms  slow(>25ms) %d",
                distance, frames.count, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0, slow
            )
        }

        private static func largestScrollView(in view: NSView) -> NSScrollView? {
            var best: NSScrollView?
            var stack = [view]
            while let next = stack.popLast() {
                if let scroll = next as? NSScrollView,
                   (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0)
                {
                    best = scroll
                }
                stack.append(contentsOf: next.subviews)
            }
            return best
        }
    }

    @MainActor
    private final class FrameRecorder: NSObject {
        private var link: CADisplayLink?
        private var step: ((Double) -> Void)?
        private var begin = 0.0
        private var last = 0.0
        private var frames: [Double] = []
        private var duration = 4.0

        func start(in view: NSView, duration: Double = 4, step: @escaping (Double) -> Void) {
            self.step = step
            self.duration = duration
            link = view.displayLink(target: self, selector: #selector(tick))
            link?.add(to: .main, forMode: .common)
        }

        @objc private func tick(_: CADisplayLink) {
            // Wall time between callbacks: a stalled main thread shows as a long frame.
            let now = CACurrentMediaTime()
            if begin == 0 { begin = now } else { frames.append((now - last) * 1000) }
            last = now
            step?(min(1, (now - begin) / duration))
        }

        func stop() -> [Double] {
            link?.invalidate()
            return frames
        }
    }
#endif

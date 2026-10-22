//
//  HomeGroupFilter.swift
//  MachineStatusView
//
//  Which servers Home shows (every one, or one group's), kept across
//  launches, and the All · group · group switcher that chooses.
//

import SwiftUI
import TamioModule

/// Which servers Home shows: every one, one group's, or those in no group.
/// Kept across launches as a string.
public enum HomeGroupFilter: Hashable, RawRepresentable, Sendable {
    case all
    case group(String)
    case ungrouped

    public init?(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "ungrouped": self = .ungrouped
        default:
            guard rawValue.hasPrefix("group:") else { return nil }
            self = .group(String(rawValue.dropFirst("group:".count)))
        }
    }

    public var rawValue: String {
        switch self {
        case .all: return "all"
        case .ungrouped: return "ungrouped"
        case let .group(name): return "group:" + name
        }
    }

    public func includes(_ machine: RDMachine) -> Bool {
        switch self {
        case .all: return true
        case .ungrouped: return machine.group.isEmpty
        case let .group(name): return machine.group == name
        }
    }

    /// The chosen filter, or All once no server is left in what it named.
    public func resolved(in machines: [RDMachine]) -> HomeGroupFilter {
        switch self {
        case .all:
            return .all
        case .ungrouped:
            return machines.contains { $0.group.isEmpty } ? .ungrouped : .all
        case let .group(name):
            return machines.contains { $0.group == name } ? self : .all
        }
    }

    /// The servers the filter and a search leave, in the store's order.
    public func machines(in store: TamioStore, search: String) -> [RDMachine] {
        let current = resolved(in: store.machineGroup.machines)
        let shown = store.machineGroup.machines.filter { current.includes($0) }
        let needle = search.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? shown : shown.filter { $0.isQualifiedForSearch(text: needle) }
    }

    /// What to say when a search leaves nothing.
    public func noMatchTitle(for search: String) -> LocalizedStringKey {
        switch self {
        case .all: return "No servers match “\(search)”"
        case .ungrouped: return "No servers in no group match “\(search)”"
        case let .group(name): return "No servers in \(name) match “\(search)”"
        }
    }
}

/// Kept in memory and written through to UserDefaults so the segmented
/// control's binding updates synchronously during AppKit's click handler
/// (a computed Binding over @AppStorage reads the previous snapshot until the
/// next render pass, which makes NSSegmentedControl snap back for one frame).
@MainActor
public final class HomeGroupFilterStore: ObservableObject {
    public static let shared = HomeGroupFilterStore()
    private static let key = "sb.moe.tamio.home.group"

    @Published public var selection: HomeGroupFilter {
        didSet {
            guard selection != oldValue else { return }
            UserDefaults.standard.set(selection.rawValue, forKey: Self.key)
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
        selection = HomeGroupFilter(rawValue: raw) ?? .all
    }
}

/// All · each group at the leading end of Home's toolbar, drawn like the
/// Terminal · Files · Monitor switcher of a session page: one click shows
/// only that group's cards. Nothing at all until a server has a group.
public struct HomeGroupSwitcher: View {
    @EnvironmentObject var store: TamioStore
    @ObservedObject private var filterStore = HomeGroupFilterStore.shared

    public init() {}

    struct Segment: Hashable {
        let filter: HomeGroupFilter
        let rawTitle: String
        let count: Int

        var title: LocalizedStringKey {
            switch filter {
            case .all: return "All"
            case .ungrouped: return "No Group"
            case let .group(name): return LocalizedStringKey(name)
            }
        }
    }

    var segments: [Segment] {
        let machines = store.machineGroup.machines
        let groups = Set(machines.map(\.group)).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        // Only once a server has a group: with none, there is nothing to
        // choose between.
        guard !groups.isEmpty else { return [] }
        var items = [Segment(filter: .all, rawTitle: "All", count: machines.count)]
        for name in groups {
            items.append(Segment(
                filter: .group(name),
                rawTitle: name,
                count: machines.filter { $0.group == name }.count
            ))
        }
        // Servers in no group are under All only: a No Group choice read as
        // a group of its own.
        return items
    }

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        let segments = segments
        let active = filterStore.selection.resolved(in: store.machineGroup.machines)
        if !segments.isEmpty {
            HStack(spacing: 0) {
                ForEach(segments, id: \.filter) { segment in
                    let isSelected = segment.filter == active
                    Button {
                        guard filterStore.selection != segment.filter else { return }
                        filterStore.selection = segment.filter
                    } label: {
                        Text(segment.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary.opacity(isSelected ? 0.96 : 0.78))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(minWidth: 56, minHeight: 28, maxHeight: 28)
                            .background {
                                if isSelected {
                                    Capsule()
                                        .fill(Color.primary.opacity(0.14))
                                        .matchedGeometryEffect(id: "selection", in: pill)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(segment.count == 1 ? String(localized: "1 server") : String(localized: "\(segment.count) servers"))
                    .accessibilityLabel("\(segment.rawTitle), \(segment.count)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 4)
            .fixedSize()
            .animation(reduceMotion ? nil : .rxMove, value: active)
            .help(String(localized: "Show every server, or one group's"))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Group"))
            .onAppear { reconcile(segments) }
            .onChange(of: segments) { reconcile($0) }
        }
    }

    private func reconcile(_ segments: [Segment]) {
        if !segments.isEmpty, !segments.contains(where: { $0.filter == filterStore.selection }) {
            filterStore.selection = .all
        }
    }
}

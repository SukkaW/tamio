//
//  Gauges.swift
//  MachineStatusView
//
//  The small readings the cards and the inspector share: rings, load rings,
//  bold values with a grey unit, and a layout that picks the first child
//  that fits.
//

import SwiftUI
import TamioModule

/// "50 K", "2.6 M", "356 G": ServerCat's short byte counts.
public enum ShortBytes {
    public static func pair(_ bytes: Double) -> (value: String, unit: String) {
        let units = ["B", "K", "M", "G", "T", "P"]
        var value = max(0, bytes.isFinite ? bytes : 0)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        let text = index == 0 || value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value)
        return (text, units[index])
    }

    public static func string(_ bytes: Double) -> String {
        let pair = pair(bytes)
        return "\(pair.value) \(pair.unit)"
    }
}

/// A bold number with a small grey unit; green when not zero.
public struct ValueText: View {
    let value: String
    let unit: String
    let active: Bool

    public init(_ value: String, unit: String, active: Bool) {
        self.value = value
        self.unit = unit
        self.active = active
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(active ? Color.rxSuccess : Color.rxInkSecondary)
                .contentTransition(.numericText())
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.rxInkSecondary)
            }
        }
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

public struct BytesText: View {
    let bytes: Double
    public init(_ bytes: Double) { self.bytes = bytes }

    public var body: some View {
        let pair = RXFormat.bytes(bytes)
        ValueText(pair.value, unit: pair.unit, active: bytes > 0)
    }
}

/// A ring with the percentage inside: used in the threshold colour, an
/// optional grey arc after it (memory cache), the rest light.
public struct RingGauge: View {
    let fraction: Double
    var cache: Double = 0
    var empty = false

    public init(fraction: Double, cache: Double = 0, empty: Bool = false) {
        self.fraction = fraction
        self.cache = cache
        self.empty = empty
    }

    public var body: some View {
        let used = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        let cached = min(max(cache.isFinite ? cache : 0, 0), 1 - used)
        ZStack {
            Circle()
                .stroke(Color.rxHairline, lineWidth: 4)
            Circle()
                .trim(from: used, to: used + cached)
                .stroke(Color.rxInkTertiary, style: StrokeStyle(lineWidth: 4, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: used)
                .stroke(rxUsageColor(used * 100, base: .rxSuccess), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(empty ? "—" : "\(RXFormat.percent(used * 100))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
                .contentTransition(.numericText())
        }
        .frame(width: 40, height: 40)
        .animation(.easeOut(duration: 0.5), value: used)
    }
}

/// Load as three concentric rings, 1, 5 and 15 minutes from the outside in,
/// each full at one task per core.
public struct LoadRings: View {
    let load: (Double, Double, Double)
    let cores: Int

    public init(load: (Double, Double, Double), cores: Int) {
        self.load = load
        self.cores = cores
    }

    public var body: some View {
        let values = [load.0, load.1, load.2].map { min(max($0 / Double(max(cores, 1)), 0), 1) }
        ZStack {
            ForEach(0 ..< 3, id: \.self) { ring in
                let size = 40 - CGFloat(ring) * 11
                Circle()
                    .stroke(Color.rxHairline, lineWidth: 4)
                    .frame(width: size, height: size)
                Circle()
                    .trim(from: 0, to: max(values[ring], 0.015))
                    .stroke(rxUsageColor(values[ring] * 100, base: .rxSuccess), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size, height: size)
            }
        }
        .frame(width: 40, height: 40)
        .animation(.easeOut(duration: 0.5), value: values)
        .help(String(localized: "Load \(String(format: "%.2f", load.0)) · \(String(format: "%.2f", load.1)) · \(String(format: "%.2f", load.2)) on \(cores) cores"))
    }
}

/// The first of its children whose ideal width fits the width proposed, as
/// ViewThatFits in the horizontal axis. The children are measured at their
/// ideal size, the same proposal every time, so SwiftUI's cache answers;
/// ViewThatFits measures them at each width it is given, and a sidebar
/// sliding over a page of cards gives it a new one every frame.
public struct FirstThatFits: Layout {
    public init() {}

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let chosen = chosen(proposal, subviews) else { return .zero }
        return subviews[chosen].sizeThatFits(.unspecified)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let chosen = chosen(proposal, subviews)
        for (index, subview) in subviews.enumerated() {
            if index == chosen {
                subview.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
            } else {
                // Out of the window, at no size: a layout places every child.
                subview.place(at: CGPoint(x: -100_000, y: -100_000), anchor: .topLeading, proposal: .zero)
            }
        }
    }

    private func chosen(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Int? {
        guard !subviews.isEmpty else { return nil }
        guard let width = proposal.width else { return 0 }
        return subviews.indices.first { subviews[$0].sizeThatFits(.unspecified).width <= width } ?? subviews.count - 1
    }
}

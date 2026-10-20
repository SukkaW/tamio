//
//  SidebarSlide.swift
//  Tamio (macOS)
//
//  The sidebar sliding open or closed. On macOS 26 the sidebar floats over the
//  content column, which keeps the window's width: what moves at every frame
//  of the slide is the column's leading safe-area inset. A page that follows
//  the inset is laid out again at each frame (Home's cards, Settings' rows, a
//  terminal), and the slide stutters. Instead the page is moved by an
//  animated offset, which is drawn but never laid out, and laid out once.
//

import AppKit
import SwiftUI
import TamioDesign

@MainActor
final class SidebarSlide: ObservableObject {
    static let shared = SidebarSlide()

    /// True from the first step of a slide until its last.
    @Published private(set) var sliding = false

    private var end: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        #if DEBUG
            // For measuring the slide as AppKit and SwiftUI do it on their own.
            if ProcessInfo.processInfo.environment["TAMIO_BENCH_NOHOLD"] != nil { return }
        #endif
        observer = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main
        ) { [weak self] note in
            let split = note.object as? NSSplitView
            MainActor.assumeIsolated { self?.resized(split) }
        }
    }

    private func resized(_ split: NSSplitView?) {
        guard let split, let window = split.window, window === Mac.mainWindow,
              split.isVertical, split.arrangedSubviews.count > 1
        else { return }
        if !sliding {
            // The window being resized, or the divider dragged, follows the
            // hand frame by frame; only the slide is taken over.
            guard !window.inLiveResize, NSEvent.pressedMouseButtons == 0 else { return }
            sliding = true
        }
        end?.cancel()
        let finish = DispatchWorkItem { [weak self] in self?.sliding = false }
        end = finish
        // Steps come every frame; a pause this long is the slide done.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: finish)
    }
}

/// Lays a page out at the sidebar's resting inset, and moves it with the
/// sidebar during a slide by an animated offset, which is only drawn, never
/// laid out. The page is laid out at most once per slide, where it is least
/// seen: at the end of an opening, at the start of a closing.
private struct FollowsSidebarWithoutLayout: ViewModifier {
    @ObservedObject private var slide = SidebarSlide.shared
    /// The leading inset the page is laid out at.
    @State private var inset: CGFloat = 0
    /// What the page is moved by, on its way to zero during a slide.
    @State private var shift: CGFloat = 0
    /// The inset with the sidebar open, the end of an opening slide.
    @State private var open: CGFloat = RX.sidebarWidth
    /// The inset the safe area gives now; read at a slide's start and end.
    @State private var measured = Measured()

    final class Measured { var inset: CGFloat = 0 }

    func body(content: Content) -> some View {
        content
            .padding(.leading, inset)
            .offset(x: shift)
            .ignoresSafeArea(.container, edges: .leading)
            .background {
                Color.clear.onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading } action: { value in
                    measured.inset = value
                    // At rest the page follows the inset (a window resized,
                    // the divider dragged); during a slide it does not.
                    if !slide.sliding, value != inset { inset = value }
                }
            }
            .onChange(of: slide.sliding) { _, sliding in
                if sliding { begin() } else { finish() }
            }
    }

    private func begin() {
        if inset > 1 { open = inset }
        // AppKit's slide: about a quarter of a second, easing in and out.
        let slide = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.25)
        if inset < open / 2 {
            // Opening: the page keeps its full width and only moves, running
            // past the window's edge until it is laid out narrower at the
            // end, once the motion has stopped.
            withAnimation(slide) { shift = open - inset }
        } else {
            // Closing: laid out at the full width it ends at, which covers
            // the column all the way, then moved there.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                shift = inset
                inset = 0
            }
            withAnimation(slide) { shift = 0 }
        }
    }

    private func finish() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            shift = 0
            if measured.inset != inset { inset = measured.inset }
        }
    }
}

extension View {
    @ViewBuilder func followsSidebarWithoutLayout() -> some View {
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAMIO_BENCH_NOHOLD"] != nil {
                self
            } else {
                modifier(FollowsSidebarWithoutLayout())
            }
        #else
            modifier(FollowsSidebarWithoutLayout())
        #endif
    }
}

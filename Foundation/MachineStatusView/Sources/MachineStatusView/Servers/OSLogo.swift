//
//  OSLogo.swift
//  MachineStatusView
//
//  The server's OS logo (Simple Icons, CC0), read from the release name it
//  reports. The icons are this package's own asset catalog.
//

import SwiftUI
import TamioModule
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

public struct OSLogo: View {
    @ObservedObject var session: MonitorSession
    var size: CGFloat = 13

    public init(session: MonitorSession, size: CGFloat = 13) {
        self.session = session
        self.size = size
    }

    public var body: some View {
        let release = session.status.system.releaseName
        if let asset = Self.asset(for: release) {
            // An image kept per asset: Image(name) looks the asset up again
            // at every layout, which the sidebar's slide does per frame.
            Self.image(asset)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.rxInkSecondary)
                .help(release)
                .accessibilityLabel(release)
        }
    }

    #if canImport(AppKit)
        nonisolated(unsafe) private static var images: [String: NSImage] = [:]

        @MainActor static func image(_ asset: String) -> Image {
            if let image = images[asset] { return Image(nsImage: image) }
            let image = Bundle.module.image(forResource: asset) ?? NSImage()
            image.isTemplate = true
            images[asset] = image
            return Image(nsImage: image)
        }
    #else
        nonisolated(unsafe) private static var images: [String: UIImage] = [:]

        @MainActor static func image(_ asset: String) -> Image {
            if let image = images[asset] { return Image(uiImage: image) }
            let image = UIImage(named: asset, in: .module, with: nil)?.withRenderingMode(.alwaysTemplate) ?? UIImage()
            images[asset] = image
            return Image(uiImage: image)
        }
    #endif

    /// "Ubuntu 24.04.1 LTS" → os-ubuntu, "macOS 26.6" → os-apple, any other
    /// Linux → the penguin.
    public static func asset(for release: String) -> String? {
        let name = release.lowercased()
        guard !name.isEmpty else { return nil }
        let marks: [(String, String)] = [
            ("macos", "os-apple"), ("mac os", "os-apple"), ("darwin", "os-apple"),
            ("ubuntu", "os-ubuntu"), ("debian", "os-debian"), ("fedora", "os-fedora"),
            ("arch", "os-archlinux"), ("alpine", "os-alpinelinux"), ("nixos", "os-nixos"),
            ("rocky", "os-rockylinux"), ("centos", "os-centos"), ("freebsd", "os-freebsd"),
            ("windows", "os-windows"),
        ]
        for (mark, asset) in marks where name.contains(mark) { return asset }
        return "os-linux"
    }
}

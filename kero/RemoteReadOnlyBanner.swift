//
//  RemoteReadOnlyBanner.swift
//  kero
//

import AppKit
import SwiftUI

/// Strip across the top of an editor or diff whose file lives on a remote
/// machine Kero can no longer reach. Saving is refused while it is up.
final class RemoteReadOnlyBannerView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    /// Matches the save-error bar in both viewers, which is the only other
    /// strip that appears in the same place.
    private static let tint = NSColor(
        srgbRed: 0.82, green: 0.60, blue: 0.13, alpha: 1
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor

        icon.image = NSImage(
            systemSymbolName: "lock.fill", accessibilityDescription: nil
        )
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        icon.contentTintColor = Self.tint
        label.font = .systemFont(ofSize: 11)
        label.textColor = Self.tint
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func update(message: String) {
        guard label.stringValue != message else { return }
        label.stringValue = message
        toolTip = message
    }

    /// The layer colour is resolved, so it has to be recomputed by hand when
    /// the system moves between light and dark.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
    }
}

/// The editor and diff panes around this banner are legacy SwiftUI, but new
/// chrome stays in AppKit — same split as the diff controls bar.
struct RemoteReadOnlyBanner: NSViewRepresentable {
    let message: String

    func makeNSView(context: Context) -> RemoteReadOnlyBannerView {
        RemoteReadOnlyBannerView(frame: .zero)
    }

    func updateNSView(_ view: RemoteReadOnlyBannerView, context: Context) {
        view.update(message: message)
    }
}

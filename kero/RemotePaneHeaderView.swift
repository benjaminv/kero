//
//  RemotePaneHeaderView.swift
//  kero
//

import AppKit

/// What the right pane's header says about where the panels are pointing.
///
/// Declared as its own type rather than taken from `WorkspaceLocation` so the
/// view has a case for a connection Kero is not managing, which is a fact
/// about the terminal rather than about any connection.
enum RemotePaneHeaderState: Equatable {
    case local
    case connecting(destination: String)
    case connected(destination: String)
    case disconnected(destination: String)
    /// An ssh process is in the foreground but Kero is not in front of it, so
    /// the remote tools cannot be offered. Showing local paths under a remote
    /// heading would be worse than saying nothing works.
    ///
    /// Deliberately a case of its own rather than a flag on ``unmanaged``: the
    /// two read the same to a user but mean opposite things to us. This one is
    /// the user's own choice - a raw `/usr/bin/ssh`, or an ssh from inside a
    /// remote shell - and nothing is wrong.
    case unmanaged
    /// The session started with Kero's shell integration and a stock ssh ran
    /// anyway, so the integration silently did not take. Worth distinguishing
    /// from ``unmanaged`` because this one is a fault on our side, and the
    /// heading is the only place it becomes visible.
    case helperBypassed
}

/// The right pane's remote heading: `user@host` with a lamp while connected,
/// and plain sentences for every other state.
///
/// Hidden entirely when the session is local, so a local window looks exactly
/// as it does today.
final class RemotePaneHeaderView: NSView {
    private enum Metrics {
        static let lamp: CGFloat = 6
        static let gap: CGFloat = 5
        static let titleSize: CGFloat = 12
        static let subtitleSize: CGFloat = 10
        static let titleToSubtitle: CGFloat = 1
    }

    private let lamp = NSView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private var lampWidth: NSLayoutConstraint?

    /// The directory the remote session is in, shown under the destination the
    /// way the panel headings show their path. Hidden while it is unknown,
    /// which it is until the working-directory probe has answered once.
    var workingDirectory: String? {
        didSet {
            guard workingDirectory != oldValue else { return }
            applyWorkingDirectory()
        }
    }

    /// Matches the sidebar's font scaling, so this heading grows with the
    /// panel titles beneath it rather than staying a fixed size.
    var fontScale: CGFloat = 1 {
        didSet {
            guard fontScale != oldValue else { return }
            applyFont()
        }
    }

    private(set) var state: RemotePaneHeaderState = .local

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        lamp.translatesAutoresizingMaskIntoConstraints = false
        lamp.wantsLayer = true
        lamp.layer?.cornerRadius = Metrics.lamp / 2
        lamp.layer?.cornerCurve = .circular

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyFont()

        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.textColor = .secondaryLabelColor
        // Truncating the head keeps the leaf directory visible, which is the
        // part that changes as the session moves around.
        subtitle.lineBreakMode = .byTruncatingHead
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(lamp)
        addSubview(label)
        addSubview(subtitle)

        let width = lamp.widthAnchor.constraint(equalToConstant: Metrics.lamp)
        lampWidth = width
        NSLayoutConstraint.activate([
            lamp.leadingAnchor.constraint(equalTo: leadingAnchor),
            lamp.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            width,
            lamp.heightAnchor.constraint(equalToConstant: Metrics.lamp),

            label.leadingAnchor.constraint(
                equalTo: lamp.trailingAnchor, constant: Metrics.gap),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),

            subtitle.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            subtitle.topAnchor.constraint(
                equalTo: label.bottomAnchor, constant: Metrics.titleToSubtitle),
            subtitle.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        apply(state: .local)
        applyWorkingDirectory()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - State

    func apply(state: RemotePaneHeaderState) {
        self.state = state
        isHidden = state == .local
        guard !isHidden else { return }

        label.stringValue = Self.title(for: state)
        label.textColor = Self.isProminent(state) ? .labelColor : .secondaryLabelColor
        toolTip = Self.tooltip(for: state)
        setAccessibilityLabel(label.stringValue)

        // The lamp is only meaningful while connected; its width collapses
        // otherwise so the text keeps a single left edge in every state.
        let showsLamp = Self.isProminent(state)
        lamp.isHidden = !showsLamp
        lamp.layer?.backgroundColor = NSColor.systemGreen.cgColor
        lampWidth?.constant = showsLamp ? Metrics.lamp : 0
        applyWorkingDirectory()
    }

    /// The state a `WorkspaceLocation` implies. `unmanaged` never comes from
    /// here: it is the caller's reading of the terminal, not of a connection.
    @MainActor
    static func headerState(for location: WorkspaceLocation) -> RemotePaneHeaderState {
        guard let connection = location.remoteConnection else { return .local }
        switch connection.state {
        case .connecting: return .connecting(destination: connection.displayName)
        case .connected: return .connected(destination: connection.displayName)
        case .disconnected: return .disconnected(destination: connection.displayName)
        }
    }

    @MainActor
    func apply(location: WorkspaceLocation) {
        apply(state: Self.headerState(for: location))
    }

    // MARK: - Wording

    private static func title(for state: RemotePaneHeaderState) -> String {
        switch state {
        case .local:
            return ""
        case .connected(let destination):
            return destination
        case .connecting(let destination):
            return String(
                format: String(
                    localized: "Connecting to %@...",
                    comment: "Right pane header while an ssh connection is being established; %@ is user@host."
                ),
                destination
            )
        case .disconnected(let destination):
            return String(
                format: String(
                    localized: "Disconnected from %@",
                    comment: "Right pane header after an ssh connection dropped; %@ is user@host."
                ),
                destination
            )
        case .unmanaged:
            return String(
                localized: "Remote tools unavailable - connection not managed by Kero",
                comment: "Right pane header when an ssh session was started in a way Kero cannot follow."
            )
        case .helperBypassed:
            return String(
                localized: "Remote tools unavailable - Kero's ssh helper was not used",
                comment: "Right pane header when Kero's shell integration is active but a stock ssh ran anyway, so the integration did not take effect."
            )
        }
    }

    /// The full destination, which the heading itself may have truncated.
    private static func tooltip(for state: RemotePaneHeaderState) -> String? {
        switch state {
        case .local, .unmanaged, .helperBypassed:
            return title(for: state).isEmpty ? nil : title(for: state)
        case .connected(let destination),
            .connecting(let destination),
            .disconnected(let destination):
            return destination
        }
    }

    private static func isProminent(_ state: RemotePaneHeaderState) -> Bool {
        if case .connected = state { return true }
        return false
    }

    /// Only meaningful next to a destination, so it goes away with the states
    /// that have no directory to speak of.
    private func applyWorkingDirectory() {
        let path = workingDirectory ?? ""
        subtitle.stringValue = path
        subtitle.isHidden = path.isEmpty || !Self.isProminent(state)
    }

    private func applyFont() {
        label.font = .systemFont(
            ofSize: Metrics.titleSize * fontScale, weight: .semibold
        )
        subtitle.font = .systemFont(ofSize: Metrics.subtitleSize * fontScale)
    }
}

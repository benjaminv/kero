//
//  WindowChrome.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

/// Keeps the traffic-light buttons aligned with the app's 38pt header bar:
/// 20pt leading, vertically centered on the header's center line. AppKit
/// re-lays the buttons out on various events, so we re-apply after each.
struct WindowChromeAccessor: NSViewRepresentable {
    static let buttonCenterY: CGFloat = 21
    static let buttonLeading: CGFloat = 16
    static let buttonSpacing: CGFloat = 20

    private let onAttach: (NSWindow) -> Void

    init(onAttach: @escaping (NSWindow) -> Void = { _ in }) {
        self.onAttach = onAttach
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onAttach: onAttach)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(window)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window {
            context.coordinator.attach(window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private let onAttach: (NSWindow) -> Void

        init(onAttach: @escaping (NSWindow) -> Void) {
            self.onAttach = onAttach
        }

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            onAttach(window)
            // Interactive controls occupy the title-bar region. Disable the
            // server-side title-bar drag entirely; WindowDragArea is the only
            // surface that opts into moving the window.
            window.isMovable = false
            reposition()
            // The initial system layout can land after us; catch up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.reposition() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.reposition() }

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didResignMainNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.reposition()
                    }
                })
            }
        }

        private func reposition() {
            guard let window else { return }
            window.isMovable = false
            guard !window.styleMask.contains(.fullScreen) else { return }
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in types.enumerated() {
                guard let button = window.standardWindowButton(type),
                      let superview = button.superview
                else { continue }
                let centerInWindow = NSPoint(
                    x: WindowChromeAccessor.buttonLeading + CGFloat(index) * WindowChromeAccessor.buttonSpacing + button.frame.width / 2,
                    y: window.frame.height - WindowChromeAccessor.buttonCenterY
                )
                let center = superview.convert(centerInWindow, from: nil)
                let origin = NSPoint(
                    x: center.x - button.frame.width / 2,
                    y: center.y - button.frame.height / 2
                )
                if button.frame.origin != origin {
                    button.setFrameOrigin(origin)
                }
            }
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

/// A deliberate window-moving surface. Interactive header controls are kept
/// outside this view so their own drag gestures receive the full mouse stream.
///
/// Double-clicking runs the standard title-bar action (zoom / minimize per
/// System Settings) — behavior our non-movable, hidden title bar would
/// otherwise lose. The tap is simultaneous with the drag: a stationary
/// double-click never registers a move, so the two don't conflict.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                NSApp.keyWindow?.performTitlebarDoubleClickAction()
            })
            .allowsWindowActivationEvents()
    }
}

extension NSWindow {
    /// Mirrors what a standard title bar does on double-click, honoring the
    /// "Double-click a window's title bar to" setting in System Settings.
    /// The global default is absent when set to Zoom, which is the default.
    func performTitlebarDoubleClickAction() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            performMiniaturize(nil)
        case "None":
            break
        default: // "Maximize" or unset
            performZoom(nil)
        }
    }
}

/// The window's profile, shown as a pill in the header's drag area so the
/// active CLI accounts are identifiable at a glance. Windows on the System
/// profile show nothing: that is the unconfigured default, and a badge on
/// every window would be noise.
///
/// The pill sits above the SwiftUI header rather than inside it, keeping new
/// UI in AppKit. It never takes mouse events, so the window drag underneath
/// still works.
@MainActor
final class ProfileBadgeView: NSView {
    /// Header height (38) centered, minus the pill's own height.
    private static let height: CGFloat = 20
    /// Clears the right-sidebar toggle and the header's trailing padding.
    private static let trailingInset: CGFloat = 40
    private static let maximumWidth: CGFloat = 120
    private static let horizontalPadding: CGFloat = 9

    private var title = "" {
        didSet {
            guard title != oldValue else { return }
            resize()
            needsDisplay = true
        }
    }

    private var observations: [AnyCancellable] = []

    init(manager: TerminalManager) {
        super.init(frame: .zero)
        autoresizingMask = [.minXMargin, .minYMargin]
        wantsLayer = true
        observations = [
            manager.$profileID.sink { [weak self] id in
                MainActor.assumeIsolated { self?.apply(profileID: id) }
            },
            // @Published fires before the array is swapped in, so read the
            // renamed profile on the next turn of the run loop.
            ProfileStore.shared.$profiles.sink { [weak manager] _ in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let manager else { return }
                        self.apply(profileID: manager.profileID)
                    }
                }
            },
            Theme.changes.objectWillChange.sink { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The header's own controls own every click in this region.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func apply(profileID: String) {
        let profile = ProfileStore.shared.profile(id: profileID)
        isHidden = profile.isSystem
        title = profile.displayName
    }

    private var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: Theme.accent,
            .paragraphStyle: paragraph,
        ]
    }

    private func resize() {
        guard let superview else { return }
        let text = (title as NSString).size(withAttributes: attributes).width
        let width = min(
            Self.maximumWidth,
            (text + Self.horizontalPadding * 2).rounded(.up)
        )
        frame = NSRect(
            x: superview.bounds.width - Self.trailingInset - width,
            y: superview.bounds.height - (38 + Self.height) / 2,
            width: width,
            height: Self.height
        )
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resize()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.accent.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let attributes = attributes
        let size = (title as NSString).size(withAttributes: attributes)
        let textRect = NSRect(
            x: Self.horizontalPadding,
            y: (bounds.height - size.height).rounded() / 2,
            width: bounds.width - Self.horizontalPadding * 2,
            height: size.height
        )
        (title as NSString).draw(in: textRect, withAttributes: attributes)
    }
}

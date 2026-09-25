//
//  TunnelSettingsView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

/// The Port Forwarding section of Settings: saved forwards with a switch,
/// what each reaches, its local port and a live status in words.
///
/// AppKit-owned, mounted into the legacy SwiftUI Settings form through
/// ``TunnelSettingsRow`` like the terminal cursor rows.
@MainActor
final class TunnelSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum Column {
        static let enabled = NSUserInterfaceItemIdentifier("enabled")
        static let name = NSUserInterfaceItemIdentifier("name")
        static let remote = NSUserInterfaceItemIdentifier("remote")
        static let local = NSUserInterfaceItemIdentifier("local")
        static let status = NSUserInterfaceItemIdentifier("status")
    }

    private let manager = TunnelManager.shared
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addRemoveControl = NSSegmentedControl()
    private let emptyLabel = NSTextField(
        labelWithString: String(localized: "No saved forwards. Click + to add one.")
    )
    private var subscriptions: Set<AnyCancellable> = []
    /// Ticks once a second while any row counts down to a retry, so
    /// "retrying in 12 s" stays true without redrawing an idle table.
    private var countdownTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildTable()
        buildControls()

        manager.$tunnels
            .combineLatest(manager.$states)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.reload() }
            .store(in: &subscriptions)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 176)
    }

    // MARK: - Layout

    private func buildTable() {
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (Column.enabled, "", 24),
            (Column.name, String(localized: "Name"), 110),
            (Column.remote, String(localized: "Forwards to"), 150),
            (Column.local, String(localized: "Local port"), 70),
            (Column.status, String(localized: "Status"), 150),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = identifier == Column.enabled ? 24 : 50
            if identifier == Column.enabled { column.maxWidth = 24 }
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 22
        tableView.style = .inset
        tableView.target = self
        tableView.doubleAction = #selector(editClickedRow)
        tableView.setAccessibilityLabel(String(localized: "Saved port forwards"))

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
    }

    private func buildControls() {
        addRemoveControl.segmentCount = 2
        addRemoveControl.trackingMode = .momentary
        addRemoveControl.segmentStyle = .smallSquare
        addRemoveControl.setImage(
            NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Add forward")),
            forSegment: 0)
        addRemoveControl.setImage(
            NSImage(systemSymbolName: "minus", accessibilityDescription: String(localized: "Remove forward")),
            forSegment: 1)
        addRemoveControl.setToolTip(String(localized: "Add forward"), forSegment: 0)
        addRemoveControl.setToolTip(String(localized: "Remove selected forward"), forSegment: 1)
        addRemoveControl.target = self
        addRemoveControl.action = #selector(addRemoveClicked)
        addRemoveControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addRemoveControl)

        let note = NSTextField(
            wrappingLabelWithString: String(
                localized: "Forwards stay open while Kero is running, even with no terminal connected. They use your ssh keys and ~/.ssh/config; Kero never asks for a password."
            ))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        addSubview(note)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 112),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            addRemoveControl.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            addRemoveControl.leadingAnchor.constraint(equalTo: leadingAnchor),

            note.topAnchor.constraint(equalTo: addRemoveControl.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: leadingAnchor),
            note.trailingAnchor.constraint(equalTo: trailingAnchor),
            note.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    // MARK: - Data

    private func reload() {
        let selectedID = selectedTunnel?.id
        tableView.reloadData()
        if let selectedID, let row = manager.tunnels.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        emptyLabel.isHidden = !manager.tunnels.isEmpty
        addRemoveControl.setEnabled(selectedTunnel != nil, forSegment: 1)
        updateCountdownTimer()
    }

    private var selectedTunnel: TunnelDefinition? {
        tunnel(at: tableView.selectedRow)
    }

    private func tunnel(at row: Int) -> TunnelDefinition? {
        manager.tunnels.indices.contains(row) ? manager.tunnels[row] : nil
    }

    private func updateCountdownTimer() {
        let counting = manager.states.values.contains {
            if case .failed(_, let retryAt?) = $0 { return retryAt > Date() }
            return false
        }
        if counting, countdownTimer == nil {
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatusColumn() }
            }
        } else if !counting {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }

    private func refreshStatusColumn() {
        let column = tableView.column(withIdentifier: Column.status)
        guard column >= 0, tableView.numberOfRows > 0 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<tableView.numberOfRows),
            columnIndexes: IndexSet(integer: column))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            countdownTimer?.invalidate()
            countdownTimer = nil
        } else {
            updateCountdownTimer()
        }
    }

    /// The status in words, never by color alone.
    private func statusText(for tunnel: TunnelDefinition) -> (text: String, detail: String?) {
        guard tunnel.isEnabled else { return (String(localized: "Off"), nil) }
        switch manager.state(for: tunnel.id) {
        case .stopped:
            return (String(localized: "Stopped"), nil)
        case .connecting:
            return (String(localized: "Connecting…"), nil)
        case .up:
            return (String(localized: "Connected"), nil)
        case .failed(let message, let retryAt):
            guard let retryAt else { return (String(localized: "Failed: \(message)"), message) }
            let seconds = max(0, Int(retryAt.timeIntervalSinceNow.rounded(.up)))
            return (
                String(localized: "Failed, retrying in \(String(seconds)) s: \(message)"),
                message
            )
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        manager.tunnels.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let tunnel = tunnel(at: row) else { return nil }

        if tableColumn.identifier == Column.enabled {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(enabledToggled(_:)))
            checkbox.state = tunnel.isEnabled ? .on : .off
            checkbox.tag = row
            checkbox.setAccessibilityLabel(String(localized: "Keep \(tunnel.name) open"))
            return checkbox
        }

        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeTextCell(identifier: identifier)
        let field = cell.textField
        field?.toolTip = nil
        switch identifier {
        case Column.name:
            field?.stringValue = tunnel.name
        case Column.remote:
            field?.stringValue = tunnel.remoteDescription
        case Column.local:
            field?.stringValue = String(tunnel.localPort)
        default:
            let status = statusText(for: tunnel)
            field?.stringValue = status.text
            field?.toolTip = status.detail
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        addRemoveControl.setEnabled(selectedTunnel != nil, forSegment: 1)
    }

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        if identifier == Column.local {
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        if identifier == Column.status || identifier == Column.remote {
            field.textColor = .secondaryLabelColor
        }
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tunnel = tunnel(at: tableView.clickedRow) else { return }
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = tunnel.id
            return item
        }
        menu.addItem(item(String(localized: "Copy Local Address"), #selector(copyLocalAddress(_:))))
        if tunnel.isEnabled {
            menu.addItem(item(String(localized: "Reconnect"), #selector(restartTunnel(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Edit…"), #selector(editTunnel(_:))))
        menu.addItem(item(String(localized: "Delete"), #selector(deleteTunnel(_:))))
    }

    // MARK: - Actions

    @objc private func enabledToggled(_ sender: NSButton) {
        guard let tunnel = tunnel(at: sender.tag) else { return }
        let enable = sender.state == .on
        if enable, let other = manager.conflict(localPort: tunnel.localPort, excluding: tunnel.id) {
            sender.state = .off
            showAlert(
                String(localized: "Local port \(String(tunnel.localPort)) is already used by “\(other.name)”."),
                detail: String(localized: "Turn that forward off or give this one a different local port."))
            return
        }
        manager.setEnabled(enable, id: tunnel.id)
    }

    @objc private func addRemoveClicked() {
        if addRemoveControl.selectedSegment == 0 {
            presentEditor(for: nil)
        } else if let tunnel = selectedTunnel {
            manager.remove(id: tunnel.id)
        }
    }

    @objc private func editClickedRow() {
        guard let tunnel = tunnel(at: tableView.clickedRow) else { return }
        presentEditor(for: tunnel)
    }

    @objc private func copyLocalAddress(_ sender: NSMenuItem) {
        guard let tunnel = tunnel(withID: sender.representedObject) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tunnel.localAddress, forType: .string)
    }

    @objc private func restartTunnel(_ sender: NSMenuItem) {
        guard let tunnel = tunnel(withID: sender.representedObject) else { return }
        manager.restart(id: tunnel.id)
    }

    @objc private func editTunnel(_ sender: NSMenuItem) {
        guard let tunnel = tunnel(withID: sender.representedObject) else { return }
        presentEditor(for: tunnel)
    }

    @objc private func deleteTunnel(_ sender: NSMenuItem) {
        guard let tunnel = tunnel(withID: sender.representedObject) else { return }
        manager.remove(id: tunnel.id)
    }

    private func tunnel(withID object: Any?) -> TunnelDefinition? {
        guard let id = object as? UUID else { return nil }
        return manager.tunnels.first { $0.id == id }
    }

    private func presentEditor(for existing: TunnelDefinition?) {
        guard let window else { return }
        let editor = TunnelEditorController(existing: existing)
        editor.onSave = { [weak self] tunnel in
            guard let self else { return }
            if existing == nil {
                self.manager.add(tunnel)
            } else {
                self.manager.update(tunnel)
            }
        }
        editor.present(on: window)
    }

    private func showAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - Editor sheet

/// The add/edit sheet: name, host, remote host and port, local port, and
/// whether to open it now. Validation runs on Save and keeps the sheet open
/// with the reason shown under the fields.
@MainActor
private final class TunnelEditorController: NSObject, NSTextFieldDelegate {
    var onSave: ((TunnelDefinition) -> Void)?

    private let existing: TunnelDefinition?
    private let sheet: NSWindow
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let remoteHostField = NSTextField()
    private let remotePortField = NSTextField()
    private let localPortField = NSTextField()
    private let enabledCheckbox = NSButton(
        checkboxWithTitle: String(localized: "Keep this forward open"), target: nil, action: nil)
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    /// Until the user types a local port, it follows the remote one, since
    /// the same number is what pages that hardcode their own port need.
    private var localPortEdited = false
    /// Keeps the controller alive while its sheet is up.
    private var retainedSelf: TunnelEditorController?

    init(existing: TunnelDefinition?) {
        self.existing = existing
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 10),
            styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        build()
    }

    func present(on window: NSWindow) {
        retainedSelf = self
        window.beginSheet(sheet) { [weak self] _ in
            self?.retainedSelf = nil
        }
        sheet.makeFirstResponder(existing == nil ? hostField : nameField)
    }

    private func build() {
        let tunnel = existing
        nameField.stringValue = tunnel?.name ?? ""
        nameField.placeholderString = String(localized: "A1 desktop")
        hostField.stringValue = tunnel?.host ?? ""
        hostField.placeholderString = String(localized: "oracle or user@host")
        remoteHostField.stringValue = tunnel?.remoteHost ?? "127.0.0.1"
        remotePortField.stringValue = tunnel.map { String($0.remotePort) } ?? ""
        remotePortField.placeholderString = "3389"
        localPortField.stringValue = tunnel.map { String($0.localPort) } ?? ""
        localPortField.placeholderString = String(localized: "Same as remote")
        enabledCheckbox.state = (tunnel?.isEnabled ?? true) ? .on : .off
        localPortEdited = tunnel != nil
        remotePortField.delegate = self
        localPortField.delegate = self

        for field in [nameField, hostField, remoteHostField, remotePortField, localPortField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }

        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        let grid = NSGridView(views: [
            [label(String(localized: "Name:")), nameField],
            [label(String(localized: "SSH host:")), hostField],
            [label(String(localized: "Remote host:")), remoteHostField],
            [label(String(localized: "Remote port:")), remotePortField],
            [label(String(localized: "Local port:")), localPortField],
            [NSGridCell.emptyContentView, enabledCheckbox],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        problemLabel.textColor = .systemRed
        problemLabel.isHidden = true
        problemLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: String(localized: "Save"), target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, save])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        content.addSubview(problemLabel)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            problemLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            problemLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            problemLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            buttons.topAnchor.constraint(equalTo: problemLabel.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        sheet.contentView = content
        sheet.setContentSize(content.fittingSize)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === localPortField {
            localPortEdited = !localPortField.stringValue.isEmpty
        } else if field === remotePortField, !localPortEdited,
            let remote = Int(remotePortField.stringValue),
            TunnelDefinition.localPortRange.contains(remote)
        {
            localPortField.stringValue = String(remote)
        }
    }

    @objc private func cancel() {
        sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
    }

    @objc private func save() {
        func trimmed(_ field: NSTextField) -> String {
            field.stringValue.trimmingCharacters(in: .whitespaces)
        }
        guard let remotePort = Int(trimmed(remotePortField)) else {
            return show(String(localized: "Enter the remote port as a number."))
        }
        let localText = trimmed(localPortField)
        guard let localPort = localText.isEmpty ? remotePort : Int(localText) else {
            return show(String(localized: "Enter the local port as a number."))
        }
        let host = trimmed(hostField)
        let name = trimmed(nameField)
        var tunnel = existing ?? TunnelDefinition(name: "", host: "", localPort: 0, remotePort: 0)
        tunnel.name = name.isEmpty ? "\(host):\(remotePort)" : name
        tunnel.host = host
        tunnel.remoteHost = trimmed(remoteHostField)
        tunnel.remotePort = remotePort
        tunnel.localPort = localPort
        tunnel.isEnabled = enabledCheckbox.state == .on

        if let problem = tunnel.validationProblem {
            return show(problem)
        }
        if tunnel.isEnabled,
            let other = TunnelManager.shared.conflict(localPort: localPort, excluding: tunnel.id)
        {
            return show(
                String(localized: "Local port \(String(localPort)) is already used by “\(other.name)”."))
        }
        onSave?(tunnel)
        sheet.sheetParent?.endSheet(sheet, returnCode: .OK)
    }

    private func show(_ problem: String) {
        problemLabel.stringValue = problem
        problemLabel.isHidden = false
        sheet.setContentSize(sheet.contentView?.fittingSize ?? sheet.frame.size)
        NSAccessibility.post(
            element: problemLabel, notification: .announcementRequested,
            userInfo: [.announcement: problem, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

// MARK: - SwiftUI mount point

struct TunnelSettingsRow: NSViewRepresentable {
    func makeNSView(context: Context) -> TunnelSettingsView {
        TunnelSettingsView(frame: .zero)
    }

    func updateNSView(_ view: TunnelSettingsView, context: Context) {}
}

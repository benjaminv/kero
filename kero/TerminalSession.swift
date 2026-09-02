//
//  TerminalSession.swift
//  kero
//

import AppKit
import Combine
import Darwin
import Foundation

/// One long-lived terminal process rendered by one terminal surface. Normally
/// that process is the user's login shell; a CLI-created project can instead
/// exec an explicit argv directly. SwiftUI only reparents the same surface, so
/// PTY state, selection, and scrollback survive tab and split-layout changes.
///
/// Which emulator draws that surface is `TerminalBackend`'s business: this
/// type talks to ``TerminalBackendSurface`` and hears back through
/// ``TerminalBackendEvents``, and names no emulator's types itself.
@MainActor
final class TerminalSession: NSObject, nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id: UUID

    @Published var title: String
    @Published var workingDirectory: String?
    @Published var hasExited = false
    @Published private(set) var commandLifecycle = TerminalCommandLifecycle()
    @Published private(set) var terminalCellSize: CGSize?
    /// Recognized coding agent occupying this terminal, if any. The monitor
    /// reconciles foreground process identity with explicit lifecycle events.
    @Published var agentStatus: KeroAgentStatus?

    /// Where this session's right pane looks. Set by Kero's `ssh` helper
    /// through the automation socket, never guessed from the foreground
    /// process: an ssh Kero did not front cannot be followed.
    @Published var location: WorkspaceLocation = .local
    /// The connection this session most recently left. Open editor tabs use it
    /// to recognise their own remote after `exit` has returned the pane to the
    /// local machine.
    @Published private(set) var lastRemoteConnection: RemoteConnection?

    /// The emulator driving this session. Fixed for the session's lifetime —
    /// changing the setting only affects terminals opened afterwards.
    let backend: TerminalBackend
    let surface: any TerminalBackendSurface
    let overlayScrollbar = OverlayScrollbarView()
    /// Find-in-terminal state for this session's pane (⌘F).
    let find: TerminalFind
    var onExited: ((TerminalSession) -> Void)?

    private static let persistedHistoryLineLimit = 500

    private let shellPath: String
    private let launchWorkingDirectory: String
    private let launchDirectoryURL: URL?
    private let shellPidFileURL: URL?
    private var cachedShellPid: pid_t?
    private var remoteMonitor: Task<Void, Never>?
    private var remoteObservation: AnyCancellable?
    private var lastHistorySnapshot: String?
    private var isTerminating = false
    private var commandExecutionStartedAtNanos: UInt64?
    /// Alternate-screen transcript paging must begin at the live prompt, never
    /// from text the user has scrolled back to inspect.
    var terminalIsAtLiveBottom = true
    let agentObservation = KeroAgentObservationState()

    init(
        initialDirectory: String? = nil,
        restoredHistory: String? = nil,
        commandArguments: [String]? = nil,
        environmentPath: String? = nil
    ) {
        let sessionID = UUID()
        let directCommand = commandArguments.flatMap { $0.isEmpty ? nil : $0 }
        let shellPath = directCommand?.first ?? Self.loginShell()
        let directory = Self.validWorkingDirectory(initialDirectory)
        let artifacts = Self.makeLaunchArtifacts(restoredHistory: restoredHistory)
        let backend = AppSettings.shared.terminalBackend
        let script = Self.makeLaunchScript(
            backend: backend,
            shellPath: shellPath,
            commandArguments: directCommand,
            pidFileURL: artifacts.pidFileURL,
            replayFileURL: artifacts.replayFileURL
        )
        let launch = TerminalLaunch(
            program: "/bin/sh",
            arguments: ["-c", script],
            commandLine: "/bin/sh -c \(Self.shellQuote(script))",
            workingDirectory: directory,
            environment: Self.surfaceEnvironment(
                pathOverride: environmentPath,
                sessionID: sessionID,
                shellPath: shellPath
            )
        )

        id = sessionID
        self.shellPath = shellPath
        self.backend = backend
        launchWorkingDirectory = directory
        launchDirectoryURL = artifacts.directoryURL
        shellPidFileURL = artifacts.pidFileURL
        title = (shellPath as NSString).lastPathComponent
        agentStatus = nil

        let surface = Self.makeSurface(backend: backend, launch: launch)
        self.surface = surface
        find = TerminalFind(surface: surface)
        lastHistorySnapshot = restoredHistory
        super.init()

        surface.events = self
        installOverlayScrollbar()
        applyTheme()
        AgentAutomationMonitor.shared.register(self)
    }

    deinit {
        if let launchDirectoryURL {
            try? FileManager.default.removeItem(at: launchDirectoryURL)
        }
    }

    /// `makeSurface` returns nil only for a backend this build has no surface
    /// for, and `AppSettings` refuses to store one — so this is belt and
    /// braces, preferring a working terminal over an empty pane.
    private static func makeSurface(
        backend: TerminalBackend, launch: TerminalLaunch
    ) -> any TerminalBackendSurface {
        if let surface = backend.makeSurface(launch: launch) { return surface }
        NSLog("kero: no surface for terminal backend \(backend.rawValue)")
        return KeroTerminalView(launch: launch)
    }

    private func installOverlayScrollbar() {
        overlayScrollbar.alphaValue = 0
        overlayScrollbar.onScroll = { [weak self] position in
            self?.surface.scroll(toFraction: position)
        }
    }

    /// Reconfigures the surface in place when either appearance or terminal
    /// font settings change.
    func applyTheme() {
        surface.applyAppearance()
    }

    /// Stops the whole PTY job before releasing the surface. The backend's
    /// teardown owns the final reap; sending HUP first gives shells the same
    /// close signal they received before the backend migration.
    func terminate() {
        guard !hasExited, !isTerminating else { return }
        isTerminating = true
        beginTeardown(processAlive: true, notifyExit: false)
    }

    /// Keeps the session and surface alive until the child has either exited
    /// or been force-stopped. Detaching first can make a backend wait
    /// synchronously for a process that ignored SIGHUP.
    private func beginTeardown(processAlive: Bool, notifyExit: Bool) {
        // TerminalHostView normally clears these while dismantling, but close
        // teardown must not depend on a later SwiftUI reconciliation pass.
        // These callbacks originate on PaneView and capture this session.
        surface.setSurfaceVisible(false)
        surface.onBecomeFirstResponder = nil
        surface.splitTarget.onSplit = nil
        surface.splitTarget.onNewBrowserTab = nil
        surface.splitTarget.onNewBrowserPane = nil
        surface.splitTarget.onNewFileTab = nil
        surface.splitTarget.onNewFilePane = nil

        if processAlive {
            _ = shellPid // Cache it before `hasExited` changes.
            signalTerminalJob(SIGHUP)
        }

        Task { @MainActor [self] in
            if processAlive {
                // Give well-behaved shells a moment to unwind, then guarantee
                // surface teardown cannot wait indefinitely.
                try? await Task.sleep(for: .milliseconds(120))
                signalTerminalJob(SIGKILL)
            } else {
                // Avoid freeing the surface reentrantly from the backend's
                // process-close callback.
                await Task.yield()
            }
            surface.detach()
            hasExited = true
            removeLaunchArtifacts()
            if notifyExit { onExited?(self) }
        }
    }

    private func signalTerminalJob(_ signal: Int32) {
        var pids = Set<pid_t>()
        if let shellPid { pids.insert(shellPid) }
        if let foreground = surface.foregroundPid, foreground > 0 {
            pids.insert(foreground)
        }
        for pid in pids where pid > 1 {
            // Interactive shells and their foreground jobs normally lead
            // distinct process groups. Signal the group, then the leader as a
            // fallback for an unusual launch configuration.
            _ = Darwin.kill(-pid, signal)
            _ = Darwin.kill(pid, signal)
        }
    }

    private func removeLaunchArtifacts() {
        endRemoteConnection(reason: "terminal closed")
        KeroCLIService.shared.revokeTerminal(id: id)
        guard let launchDirectoryURL else { return }
        try? FileManager.default.removeItem(at: launchDirectoryURL)
    }

    // MARK: - Remote workspace

    /// Adopts the connection Kero's `ssh` helper just announced and starts
    /// watching it. Exactly one connection per session: an `ssh` typed from
    /// inside an already-remote shell is nested and is not followed.
    @discardableResult
    func beginRemoteConnection(_ connection: RemoteConnection) -> Bool {
        // A live connection means this ssh was typed from inside the remote
        // shell. That is nested and Kero does not follow it. A connection that
        // has already finished is simply the previous one, and the session is
        // free to go remote again.
        if let existing = location.remoteConnection, existing.state != .disconnected {
            NSLog(
                "kero: ignoring nested ssh in terminal %@ (already remote)",
                id.uuidString
            )
            return false
        }
        endRemoteConnection(reason: "replaced by a new connection")
        location = .remote(connection)
        // The connection is its own observable object, so republish its
        // changes or views bound to the session never see a state change.
        remoteObservation = connection.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        remoteMonitor = Task { [weak self] in
            await self?.watchRemoteConnection(connection)
        }
        return true
    }

    func endRemoteConnection(reason: String) {
        remoteMonitor?.cancel()
        remoteMonitor = nil
        remoteObservation = nil
        guard let connection = location.remoteConnection else { return }
        connection.markDisconnected(reason: reason)
        lastRemoteConnection = connection
    }

    /// The pane returns to the local machine only when the ssh process itself
    /// is gone, which is what `exit` does. A connection that drops while ssh is
    /// still running keeps the pane remote and disconnected on purpose: falling
    /// back to local paths under a remote heading is the one outcome to avoid.
    private func returnToLocal(_ connection: RemoteConnection, reason: String) {
        connection.markDisconnected(reason: reason)
        lastRemoteConnection = connection
        location = .local
        remoteObservation = nil
    }

    /// One check a second. While connecting, only the ssh process going away
    /// is a failure: the control socket does not exist until authentication
    /// finishes, and a password or a hardware key can take a while.
    private func watchRemoteConnection(_ connection: RemoteConnection) async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            tick += 1

            guard connection.isSSHProcessAlive else {
                returnToLocal(connection, reason: "ssh process exited")
                return
            }
            switch connection.state {
            case .connecting:
                guard connection.controlSocketExists else { continue }
                guard await connection.check() else { continue }
                connection.markConnected()
                // Probe straight away rather than waiting for the next tick:
                // the backend and the panel path only switch to the remote
                // together, once this answers.
                await probeRemoteWorkingDirectory(connection)
            case .connected:
                // The master removes its socket on exit, so this is both
                // cheaper and faster than waiting for a check to fail.
                guard connection.controlSocketExists else {
                    connection.markDisconnected(reason: "control socket removed")
                    return
                }
                if tick.isMultiple(of: 2) {
                    // One round trip per 2 s, matching the panel refresh.
                    // `run` checks liveness itself and marks the connection
                    // disconnected, so no separate check is needed here.
                    await probeRemoteWorkingDirectory(connection)
                } else if await connection.check() == false {
                    connection.markDisconnected(reason: "control socket check failed")
                    return
                }
            case .disconnected:
                return
            }
        }
    }

    /// Finds the remote shell's directory over the shared channel. A miss
    /// keeps the last known directory: the lookup can fail transiently while a
    /// command is running, and dropping the path would bounce the panels.
    private func probeRemoteWorkingDirectory(_ connection: RemoteConnection) async {
        let found = try? await connection.workspaceBackend.remoteWorkingDirectory(
            terminalTag: id.uuidString
        )
        guard let directory = found?.directory, !directory.isEmpty else { return }
        if connection.workingDirectory != directory {
            connection.workingDirectory = directory
        }
    }

    /// Short label for the sidebar: the tail of the current directory, if known.
    var directoryLabel: String? {
        guard let dir = workingDirectory else { return nil }
        let path = URL(string: dir)?.path ?? dir
        let tail = (path as NSString).lastPathComponent
        return tail.isEmpty ? nil : tail
    }

    /// Best-effort live shell directory: OSC 7 first, kernel process metadata
    /// second, then the directory used to launch this session.
    var currentDirectoryPath: String {
        if let dir = workingDirectory {
            if let url = URL(string: dir), url.isFileURL { return url.path }
            if dir.hasPrefix("/") { return dir }
        }
        if let shellPid, let path = processWorkingDirectory(pid: shellPid) {
            return path
        }
        return launchWorkingDirectory
    }

    /// Working directory of the terminal's foreground job, when that job is
    /// something other than the shell itself. Coding agents change their own
    /// process directory when they move to another checkout — Claude Code's
    /// worktree switch is a `chdir` inside the running `claude` process — and
    /// the shell never moves, so no OSC 7 arrives and `currentDirectoryPath`
    /// keeps describing the old tree. This is deliberately a separate fact:
    /// `currentDirectoryPath` must stay true to the shell.
    var foregroundDirectoryPath: String? {
        // While the session is remote this would be the ssh client's own local
        // directory, which means nothing on the other machine.
        guard location.remoteConnection == nil else { return nil }
        guard let foreground = surface.foregroundPid, foreground > 0,
              foreground != shellPid
        else { return nil }
        return processWorkingDirectory(pid: foreground)
    }

    func sendCommand(_ text: String) {
        surface.sendText(text)
    }

    /// Clears the emulator's visible screen and scrollback, then asks the
    /// foreground shell to repaint its prompt at the top.
    func clear() {
        surface.clearScreen()
    }

    /// Styled VT snapshot used by the existing sidecar history store. A
    /// scrollback/PID heuristic keeps a full-screen alternate buffer from
    /// replacing the last saved shell scrollback in normal shell/TUI use.
    func serializedHistory(captureLive: Bool) -> String? {
        guard AppSettings.shared.restoreTerminalHistory else { return nil }
        guard captureLive else { return lastHistorySnapshot }

        let rootShellIsForeground = shellPid != nil
            && surface.foregroundPid == shellPid
        if !rootShellIsForeground,
           !TerminalHistorySerializer.hasPrimaryScrollback(surface) {
            // A primary screen with no rows above the viewport and an
            // alternate screen both have no scrollback export. The root shell
            // is foreground only in the former case; a TUI owns its own
            // foreground process group in the latter.
            return lastHistorySnapshot
        }
        switch TerminalHistorySerializer.capture(
            from: surface, maxLines: Self.persistedHistoryLineLimit
        ) {
        case .captured(let snapshot):
            lastHistorySnapshot = snapshot
            return snapshot
        case .failed:
            return lastHistorySnapshot
        }
    }

    var shellName: String {
        (shellPath as NSString).lastPathComponent
    }

    /// PID of the root terminal process. The launch shim records its own PID
    /// before `exec`, so this remains stable while a shell's foreground PID
    /// moves to child jobs and back.
    var shellPid: pid_t? {
        if let cachedShellPid, cachedShellPid > 0 { return cachedShellPid }
        guard !hasExited, let shellPidFileURL,
              let text = try? String(contentsOf: shellPidFileURL, encoding: .utf8),
              let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0
        else { return nil }
        cachedShellPid = value
        return value
    }

    /// The workspace the right pane, editor and diff viewer operate on for
    /// this session. Always the Mac's own disk today; a session ssh'd into a
    /// remote machine will answer with a backend that runs over that channel.
    var workspaceBackend: WorkspaceBackend {
        guard let connection = connectedRemote else { return LocalWorkspaceBackend.shared }
        return connection.workspaceBackend
    }

    /// The directory the right pane, editor and diff viewer work in. The same
    /// as ``currentDirectoryPath`` locally, and the remote shell's directory
    /// once this session is connected to another machine.
    ///
    /// Deliberately separate from ``currentDirectoryPath``, which seeds new
    /// local terminals and the saved session snapshot and must stay a path on
    /// this Mac.
    var panelDirectoryPath: String {
        guard let directory = connectedRemote?.workingDirectory else {
            return currentDirectoryPath
        }
        return directory
    }

    /// What the right pane's heading should say for this session.
    ///
    /// The `unmanaged` case is the one Kero cannot serve: an ssh is running in
    /// the foreground but it did not come through Kero's helper, so there is no
    /// channel to work over. Saying so is better than showing this Mac's files
    /// under the remote's name.
    var remoteHeaderState: RemotePaneHeaderState {
        if location.remoteConnection != nil {
            return RemotePaneHeaderView.headerState(for: location)
        }
        return isRunningUnmanagedSSH ? .unmanaged : .local
    }

    /// True when the foreground job is an ssh client Kero is not in front of.
    /// The kernel-reported image is used rather than the tab title, which is
    /// terminal output the remote can write.
    private var isRunningUnmanagedSSH: Bool {
        guard let foreground = surface.foregroundPid, foreground > 0,
              foreground != shellPid,
              let path = processExecutablePath(pid: foreground)
        else { return false }
        return (path as NSString).lastPathComponent == "ssh"
    }

    /// The remote this session is fully ready to work on. Both the backend and
    /// the panel path read this, so the pane can never pair a remote backend
    /// with a local path or the reverse.
    private var connectedRemote: RemoteConnection? {
        guard let connection = location.remoteConnection,
              connection.state == .connected,
              connection.workingDirectory != nil
        else { return nil }
        return connection
    }

    // MARK: - Launch

    private static func surfaceEnvironment(
        pathOverride: String?,
        sessionID: UUID,
        shellPath: String
    ) -> [String: String] {
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
        ]
        environment.merge(
            KeroCLIService.shared.terminalEnvironment(for: sessionID),
            uniquingKeysWith: { _, cliValue in cliValue }
        )
        environment.merge(
            zshIntegrationEnvironment(shellPath: shellPath),
            uniquingKeysWith: { _, integrationValue in integrationValue }
        )
        if let pathOverride, !pathOverride.isEmpty {
            environment["PATH"] = pathOverride
        }
        // Locale belongs to the user's shell environment. Kero's app language
        // must never synthesize or override LANG/LC_* for terminal processes.
        return environment
    }

    /// Points zsh at Kero's own startup directory.
    ///
    /// The bundled `.zshenv` restores the user's `ZDOTDIR` and sources their
    /// files before doing anything, so their shell starts exactly as it would
    /// otherwise; it then adds an interactive `ssh` function that routes
    /// through Kero's helper.
    ///
    /// This replaces shadowing `ssh` on `PATH`, which cannot work on macOS:
    /// `/etc/zprofile` runs `path_helper`, which rebuilds `PATH` with the
    /// system directories first and leaves anything Kero prepended behind
    /// `/usr/bin`. A shell function is also the better tool, because it
    /// applies only to what the user types and never to scripts or agents.
    private static func zshIntegrationEnvironment(
        shellPath: String
    ) -> [String: String] {
        guard (shellPath as NSString).lastPathComponent == "zsh",
              let resources = Bundle.main.resourceURL,
              let executables = Bundle.main.executableURL?.deletingLastPathComponent()
        else { return [:] }

        let directory = resources
            .appendingPathComponent("shell-integration/zsh", isDirectory: true)
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".zshenv").path
        ) else { return [:] }

        var environment = [
            "ZDOTDIR": directory.path,
            // argv[0] must still be `ssh`, so this names the symlink rather
            // than the app binary it points at.
            "KERO_SSH_HELPER": executables.appendingPathComponent("ssh").path,
        ]
        // Only set when the user had one, so the bundled file can tell
        // "restore this" from "there was none".
        if let existing = ProcessInfo.processInfo.environment["ZDOTDIR"],
           !existing.isEmpty {
            environment["KERO_ZSH_ZDOTDIR"] = existing
        }
        return environment
    }

    private struct LaunchArtifacts {
        let directoryURL: URL?
        let pidFileURL: URL?
        let replayFileURL: URL?
    }

    private static func makeLaunchArtifacts(restoredHistory: String?) -> LaunchArtifacts {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("kero-terminal-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let pidFile = directory.appendingPathComponent("shell.pid")
            var replayFile: URL?
            if AppSettings.shared.restoreTerminalHistory,
               let restoredHistory,
               !restoredHistory.isEmpty {
                let file = directory.appendingPathComponent("history.vt")
                let separator = restoredHistory.hasSuffix("\n") ? "" : "\r\n"
                let contents = restoredHistory + separator
                    + TerminalHistorySerializer.restoredBanner() + "\r\n"
                try Data(contents.utf8).write(to: file, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path
                )
                replayFile = file
            }
            return LaunchArtifacts(
                directoryURL: directory,
                pidFileURL: pidFile,
                replayFileURL: replayFile
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            NSLog("kero: failed to prepare terminal launch files: \(error)")
            return LaunchArtifacts(directoryURL: nil, pidFileURL: nil, replayFileURL: nil)
        }
    }

    /// The `sh` script every pane starts with: record the process PID, replay
    /// any restored scrollback, advertise the emulator, then become either the
    /// requested argv or the user's login shell.
    private static func makeLaunchScript(
        backend: TerminalBackend,
        shellPath: String,
        commandArguments: [String]?,
        pidFileURL: URL?,
        replayFileURL: URL?
    ) -> String {
        var commands: [String] = []
        if let pidFileURL {
            // The PID file is the only thing this script creates, so the
            // tightened mask stays inside a subshell: `umask` outlives the
            // `exec` below, and a terminal that leaves the user's shell at 077
            // silently makes every file they create private. `$$` keeps
            // expanding to this shell's PID inside the subshell — the same PID
            // `exec` hands to the shell itself.
            commands.append(
                "(umask 077; printf '%s\\n' \"$$\" > \(shellQuote(pidFileURL.path)))"
            )
        }
        if let replayFileURL {
            let path = shellQuote(replayFileURL.path)
            commands.append("if [ -r \(path) ]; then /bin/cat \(path); /bin/rm -f \(path); fi")
        }
        // KERO_TERM exposes the actual surface. TERM_PROGRAM remains a
        // capability hint so tools select protocols Kero can actually render.
        commands.append("export KERO_TERM=\(shellQuote(backend.environmentName))")
        let termProgram = backend.termProgram
        commands.append("export TERM_PROGRAM=\(shellQuote(termProgram.name))")
        if !termProgram.version.isEmpty {
            commands.append(
                "export TERM_PROGRAM_VERSION=\(shellQuote(termProgram.version))"
            )
        } else {
            commands.append("unset TERM_PROGRAM_VERSION")
        }
        if let commandArguments {
            let argv = commandArguments.map(shellQuote).joined(separator: " ")
            // `env` resolves argv[0] against the caller's PATH. Every argument
            // is quoted independently, so no command text is reparsed or
            // expanded by the launch shim.
            commands.append("exec /usr/bin/env -- \(argv)")
        } else {
            commands.append("exec \(shellQuote(shellPath)) -l")
        }
        // Ghostty's macOS launcher prepends `exec -l` to a shell command.
        // Keeping the setup as one compound command means `exec -l` does not
        // stop after the first shell builtin.
        return commands.joined(separator: "; ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validWorkingDirectory(_ requested: String?) -> String {
        var isDirectory: ObjCBool = false
        if let requested,
           FileManager.default.fileExists(atPath: requested, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return requested
        }
        return NSHomeDirectory()
    }

    private static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}

// MARK: - Terminal surface callbacks

extension TerminalSession: TerminalBackendEvents {
    func terminalDidChangeTitle(_ title: String) {
        guard !title.isEmpty else { return }
        self.title = title
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        workingDirectory = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).absoluteString : path
    }

    func terminalDidChangeCellSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0,
              terminalCellSize != size else { return }
        terminalCellSize = size
    }

    func terminalDidRingBell() {
        NSSound.beep()
        guard !surface.hasEffectiveTerminalFocus else { return }
        TerminalNotificationService.shared.post(
            message: String(localized: "Terminal bell"),
            sessionID: id
        )
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func terminalDidReportShellIntegration(_ event: TerminalShellIntegrationEvent) {
        var lifecycle = commandLifecycle
        switch event {
        case .promptStart:
            lifecycle.phase = .prompt
        case .commandStart:
            lifecycle.phase = .input
        case .commandExecuting:
            lifecycle.phase = .executing
            commandExecutionStartedAtNanos = DispatchTime.now().uptimeNanoseconds
        case let .commandFinished(exitCode, reportedDuration):
            let measuredDuration = commandExecutionStartedAtNanos.flatMap { started in
                let now = DispatchTime.now().uptimeNanoseconds
                return now >= started ? now - started : nil
            }
            lifecycle.phase = .idle
            lifecycle.lastExitCode = exitCode
            lifecycle.lastDurationNanos = reportedDuration ?? measuredDuration
            lifecycle.completionSequence &+= 1
            commandExecutionStartedAtNanos = nil
        }
        commandLifecycle = lifecycle
    }

    func terminalDidClose(processAlive: Bool) {
        guard !isTerminating else { return }
        isTerminating = true
        beginTeardown(processAlive: processAlive, notifyExit: true)
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        let message = body.isEmpty ? title : body
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        TerminalNotificationService.shared.post(message: message, sessionID: id)
    }

    func terminalDidRequestOpenURL(_ value: String) {
        guard let target = terminalLinkTarget(for: value) else { return }
        switch target {
        case .file(let fileURL):
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        case .url(let url):
            NSWorkspace.shared.open(url)
        }
    }

    /// Classifies a detected terminal link only after proving a local path
    /// exists or a non-file URL has a scheme. Context menus and Command-click
    /// use this same answer, so neither offers an action it cannot perform.
    func terminalLinkTarget(for value: String) -> TerminalLinkTarget? {
        if let fileURL = existingFileURL(from: value) {
            return .file(fileURL)
        }
        guard let url = URL(string: value),
              url.scheme != nil,
              !url.isFileURL
        else { return nil }
        return .url(url)
    }

    /// Resolves terminal links the way the shell would: `file:` URLs are
    /// already absolute, `~` belongs to the current user, and other paths are
    /// relative to this pane's live working directory. Diagnostics commonly
    /// append `:line[:column]`, so try the literal path before peeling those
    /// numeric locations off.
    private func existingFileURL(from value: String) -> URL? {
        let candidate: URL
        if let url = URL(string: value), url.scheme != nil {
            guard url.isFileURL else { return nil }
            candidate = url
        } else {
            let decoded = value.removingPercentEncoding ?? value
            let expanded = (decoded as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                candidate = URL(fileURLWithPath: expanded)
            } else {
                let basePath = foregroundDirectoryPath ?? currentDirectoryPath
                candidate = URL(
                    fileURLWithPath: expanded,
                    relativeTo: URL(fileURLWithPath: basePath, isDirectory: true)
                )
            }
        }

        var url = candidate.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            let strippedPath = url.path.replacingOccurrences(
                of: #":\d+$"#,
                with: "",
                options: .regularExpression
            )
            guard strippedPath != url.path else { return nil }
            url = URL(fileURLWithPath: strippedPath).standardizedFileURL
        }
    }

    func terminalDidScroll(_ position: TerminalScrollPosition) {
        terminalIsAtLiveBottom = position.position >= 0.999
        overlayScrollbar.update(
            position: position.position,
            proportion: position.proportion,
            active: position.isScrollable
        )
    }

    func terminalDidBeginFind(needle: String) {
        find.started(needle: needle)
    }

    func terminalDidEndFind() {
        find.ended()
    }

    func terminalDidUpdateFindTotal(_ total: Int?) {
        find.update(total: total)
    }

    func terminalDidUpdateFindSelected(_ selected: Int?) {
        find.update(selected: selected)
    }

    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardRequest) {
        guard let window = surface.window else {
            request.deny()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch request.kind {
        case .unsafePaste:
            alert.messageText = String(localized: "Warning: Potentially Unsafe Paste")
            alert.informativeText =
                String(localized: "Pasting this text to the terminal may be dangerous because it looks like one or more commands may execute.")
        case .programRead:
            alert.messageText = String(localized: "Authorize Clipboard Access")
            alert.informativeText =
                String(localized: "A program is attempting to read from the clipboard. The current clipboard contents are shown below.")
        }
        alert.accessoryView = Self.clipboardPreview(request.contents)
        alert.addButton(withTitle: request.kind == .unsafePaste
            ? String(localized: "Paste")
            : String(localized: "Allow"))
        let cancel = alert.addButton(
            withTitle: request.kind == .unsafePaste
                ? String(localized: "Cancel")
                : String(localized: "Deny")
        )
        cancel.keyEquivalent = "\u{1b}"

        Task { @MainActor in
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                request.approve()
            } else {
                request.deny()
            }
        }
    }

    /// Bounded, read-only preview of the text under decision, mirroring
    /// the preview area in Ghostty's own confirmation dialog.
    private static func clipboardPreview(_ contents: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        // A pathological clipboard can be arbitrarily large; the decision
        // only needs a glimpse.
        text.string = String(contents.prefix(4096))
        text.autoresizingMask = [.width]
        scroll.documentView = text
        return scroll
    }
}

//
//  TunnelManager.swift
//  kero
//

import AppKit
import Combine
import Darwin
import Foundation

/// What a saved forward is doing right now, as Settings shows it.
enum TunnelState: Equatable {
    case stopped
    case connecting
    case up
    case failed(message: String, retryAt: Date?)
}

/// Keeps the enabled saved forwards open for as long as Kero runs, with no
/// terminal pane involved, so other apps (an RDP client, a browser) can use
/// them.
///
/// This is the one place Kero authenticates on its own. `RemoteConnection`
/// only ever rides the ssh the user typed; a background forward has no such
/// session, so it starts `/usr/bin/ssh` itself. It keeps that honest by
/// never prompting (`BatchMode=yes`: keys and agent only, and ssh's own
/// error is shown instead), never binding anything but loopback, never
/// starting a forward the user did not add and switch on, and never feeding
/// the Files, Git or Info panels.
@MainActor
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var tunnels: [TunnelDefinition] = []
    @Published private(set) var states: [UUID: TunnelState] = [:]

    private var runners: [UUID: TunnelRunner] = [:]
    private var observers: [NSObjectProtocol] = []
    private var started = false

    private init() {}

    /// Loads the saved forwards and opens the enabled ones. Called once at
    /// launch; later calls do nothing.
    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        TunnelStore.runSelfCheck()
        #endif
        TunnelPIDFile.terminateLeftovers()
        tunnels = TunnelStore.load()
        reconcile()

        // After sleep the old TCP session is dead, but ssh would only notice
        // once ServerAlive gives up, about 45 seconds later. Start over now.
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { TunnelManager.shared.restartEnabled() }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { TunnelManager.shared.stopAll() }
            })
    }

    // MARK: - Editing

    func add(_ tunnel: TunnelDefinition) {
        tunnels.append(tunnel)
        commit()
    }

    func update(_ tunnel: TunnelDefinition) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        tunnels[index] = tunnel
        commit()
    }

    func remove(id: UUID) {
        tunnels.removeAll { $0.id == id }
        commit()
    }

    func setEnabled(_ isEnabled: Bool, id: UUID) {
        guard let index = tunnels.firstIndex(where: { $0.id == id }) else { return }
        tunnels[index].isEnabled = isEnabled
        commit()
    }

    /// Drops the current ssh and connects again straight away, resetting the
    /// retry delay.
    func restart(id: UUID) {
        runners[id]?.restartNow()
    }

    /// Another enabled forward already claiming `localPort`, if any.
    func conflict(localPort: Int, excluding id: UUID) -> TunnelDefinition? {
        tunnels.first { $0.isEnabled && $0.id != id && $0.localPort == localPort }
    }

    func state(for id: UUID) -> TunnelState {
        states[id] ?? .stopped
    }

    private func commit() {
        TunnelStore.save(tunnels)
        reconcile()
    }

    // MARK: - Runners

    /// Brings the running processes in line with the saved list: starts what
    /// is newly enabled, stops what was removed or disabled, and restarts a
    /// forward whose definition changed.
    private func reconcile() {
        let wanted = Dictionary(
            tunnels.filter(\.isEnabled).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (id, runner) in runners where wanted[id] != runner.definition {
            runner.stop()
            runners[id] = nil
            states[id] = nil
        }
        for (id, definition) in wanted where runners[id] == nil {
            let runner = TunnelRunner(definition: definition) { [weak self] state in
                self?.states[id] = state
            }
            runners[id] = runner
            runner.start()
        }
        // Forget states for forwards that no longer exist at all.
        let known = Set(tunnels.map(\.id))
        states = states.filter { known.contains($0.key) }
    }

    private func restartEnabled() {
        for runner in runners.values { runner.restartNow() }
    }

    private func stopAll() {
        for runner in runners.values { runner.stop() }
        runners.removeAll()
        TunnelPIDFile.write([])
    }

    /// Called by runners whenever an ssh starts or exits, so the file always
    /// names exactly the processes a crash would leave behind.
    fileprivate func recordProcesses() {
        TunnelPIDFile.write(runners.values.compactMap(\.processIdentifier))
    }
}

// MARK: - One forward

/// Owns the ssh process for one enabled forward and keeps it running:
/// launch, detect that the listener is up, and relaunch with backoff when it
/// exits.
@MainActor
private final class TunnelRunner {
    let definition: TunnelDefinition
    private let report: (TunnelState) -> Void

    private var process: Process?
    private var errorOutput = TunnelStderrBuffer()
    private var attempts = 0
    private var upSince: Date?
    private var retryTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var isStopped = false

    /// A forward that stayed up this long counts as healthy again, so the
    /// next drop retries quickly rather than at the capped delay.
    private static let healthyAfter: TimeInterval = 60
    private static let maximumDelay: TimeInterval = 60
    /// Three seconds, in quarter-second checks, for a previous ssh to release
    /// the local port.
    private static let portReleaseChecks = 12

    var processIdentifier: pid_t? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    init(definition: TunnelDefinition, report: @escaping (TunnelState) -> Void) {
        self.definition = definition
        self.report = report
    }

    func start() {
        isStopped = false
        launch()
    }

    func stop() {
        isStopped = true
        retryTask?.cancel()
        readinessTask?.cancel()
        terminateProcess()
        report(.stopped)
    }

    func restartNow() {
        guard !isStopped else { return }
        retryTask?.cancel()
        readinessTask?.cancel()
        attempts = 0
        terminateProcess()
        launch()
    }

    private func launch() {
        guard !isStopped else { return }
        if let problem = definition.validationProblem {
            report(.failed(message: problem, retryAt: nil))
            return
        }
        // ssh would bind 127.0.0.1 with SO_REUSEADDR and could succeed beside
        // a local server on *:port; refuse instead so the browser never
        // reaches the wrong one. See RemoteCommands.isLocalPortFree.
        //
        // A busy port is often our own previous ssh still exiting: every
        // restart (wake, Reconnect, an edit, a quick off and on) stops one
        // process and starts the next at once. Give it a moment to let go
        // before calling the port taken.
        let port = UInt16(definition.localPort)
        guard RemoteCommands.isLocalPortFree(port) else {
            report(.connecting)
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                for _ in 0..<Self.portReleaseChecks {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled, !self.isStopped else { return }
                    if RemoteCommands.isLocalPortFree(port) {
                        self.spawn()
                        return
                    }
                }
                guard let self, !Task.isCancelled, !self.isStopped else { return }
                self.scheduleRetry(
                    message: String(
                        localized: "Port \(String(self.definition.localPort)) is already in use on this Mac."))
            }
            return
        }
        spawn()
    }

    private func spawn() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15",
            // Never share, or become, the master for the user's interactive
            // sessions when their config sets `ControlMaster auto`.
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "LogLevel=ERROR",
            "-L", definition.forwardSpecification,
            "--", definition.host,
        ]
        var environment = ProcessInfo.processInfo.environment
        // The error text shown in Settings must not follow the user's locale.
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let buffer = TunnelStderrBuffer()
        errorOutput = buffer
        let pipe = Pipe()
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                buffer.append(data)
            }
        }

        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                self?.processExited(finished, status: status)
            }
        }

        do {
            try process.run()
        } catch {
            scheduleRetry(message: error.localizedDescription)
            return
        }
        self.process = process
        TunnelManager.shared.recordProcesses()
        report(.connecting)
        NSLog(
            "kero: tunnel %@ started ssh pid %d for %@",
            definition.name, process.processIdentifier, definition.forwardSpecification)
        watchForListener(process)
    }

    /// `ssh -N` prints nothing once the forward is ready. With
    /// `ExitOnForwardFailure` it exits if the listener can't be set up, so a
    /// process that is still running while the local port has become busy
    /// is a working forward.
    private func watchForListener(_ process: Process) {
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.process === process, process.isRunning
                else { return }
                if !RemoteCommands.isLocalPortFree(UInt16(self.definition.localPort)) {
                    self.upSince = Date()
                    self.report(.up)
                    return
                }
            }
        }
    }

    private func processExited(_ finished: Process, status: Int32) {
        guard finished === process else { return }
        process = nil
        readinessTask?.cancel()
        TunnelManager.shared.recordProcesses()
        guard !isStopped else { return }

        if let upSince, Date().timeIntervalSince(upSince) >= Self.healthyAfter {
            attempts = 0
        }
        upSince = nil
        let message = errorOutput.lastLine
            ?? String(localized: "ssh exited with status \(String(status)).")
        NSLog("kero: tunnel %@ ssh exited (%d): %@", definition.name, status, message)
        scheduleRetry(message: message)
    }

    private func scheduleRetry(message: String) {
        attempts += 1
        let delay = min(Self.maximumDelay, pow(2, Double(attempts)))
        report(.failed(message: message, retryAt: Date().addingTimeInterval(delay)))
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.isStopped else { return }
            self.launch()
        }
    }

    private func terminateProcess() {
        guard let process else { return }
        self.process = nil
        TunnelManager.shared.recordProcesses()
        guard process.isRunning else { return }
        process.terminate()
        // ssh exits promptly on SIGTERM; one that doesn't would keep the port
        // and block the forward that replaces it.
        let pid = process.processIdentifier
        Task {
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }
}

/// ssh's stderr, written from the pipe's reader thread and read on the main
/// actor once the process exits. Only the tail matters: the last line is
/// usually the reason, such as "Permission denied (publickey)".
private nonisolated final class TunnelStderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private static let limit = 4_096
    /// Lines ssh prints after the real reason. A busy port ends with
    /// "bind [127.0.0.1]:13389: Address already in use", then these two.
    private static let followUpPrefixes = [
        "channel_setup_fwd_listener",
        "Could not request local forwarding",
    ]

    init() {}

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > Self.limit { data = data.suffix(Self.limit) }
    }

    var lastLine: String? {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { line in
                !line.isEmpty && !Self.followUpPrefixes.contains { line.hasPrefix($0) }
            }
    }
}

// MARK: - Crash leftovers

/// The ssh processes Kero started, recorded so a crashed Kero's forwards can
/// be cleaned up on the next launch. macOS has no parent-death signal, so a
/// `kill -9` of Kero leaves `ssh -N` holding its ports.
///
/// Each entry is a pid plus the process start time, and a leftover is only
/// terminated when both still match and the image is `/usr/bin/ssh`, so a
/// pid the system has since reused is never touched.
private enum TunnelPIDFile {
    static var url: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "sh.kero")
            .appendingPathComponent("tunnels.pids")
    }

    static func write(_ pids: [pid_t]) {
        let lines = pids.compactMap { pid in
            startTime(of: pid).map { "\(pid) \($0)" }
        }
        do {
            if lines.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n")
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("kero: failed to write \(url.path): \(error)")
        }
    }

    static func terminateLeftovers() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 2,
                let pid = pid_t(fields[0]),
                let recorded = UInt64(fields[1]),
                startTime(of: pid) == recorded,
                processExecutablePath(pid: pid) == "/usr/bin/ssh"
            else { continue }
            NSLog("kero: terminating leftover tunnel ssh pid %d", pid)
            Darwin.kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Seconds since the epoch at which `pid` started, or nil if it is gone.
    private static func startTime(of pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec
    }
}

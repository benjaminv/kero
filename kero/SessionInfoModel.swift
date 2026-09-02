//
//  SessionInfoModel.swift
//  kero
//

import Combine
import Darwin
import Foundation

/// Polls `ps`/`lsof` for the active session's shell: the processes running
/// under it and any TCP ports those processes are listening on.
@MainActor
final class SessionInfoModel: nonisolated ObservableObject {
    struct ProcessItem: Identifiable, Equatable {
        var id: pid_t { pid }
        let pid: pid_t
        /// Executable name, e.g. "node".
        let name: String
        /// Full executable path, for tooltips.
        let executable: String
        /// Percent CPU as `ps` reports it.
        let cpu: Double
        /// Resident set size in kilobytes.
        let memoryKB: Int

        var memoryLabel: String {
            ByteCountFormatter.string(
                fromByteCount: Int64(memoryKB) * 1024,
                countStyle: .memory
            )
        }
    }

    struct PortItem: Identifiable, Equatable {
        var id: String { "\(pid):\(port)" }
        let port: Int
        let pid: pid_t
        let processName: String

        var url: URL? { URL(string: "http://localhost:\(port)/") }
    }

    @Published private(set) var rootPath = ""
    /// The project directory the file tree and git panels anchor to —
    /// shown alongside the live cwd so both are visible at a glance.
    @Published private(set) var projectRootPath = ""
    /// Which rule produced that directory — pinned, the shell's repository,
    /// or the repository the foreground job moved to.
    @Published private(set) var projectRootSource = Project.PanelRootSource.shell
    @Published private(set) var shellName = ""
    @Published private(set) var shellPid: pid_t = 0
    @Published private(set) var processes: [ProcessItem] = []
    @Published private(set) var ports: [PortItem] = []

    private var isRefreshing = false
    /// The workspace this panel describes. Replaced on every `sync`, so the
    /// panel follows its session between the local machine and a remote one.
    private var backend: WorkspaceBackend = LocalWorkspaceBackend.shared

    func sync(
        root: String,
        projectRoot: String,
        projectRootSource: Project.PanelRootSource,
        shellName: String,
        shellPid: pid_t?,
        backend: WorkspaceBackend
    ) async {
        self.backend = backend
        if rootPath != root { rootPath = root }
        if projectRootPath != projectRoot { projectRootPath = projectRoot }
        if self.projectRootSource != projectRootSource {
            self.projectRootSource = projectRootSource
        }
        if self.shellName != shellName { self.shellName = shellName }
        let pid = shellPid ?? 0
        if self.shellPid != pid { self.shellPid = pid }
        await refresh()
    }

    func refresh() async {
        let pid = shellPid
        guard pid > 0 else {
            if !processes.isEmpty { processes = [] }
            if !ports.isEmpty { ports = [] }
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true

        let (processes, ports) = await Self.snapshot(shellPid: pid, backend: backend)
        isRefreshing = false
        // A tab switch may have re-targeted us while the poll ran.
        guard shellPid == pid else { return }
        if self.processes != processes { self.processes = processes }
        if self.ports != ports { self.ports = ports }
    }

    /// SIGTERM (or SIGKILL when `force`), then a delayed re-poll so the
    /// row disappears once the process is actually gone.
    func kill(_ pid: pid_t, force: Bool = false) async {
        try? await backend.kill(pid: pid, force: force)
        try? await Task.sleep(for: .milliseconds(300))
        await refresh()
    }

    // MARK: - Polling

    private static func snapshot(
        shellPid: pid_t, backend: WorkspaceBackend
    ) async -> ([ProcessItem], [PortItem]) {
        guard let snapshot = try? await backend.processes(descendantsOf: shellPid)
        else { return ([], []) }
        let processes = snapshot.descendants.map {
            ProcessItem(
                pid: $0.pid,
                name: $0.name,
                executable: $0.executable,
                cpu: $0.cpu,
                memoryKB: $0.memoryKB
            )
        }
        let listening = (try? await backend.listeningPorts(
            pids: [shellPid] + processes.map(\.pid)
        )) ?? []
        // A listening socket can belong to the shell itself, which is not one
        // of its own descendants, so names come from the whole process table.
        let ports = listening.map {
            PortItem(
                port: $0.port,
                pid: $0.pid,
                processName: snapshot.namesByPid[$0.pid] ?? "?"
            )
        }
        return (processes, ports)
    }
}

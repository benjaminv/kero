//
//  SSHWorkspaceBackend.swift
//  kero
//

import Darwin
import Foundation

/// Runs one command on the remote machine and returns what it printed.
///
/// Declared here rather than taken from the ssh connection type so this file
/// can be built and tested before that lands; the connection conforms to it.
nonisolated protocol RemoteCommandRunner: Sendable {
    func run(
        _ argv: [String], stdin: Data?, timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: Data, stderr: Data)
}

/// A remote command that failed, carrying the remote's own message so the
/// panel can show what the remote said rather than a generic failure.
nonisolated struct RemoteCommandFailure: LocalizedError {
    let command: String
    let status: Int32
    let message: String

    var errorDescription: String? {
        message.isEmpty ? "Remote command failed (status \(status))." : message
    }
}

/// The workspace on a Linux machine reached over an existing ssh connection.
///
/// Files and processes only. Git still runs locally, so the git methods report
/// that they are unsupported rather than pretending.
///
/// Every method is a single round trip: build the command with
/// `RemoteCommands`, run it, parse the output.
nonisolated final class SSHWorkspaceBackend: WorkspaceBackend {
    private let runner: RemoteCommandRunner
    private let timeout: TimeInterval

    init(runner: RemoteCommandRunner, timeout: TimeInterval = 10) {
        self.runner = runner
        self.timeout = timeout
    }

    /// Exit codes the built commands use to report a condition precisely,
    /// rather than leaving it to be guessed from an error message.
    private enum ExitCode {
        static let missing: Int32 = 44
        static let exists: Int32 = 45
    }

    // MARK: - Running

    @discardableResult
    private func shell(_ command: String, stdin: Data? = nil) async throws -> Data {
        let result = try await runner.run([command], stdin: stdin, timeout: timeout)
        guard result.status == 0 else {
            throw failure(command: command, result: result)
        }
        return result.stdout
    }

    private func failure(
        command: String, result: (status: Int32, stdout: Data, stderr: Data)
    ) -> Error {
        switch result.status {
        case ExitCode.missing: return WorkspaceError.notFound
        case ExitCode.exists: return CocoaError(.fileWriteFileExists)
        default:
            let message = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RemoteCommandFailure(
                command: command, status: result.status, message: message
            )
        }
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// Guards a command so a missing path is reported as `notFound` rather
    /// than as whatever message the tool happened to print.
    private func requiring(_ path: String, _ command: String) -> String {
        "[ -e \(RemoteCommands.quote(path)) ] || exit \(ExitCode.missing); " + command
    }

    // MARK: - Files

    func list(directory: String) async throws -> [WorkspaceEntry] {
        let command = requiring(directory, RemoteCommands.listDirectoryCommand(path: directory))
        return RemoteCommands.parseDirectoryListing(try await shell(command))
    }

    func stat(path: String) async throws -> WorkspaceStat? {
        // A missing path is not an error here: the local backend answers nil.
        let output = try await shell(RemoteCommands.statCommand(path: path) + "; :")
        return RemoteCommands.parseStat(text(output))?.stat
    }

    func readSymlinkDestination(path: String) async throws -> String? {
        let quoted = RemoteCommands.quote(path)
        let output = try await shell("readlink -- \(quoted) 2>/dev/null; :")
        let destination = text(output).trimmingCharacters(in: .newlines)
        return destination.isEmpty ? nil : destination
    }

    /// Reads one byte past the cap so an oversized file can be told apart from
    /// one that happens to be exactly `maxBytes` long.
    func read(path: String, maxBytes: Int) async throws -> Data {
        let quoted = RemoteCommands.quote(path)
        let limit = maxBytes == .max ? nil : maxBytes + 1
        let read = limit.map { "head -c \($0) -- \(quoted)" } ?? "cat -- \(quoted)"
        let data = try await shell(requiring(path, read))
        if let limit, data.count == limit { throw WorkspaceError.tooLarge }
        return data
    }

    func write(path: String, data: Data) async throws {
        try await shell(RemoteCommands.atomicWriteCommand(path: path), stdin: data)
    }

    /// Truncates an existing file, matching `FileManager.createFile`.
    func createFile(path: String) async throws {
        try await shell(": > \(RemoteCommands.quote(path))")
    }

    /// No `-p`: the local backend creates one level and fails when the
    /// directory already exists, and the panel's wording depends on that.
    func createDirectory(path: String) async throws {
        try await shell("mkdir -- \(RemoteCommands.quote(path))")
    }

    /// `mv -n` would skip silently when the destination exists, so the check
    /// is explicit and reports the same "already exists" the local move does.
    func rename(from: String, to: String) async throws {
        let source = RemoteCommands.quote(from)
        let destination = RemoteCommands.quote(to)
        try await shell(
            requiring(
                from,
                "[ -e \(destination) ] && exit \(ExitCode.exists); mv -- \(source) \(destination)"
            )
        )
    }

    /// There is no remote Trash: freedesktop trash semantics vary between
    /// distributions, and a file quietly moved somewhere unexpected is worse
    /// than an explicit delete. The caller confirms first.
    func delete(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let quoted = paths.map(RemoteCommands.quote).joined(separator: " ")
        try await shell("rm -rf -- \(quoted)")
    }

    // MARK: - Git geography

    /// Read-only, and needed before any panel can pick its root.
    func gitRoot(containing path: String) async throws -> String? {
        let quoted = RemoteCommands.quote(path)
        let output = try await shell(
            "git -C \(quoted) rev-parse --show-toplevel 2>/dev/null; :"
        )
        let root = text(output).trimmingCharacters(in: .newlines)
        return root.isEmpty ? nil : root
    }

    /// A linked worktree has `.git` as a file pointing into the main
    /// repository, not as a directory.
    func isLinkedWorktree(_ root: String) async throws -> Bool {
        let marker = RemoteCommands.quote((root as NSString).appendingPathComponent(".git"))
        let output = try await shell(
            "[ -f \(marker) ] && grep -c '/worktrees/' \(marker) 2>/dev/null; :"
        )
        return (Int(text(output).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    // MARK: - Processes

    func run(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?
    ) async throws -> WorkspaceRunResult {
        guard !argv.isEmpty else { throw WorkspaceError.notFound }
        var command = ""
        if let cwd { command += "cd \(RemoteCommands.quote(cwd)) && " }
        if let env, !env.isEmpty {
            let assignments = env.keys.sorted().map { "\($0)=\(RemoteCommands.quote(env[$0]!))" }
            command += "env " + assignments.joined(separator: " ") + " "
        }
        command += argv.map(RemoteCommands.quote).joined(separator: " ")

        let result = try await runner.run(
            [command], stdin: stdin, timeout: timeout ?? self.timeout
        )
        return WorkspaceRunResult(
            status: result.status, stdout: result.stdout, stderr: result.stderr
        )
    }

    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot {
        let output = try await shell(RemoteCommands.processListCommand())
        let rows = RemoteCommands.parseProcessList(text(output))
        return RemoteCommands.snapshot(rows: rows, descendantsOf: pid)
    }

    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] {
        let output = try await shell(RemoteCommands.listeningPortsCommand())
        let wanted = Set(pids)
        return RemoteCommands.parseListeningPorts(text(output))
            .filter { wanted.contains($0.pid) }
    }

    func kill(pid: pid_t, force: Bool) async throws {
        try await shell("kill -\(force ? "KILL" : "TERM") \(pid)")
    }

    // MARK: - Where the session is

    /// The interactive shell on this connection and the directory it is in,
    /// or nil when no shell can be identified — a session Kero is not in front
    /// of, or a remote without `/proc`.
    func remoteWorkingDirectory(
        terminalTag: String? = nil
    ) async throws -> (pid: pid_t, directory: String)? {
        let command = RemoteCommands.shellDiscoveryCommand(terminalTag: terminalTag)
        let output = try await shell(command + "; :")
        return RemoteCommands.parseShellDiscovery(text(output))
    }
}

/// Runs commands over an ssh control socket somebody else opened.
///
/// `BatchMode=yes` keeps a stalled connection from stopping on a prompt no one
/// can answer; the multiplexed channel needs no authentication of its own.
nonisolated struct ProcessRemoteCommandRunner: RemoteCommandRunner {
    let controlSocket: String
    let destination: String
    var sshPath = "/usr/bin/ssh"

    func run(
        _ argv: [String], stdin: Data?, timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        let arguments =
            ["-S", controlSocket, "-o", "BatchMode=yes", destination, "--"] + argv
        return try await Task.detached(priority: .utility) {
            try Self.launch(
                sshPath: sshPath, arguments: arguments, stdin: stdin, timeout: timeout
            )
        }.value
    }

    /// Both pipes are drained on their own threads: a command that fills one
    /// while we wait on the other would otherwise never finish.
    private static func launch(
        sshPath: String, arguments: [String], stdin: Data?, timeout: TimeInterval
    ) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errorPipe
        let inputPipe = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inputPipe

        try process.run()

        if let stdin {
            let handle = inputPipe.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async {
                try? handle.write(contentsOf: stdin)
                try? handle.close()
            }
        }

        let collected = Collected()
        let group = DispatchGroup()
        for (pipe, isStdout) in [(outPipe, true), (errorPipe, false)] {
            DispatchQueue.global(qos: .utility).async(group: group) {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.store(data, isStdout: isStdout)
            }
        }

        let expired = Flag()
        let watchdog = DispatchWorkItem {
            expired.raise()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout, execute: watchdog
        )

        process.waitUntilExit()
        watchdog.cancel()
        group.wait()

        if expired.isRaised { throw WorkspaceError.timedOut }
        return (process.terminationStatus, collected.stdout, collected.stderr)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var error = Data()

        func store(_ data: Data, isStdout: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isStdout { out = data } else { error = data }
        }

        var stdout: Data { lock.withLock { out } }
        var stderr: Data { lock.withLock { error } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func raise() { lock.withLock { value = true } }
        var isRaised: Bool { lock.withLock { value } }
    }
}

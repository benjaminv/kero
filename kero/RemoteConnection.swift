//
//  RemoteConnection.swift
//  kero
//

import Combine
import Darwin
import Foundation

/// Where a session's right pane looks for files, processes and git state.
///
/// A session is `.local` until Kero's own `ssh` helper reports that the user
/// typed an interactive `ssh` in that terminal. Nested or unmanaged `ssh`
/// invocations never produce a `.remote` location, so the pane can say the
/// remote tools are unavailable rather than showing local paths under a
/// remote heading.
enum WorkspaceLocation {
    case local
    case remote(RemoteConnection)

    var remoteConnection: RemoteConnection? {
        guard case .remote(let connection) = self else { return nil }
        return connection
    }
}

enum RemoteConnectionError: Error, LocalizedError {
    case notConnected
    case commandFailed(status: Int32, message: String)
    case unexpectedOutput(String)
    case socketPathTooLong(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "The remote connection is not available.")
        case .commandFailed(let status, let message):
            return message.isEmpty
                ? String(localized: "The remote command failed with status \(status).")
                : message
        case .unexpectedOutput(let output):
            return String(localized: "Unexpected ssh output: \(output)")
        case .socketPathTooLong(let path):
            return String(localized: "The control socket path is too long: \(path)")
        }
    }
}

/// One multiplexed ssh session, shared with the interactive `ssh` the user
/// typed. Kero never authenticates: the control socket is created by that
/// process, and every command here rides the existing channel.
@MainActor
final class RemoteConnection: ObservableObject, Identifiable, RemoteCommandRunner {
    enum State: Equatable {
        case connecting
        case connected
        case disconnected
    }

    nonisolated let id = UUID()
    nonisolated let user: String
    nonisolated let host: String
    nonisolated let port: Int
    /// Created and owned by the user's ssh process; Kero only names it.
    nonisolated let controlSocket: URL
    /// The interactive ssh itself. The helper `exec`s ssh over its own
    /// process, so the pid it reports stays valid for the session's life.
    nonisolated let sshPID: pid_t

    @Published private(set) var state: State = .connecting
    /// One backend per connection: the models store whatever they are handed
    /// each sync, so a fresh instance per access would be wasteful churn.
    lazy var workspaceBackend: SSHWorkspaceBackend = SSHWorkspaceBackend(runner: self)
    /// The same channel with a short deadline, used only for the liveness
    /// probe. Panel work can afford to wait; a probe that waits is a drop
    /// this session has not noticed yet.
    lazy var livenessBackend: SSHWorkspaceBackend = SSHWorkspaceBackend(
        runner: self, timeout: 3
    )
    /// Remote working directory, filled in by the cwd probe.
    @Published var workingDirectory: String?
    /// The remote login shell's process id, found by the same probe. The Info
    /// panel needs it to describe the shell on the other machine rather than
    /// the local ssh client.
    @Published var shellProcessID: pid_t?

    /// Unix socket paths are capped at 104 bytes by `sockaddr_un`, which rules
    /// out Application Support. Same `/tmp` convention as the automation
    /// socket, one directory per app process at 0700.
    private static let maximumSocketPathBytes = 104

    nonisolated var destination: String {
        user.isEmpty ? host : "\(user)@\(host)"
    }

    nonisolated var displayName: String {
        destination
    }

    init(user: String, host: String, port: Int, controlSocket: URL, sshPID: pid_t) {
        self.user = user
        self.host = host
        self.port = port
        self.controlSocket = controlSocket
        self.sshPID = sshPID
        NSLog(
            "kero: remote connection %@ state connecting (socket %@, ssh pid %d)",
            destination, controlSocket.path, sshPID
        )
    }

    // MARK: - Control socket allocation

    /// Directory holding this app process's control sockets, created 0700.
    static func controlSocketDirectory() throws -> URL {
        let url = URL(
            fileURLWithPath:
                "/tmp/kero-\(getuid())-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    /// A fresh control socket path, short enough for `sockaddr_un`.
    static func allocateControlSocket() throws -> URL {
        let directory = try controlSocketDirectory()
        let nonce = UUID().uuidString.prefix(8).lowercased()
        let url = directory.appendingPathComponent("ssh-\(nonce).sock")
        guard url.path.utf8.count <= maximumSocketPathBytes else {
            throw RemoteConnectionError.socketPathTooLong(url.path)
        }
        return url
    }

    // MARK: - State

    func markConnected() {
        guard state != .connected else { return }
        state = .connected
        NSLog("kero: remote connection %@ state connected", destination)
    }

    func markDisconnected(reason: String) {
        guard state != .disconnected else { return }
        state = .disconnected
        NSLog(
            "kero: remote connection %@ state disconnected (%@)",
            destination, reason
        )
    }

    /// True while the interactive ssh process still exists. `kill(pid, 0)`
    /// reports `EPERM` for a live process we do not own, which still means
    /// alive; only `ESRCH` means gone.
    nonisolated var isSSHProcessAlive: Bool {
        guard sshPID > 1 else { return false }
        if Darwin.kill(sshPID, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// The master removes its socket when the session ends, so a missing
    /// file is a disconnect Kero can see without running ssh at all.
    nonisolated var controlSocketExists: Bool {
        FileManager.default.fileExists(atPath: controlSocket.path)
    }

    // MARK: - Multiplex commands

    /// `ssh -S <socket> -O check <destination>`: does the master still answer?
    nonisolated func check() async -> Bool {
        let result = await Self.runSSH(
            arguments: controlArguments + ["-O", "check", destination],
            stdin: nil,
            timeout: 5
        )
        return result.status == 0
    }

    /// Allocates a local listener on 127.0.0.1 forwarding to `remotePort` on
    /// the remote's own loopback, and returns the local port. Never binds
    /// 0.0.0.0. The forward dies with the connection because the helper sets
    /// `ControlPersist=no`.
    ///
    /// OpenSSH 10.2 rejects port 0 in a local forward specification ("Bad
    /// local forwarding specification"), so Kero picks the free port itself
    /// and names it explicitly. A successful `-O forward` prints nothing.
    func forward(remotePort: Int) async throws -> Int {
        guard state == .connected else { throw RemoteConnectionError.notConnected }
        let localPort = try Self.freeLocalPort()
        let specification = "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)"
        let result = await Self.runSSH(
            arguments: controlArguments + ["-O", "forward", "-L", specification, destination],
            stdin: nil,
            timeout: 10
        )
        guard result.status == 0 else {
            throw RemoteConnectionError.commandFailed(
                status: result.status,
                message: Self.text(result.stderr)
            )
        }
        NSLog(
            "kero: remote connection %@ forwarded remote port %d to 127.0.0.1:%d",
            destination, remotePort, localPort
        )
        return localPort
    }

    /// Removes a forward created by ``forward(remotePort:)``. The
    /// specification must match the one that created it.
    func cancelForward(localPort: Int, remotePort: Int) async {
        let specification = "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)"
        _ = await Self.runSSH(
            arguments: controlArguments + ["-O", "cancel", "-L", specification, destination],
            stdin: nil,
            timeout: 5
        )
    }

    /// Asks the kernel for an unused loopback port by binding it and letting
    /// go. A race with another process is possible but the window is small and
    /// ssh reports the collision rather than binding something unexpected.
    nonisolated static func freeLocalPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RemoteConnectionError.unexpectedOutput(
                "socket: \(String(cString: strerror(errno)))"
            )
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw RemoteConnectionError.unexpectedOutput(
                "bind: \(String(cString: strerror(errno)))"
            )
        }
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            throw RemoteConnectionError.unexpectedOutput(
                "getsockname: \(String(cString: strerror(errno)))"
            )
        }
        return Int(UInt16(bigEndian: resolved.sin_port))
    }

    /// Runs one command on the remote over the shared channel.
    ///
    /// `argv` is handed to ssh as the remote command words, which ssh joins
    /// with spaces for the remote login shell to interpret. Callers that have
    /// already built a shell command pass it as a single element; callers with
    /// real argv should quote through ``remoteScript(_:cwd:)`` first.
    ///
    /// The liveness check is not decoration: with a dead control socket `ssh
    /// -S` silently falls back to opening a brand new connection, which would
    /// authenticate behind the user's back. Checking first keeps this method
    /// strictly a passenger on the session the user opened.
    nonisolated func run(
        _ argv: [String],
        stdin: Data? = nil,
        timeout: TimeInterval = 20
    ) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        // Deliberately not gated on `.connected`: the liveness probe has to
        // keep running while the connection is disconnected, or nothing could
        // ever notice it coming back.
        //
        // `-O check` only asks the LOCAL multiplexing master, which answers
        // happily with the network down, so it proves the socket is ours and
        // nothing more. It is kept as the cheap fast-fail that stops ssh
        // quietly opening a brand new connection once the master is gone.
        guard controlSocketExists, await check() else {
            await MainActor.run {
                markDisconnected(reason: "control socket is gone")
            }
            throw RemoteConnectionError.notConnected
        }
        return await Self.runSSH(
            arguments: controlArguments + ["-o", "BatchMode=yes", destination, "--"] + argv,
            stdin: stdin,
            timeout: timeout
        )
    }

    /// Runs a command in a specific remote directory. Every element is quoted
    /// here, so this is the entry point for real argv rather than a shell
    /// command that has already been assembled.
    @discardableResult
    func run(
        _ argv: [String],
        cwd: String,
        stdin: Data? = nil,
        timeout: TimeInterval = 20
    ) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        try await run(
            [Self.remoteScript(argv, cwd: cwd)], stdin: stdin, timeout: timeout
        )
    }

    /// Options naming the shared channel. `-S` is ssh's own "use this control
    /// socket" switch and overrides any ControlPath from a config file.
    nonisolated private var controlArguments: [String] {
        ["-S", controlSocket.path, "-p", String(port)]
    }

    // MARK: - Command construction

    /// Wraps argv in a POSIX `sh` command line. ssh joins the remote command
    /// with spaces and hands it to the remote login shell, so every element is
    /// quoted here rather than relying on ssh to preserve argument boundaries.
    static func remoteScript(_ argv: [String], cwd: String?) -> String {
        let command = argv.map(shellQuoted).joined(separator: " ")
        guard let cwd, !cwd.isEmpty else { return "exec \(command)" }
        return "cd \(shellQuoted(cwd)) && exec \(command)"
    }

    /// POSIX single-quoting: everything is literal inside `'...'`, and a
    /// literal quote is written by closing, escaping and reopening.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Process

    /// Runs `/usr/bin/ssh` off the main actor. Kero always uses the system
    /// client here, never the bundle's helper symlink, which would recurse.
    nonisolated static func runSSH(
        arguments: [String],
        stdin: Data?,
        timeout: TimeInterval
    ) async -> (status: Int32, stdout: Data, stderr: Data) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: runSSHBlocking(
                        arguments: arguments, stdin: stdin, timeout: timeout
                    )
                )
            }
        }
    }

    private nonisolated static func runSSHBlocking(
        arguments: [String],
        stdin: Data?,
        timeout: TimeInterval
    ) -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Parsed output ("Allocated port N") must not follow the user's locale.
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe? = stdin == nil ? nil : Pipe()
        process.standardInput = stdinPipe ?? FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return (-1, Data(), Data(error.localizedDescription.utf8))
        }

        if let stdinPipe, let stdin {
            DispatchQueue.global(qos: .utility).async {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? stdinPipe.fileHandleForWriting.close()
            }
        }

        // Read with the same deadline that bounds the process.
        //
        // Not `readDataToEndOfFile` on a helper thread: ssh's multiplexing
        // client hands its stdout and stderr to the MASTER process over the
        // control socket, so the master holds the write ends. Killing this
        // client does not close them, and a read waiting for end-of-file
        // waits for the master to finish the session — which, when the
        // network has gone, means waiting out the whole outage. That is what
        // made a dropped connection take tens of seconds to notice instead of
        // the deadline set here.
        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor
        for descriptor in [outFD, errFD] {
            let flags = fcntl(descriptor, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        }

        var outData = Data()
        var errData = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        var openDescriptors: Set<Int32> = [outFD, errFD]
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false

        while true {
            if Date() >= deadline {
                timedOut = true
                break
            }
            var fds = openDescriptors.sorted().map { descriptor in
                pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            }
            if fds.isEmpty {
                // Both ends closed: the command's output is complete. Give the
                // process a moment to report its status.
                if exited.wait(timeout: .now() + .milliseconds(200)) == .success { break }
                if Date() >= deadline { timedOut = true }
                if timedOut { break }
                continue
            }
            let ready = poll(&fds, nfds_t(fds.count), 100)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            for entry in fds where entry.revents != 0 {
                let count = Darwin.read(entry.fd, &buffer, buffer.count)
                if count > 0 {
                    if entry.fd == outFD {
                        outData.append(buffer, count: count)
                    } else {
                        errData.append(buffer, count: count)
                    }
                } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                    openDescriptors.remove(entry.fd)
                }
            }
        }

        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + .seconds(1)) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + .seconds(1))
            }
            errData.append(Data("\nssh did not respond in time.\n".utf8))
            return (-2, outData, errData)
        }
        return (process.terminationStatus, outData, errData)
    }
}

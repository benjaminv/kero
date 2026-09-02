//
//  KeroSSHPassthrough.swift
//  kero
//

import Darwin
import Foundation

/// The `ssh` the user actually types inside a Kero terminal.
///
/// Kero prepends its own `Contents/MacOS` to every terminal's `PATH`, and a
/// symlink there named `ssh` points back at the app binary. When the binary is
/// invoked under that name it either tells Kero a session is going remote and
/// hands control to the real ssh with a shared control socket, or — far more
/// often — gets out of the way entirely.
///
/// Every uncertain case passes through untouched. A wrong pass-through costs
/// nothing; a wrong interception would alter a command the user, a script, or
/// an agent depends on.
enum KeroSSHPassthrough {
    /// Options OpenSSH accepts with no value.
    private static let flagOptions = Set("46AaCfGgKkMNnqsTtVvXxYy")
    /// Options OpenSSH accepts with a value, attached or as the next argument.
    private static let valueOptions = Set("BbcDEeFIiJLlmOoPpRSWw")
    /// Options that mean this invocation is not an interactive session Kero
    /// can follow: config dumps, version and query output, control-socket
    /// commands, forwarding-only and no-shell modes, and subsystems.
    private static let disqualifyingFlags = Set("GQVONWTs")
    /// Options that take over the control socket itself. `-S` and `-M` are
    /// handled by ssh's own argument parser and would override anything Kero
    /// passes, so a session using them is left alone.
    private static let disqualifyingValueOptions = Set("SM")

    /// True when the binary was invoked through the `ssh` symlink.
    static var isInvokedAsSSH: Bool {
        guard let first = CommandLine.arguments.first else { return false }
        return (first as NSString).lastPathComponent == "ssh"
    }

    static func main() -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let realSSH = locateSystemSSH()

        guard let plan = interceptionPlan(arguments: arguments, realSSH: realSSH) else {
            execute(realSSH, [realSSH] + arguments)
        }

        // A failed hand-off must never cost the user their connection: fall
        // back to an ordinary ssh with none of Kero's options.
        guard let socket = announceConnecting(plan) else {
            execute(realSSH, [realSSH] + arguments)
        }

        setenv("LC_KERO_TERMINAL", plan.terminalID, 1)
        let keroOptions = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(socket)",
            "-o", "ControlPersist=no",
            "-o", "SendEnv=LC_KERO_TERMINAL",
        ]
        // Kero's options go first because OpenSSH keeps the first value it
        // obtains for a parameter. The decision to intercept already
        // established that the user set none of these themselves.
        execute(realSSH, [realSSH] + keroOptions + arguments)
    }

    // MARK: - Locating the real client

    /// First `ssh` on `PATH` that is not this bundle's own symlink. The
    /// candidate must still resolve to something named `ssh`, which rules out
    /// a second Kero installation whose symlink resolves to `kero`.
    static func locateSystemSSH() -> String {
        let ownDirectory = (Bundle.main.executableURL?.deletingLastPathComponent().path)
            .flatMap(resolved)
            ?? resolved((CommandLine.arguments.first ?? "") as NSString)
                .flatMap { ($0 as NSString).deletingLastPathComponent }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(directory)/ssh"
            guard access(candidate, X_OK) == 0, let target = resolved(candidate) else { continue }
            guard (target as NSString).lastPathComponent == "ssh" else { continue }
            if let ownDirectory,
               resolved((candidate as NSString).deletingLastPathComponent) == ownDirectory {
                continue
            }
            return candidate
        }
        return "/usr/bin/ssh"
    }

    private static func resolved(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func resolved(_ path: NSString) -> String? {
        resolved(path as String)
    }

    // MARK: - Interception decision

    struct Plan {
        let user: String
        let host: String
        let port: Int
        let socketPath: String
        let token: String
        let terminalID: String
    }

    /// Everything that must hold before Kero touches an ssh invocation.
    static func interceptionPlan(arguments: [String], realSSH: String) -> Plan? {
        let environment = ProcessInfo.processInfo.environment
        guard let socketPath = environment["KERO_AUTOMATION_SOCKET"], !socketPath.isEmpty,
              let token = environment["KERO_AUTOMATION_TOKEN"], !token.isEmpty,
              let terminalID = environment["KERO_TERMINAL_ID"], !terminalID.isEmpty
        else { return nil }

        // Only a session a person is sitting in front of. A pipeline, an agent
        // running `ssh host cmd`, rsync and scp all fail this.
        guard isatty(0) == 1, isatty(1) == 1 else { return nil }

        guard case .interactiveSession = classify(arguments) else { return nil }

        guard let configuration = resolvedConfiguration(arguments: arguments, realSSH: realSSH),
              let host = configuration["hostname"], !host.isEmpty
        else { return nil }

        // A user who already multiplexes this host keeps their own socket.
        // Kero would otherwise silently override it, because its prepended
        // options win over both the command line and ~/.ssh/config.
        let controlMaster = configuration["controlmaster"] ?? "false"
        let controlPath = configuration["controlpath"] ?? "none"
        guard controlMaster == "false" || controlMaster == "no" else { return nil }
        guard controlPath == "none" else { return nil }

        return Plan(
            user: configuration["user"] ?? "",
            host: host,
            port: Int(configuration["port"] ?? "22") ?? 22,
            socketPath: socketPath,
            token: token,
            terminalID: terminalID
        )
    }

    enum Classification: Equatable {
        /// A destination and nothing after it.
        case interactiveSession
        /// Anything Kero declines to reason about.
        case notFollowable
    }

    /// Walks argv the way OpenSSH's own `getopt` string does, looking for a
    /// destination with no command after it.
    ///
    /// OpenSSH also accepts options *after* the destination (`ssh host -p 22`).
    /// Kero deliberately does not: treating any trailing argument as a remote
    /// command keeps the parser small and errs towards passing through.
    static func classify(_ arguments: [String]) -> Classification {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]

            if argument == "-" || argument == "--" { return .notFollowable }

            guard argument.hasPrefix("-") else {
                // The destination. Anything after it is a remote command.
                return index == arguments.index(before: arguments.endIndex)
                    ? .interactiveSession
                    : .notFollowable
            }

            let characters = Array(argument.dropFirst())
            var cursor = 0
            while cursor < characters.count {
                let flag = characters[cursor]
                if disqualifyingFlags.contains(flag) { return .notFollowable }
                // Checked before the flag branch: `-M` takes no value and so
                // also appears in the flag set, but it still means the user is
                // running their own multiplexing master.
                if disqualifyingValueOptions.contains(flag) { return .notFollowable }
                if flagOptions.contains(flag) {
                    cursor += 1
                    continue
                }
                if valueOptions.contains(flag) {
                    let attached = String(characters[(cursor + 1)...])
                    if attached.isEmpty {
                        // The value is the next argument, so skip it.
                        index = arguments.index(after: index)
                        guard index < arguments.endIndex else { return .notFollowable }
                    }
                    cursor = characters.count
                    continue
                }
                // An option this parser does not know. Never guess.
                return .notFollowable
            }
            index = arguments.index(after: index)
        }
        // Options only, no destination.
        return .notFollowable
    }

    /// `ssh -G` resolves the effective configuration without connecting.
    /// Returns the lowercased keyword to first-value map, or nil if ssh
    /// refused the arguments.
    static func resolvedConfiguration(
        arguments: [String],
        realSSH: String
    ) -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: realSSH)
        process.arguments = ["-G"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        var configuration: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let key = fields[0].lowercased()
            // ssh -G repeats multi-valued keywords; keep the first, which is
            // the value it would actually use.
            if configuration[key] == nil {
                configuration[key] = String(fields[1])
            }
        }
        return configuration
    }

    // MARK: - Telling Kero

    /// Announces the pending connection and returns the control socket path
    /// Kero allocated for it, or nil if Kero did not answer.
    private static func announceConnecting(_ plan: Plan) -> String? {
        let request = KeroAutomationRequest(
            version: 1,
            id: "kero:ssh:\(getpid())",
            method: "remote.connecting",
            token: plan.token,
            terminalID: plan.terminalID,
            params: [
                "user": .string(plan.user),
                "host": .string(plan.host),
                "port": .number(Double(plan.port)),
                // This process becomes ssh itself at `execv`, so the pid Kero
                // records stays valid for the life of the connection.
                "pid": .number(Double(getpid())),
            ]
        )
        guard let response = try? KeroAutomationSocketServer.exchange(
            path: plan.socketPath, request: request, timeout: 1
        ), response.ok,
            let socket = response.result?.objectValue?["socket"]?.stringValue,
            !socket.isEmpty
        else { return nil }
        return socket
    }

    // MARK: - Handing over

    private static func execute(_ path: String, _ arguments: [String]) -> Never {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        execv(path, &argv)
        fputs("kero: could not run \(path): \(String(cString: strerror(errno)))\n", stderr)
        exit(127)
    }
}

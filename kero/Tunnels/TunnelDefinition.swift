//
//  TunnelDefinition.swift
//  kero
//

import Foundation

/// Which way a saved forward runs.
nonisolated enum TunnelDirection: String, CaseIterable {
    /// `ssh -L`: this Mac listens, and connections reach a port as seen from
    /// the remote machine. What a remote desktop client or a browser needs.
    case local
    /// `ssh -R`: the remote machine listens, and connections reach a port on
    /// this Mac, such as its own `sshd` so a shell on the remote side can
    /// come back here.
    case remote
}

/// One saved port forward that Kero keeps open in the background, with no
/// terminal pane involved.
///
/// A local forward: `127.0.0.1:<localPort>` on this Mac reaches
/// `<remoteHost>:<remotePort>` as seen from `host`. A remote forward is the
/// mirror image: `127.0.0.1:<remotePort>` on `host` reaches
/// `<localHost>:<localPort>` as seen from this Mac. Either way the listening
/// side is loopback and the other pair names the target.
///
/// `host` is handed to `/usr/bin/ssh` exactly as typed, so an alias from
/// `~/.ssh/config` brings its `User`, `Port`, `IdentityFile` and `ProxyJump`
/// with it, the same as in a terminal.
nonisolated struct TunnelDefinition: Identifiable, Equatable {
    /// Assigned on load and never written: the file stays hand-editable, and
    /// identity only has to hold for one run of the app.
    var id = UUID()
    var name: String
    var host: String
    var direction: TunnelDirection = .local
    /// Where a remote forward lands on this side. Ignored by a local forward,
    /// which always listens on loopback.
    var localHost: String = "127.0.0.1"
    var localPort: Int
    /// What a local forward reaches on the remote side. Ignored by a remote
    /// forward, which always listens on the remote machine's loopback.
    var remoteHost: String = "127.0.0.1"
    var remotePort: Int
    var isEnabled: Bool = false

    /// Ports a user process can listen on without root. Applied to the port
    /// this Mac listens on; the remote side is ssh's to refuse, since the
    /// remote user may well be root.
    static let localPortRange = 1024...65535
    /// Any TCP port: the target of either direction, and a remote listener.
    static let anyPortRange = 1...65535

    /// The port this side's ssh listens on, or asks the remote sshd to.
    var listenPort: Int {
        direction == .local ? localPort : remotePort
    }

    /// The `-L` or `-R` argument. The listener is always bound to loopback: a
    /// background forward must never be reachable from the local network, on
    /// either machine. (A remote sshd with `GatewayPorts yes` overrides the
    /// address we ask for; that is the remote administrator's call.)
    var forwardSpecification: String {
        switch direction {
        case .local: "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)"
        case .remote: "127.0.0.1:\(remotePort):\(localHost):\(localPort)"
        }
    }

    /// Where the forward can be connected to, on whichever machine listens.
    var listenAddress: String { "127.0.0.1:\(listenPort)" }

    /// Where the forward listens, as the settings table shows it.
    var listenDescription: String {
        switch direction {
        case .local: String(localized: "This Mac, port \(String(localPort))")
        case .remote: String(localized: "\(host), port \(String(remotePort))")
        }
    }

    /// What the forward reaches, as the settings table and log lines show it.
    var targetDescription: String {
        switch direction {
        case .local: "\(host) → \(remoteHost):\(remotePort)"
        case .remote: String(localized: "This Mac → \(localHost):\(localPort)")
        }
    }

    /// Whether `other` would listen on the same port on the same machine, so
    /// only one of the two could ever be open.
    func listensAlongside(_ other: TunnelDefinition) -> Bool {
        guard direction == other.direction, listenPort == other.listenPort else { return false }
        return direction == .local || host == other.host
    }

    /// Why this definition cannot be started, or nil when it can.
    var validationProblem: String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Enter an ssh host or an alias from ~/.ssh/config.")
        }
        // A leading dash would reach ssh as an option rather than a host.
        if host.hasPrefix("-") || host.contains(where: \.isWhitespace) {
            return String(localized: "The host can't start with “-” or contain spaces.")
        }
        switch direction {
        case .local:
            if remoteHost.isEmpty || remoteHost.contains(where: \.isWhitespace) {
                return String(localized: "Enter the remote host the forward should reach, such as 127.0.0.1.")
            }
            if !Self.localPortRange.contains(localPort) {
                return String(localized: "The local port must be between 1024 and 65535.")
            }
            if !Self.anyPortRange.contains(remotePort) {
                return String(localized: "The remote port must be between 1 and 65535.")
            }
        case .remote:
            if localHost.isEmpty || localHost.contains(where: \.isWhitespace) {
                return String(localized: "Enter the host the forward should reach from this Mac, such as 127.0.0.1.")
            }
            if !Self.anyPortRange.contains(remotePort) {
                return String(localized: "The remote port must be between 1 and 65535.")
            }
            if !Self.anyPortRange.contains(localPort) {
                return String(localized: "The local port must be between 1 and 65535.")
            }
        }
        return nil
    }
}

/// Reads and writes `tunnels.toml`, beside `config.toml`.
///
/// A file of its own rather than a section of `config.toml`: `AppSettings`
/// rewrites that file from its own keys on every change, which would drop
/// anything it doesn't know about.
///
/// ```toml
/// [[tunnel]]
/// name = "A1 desktop (RDP)"
/// host = "oracle"
/// direction = "local"
/// local-port = 13389
/// remote-host = "127.0.0.1"
/// remote-port = 3389
/// enabled = true
///
/// [[tunnel]]
/// name = "A1 back to this Mac (ssh)"
/// host = "oracle"
/// direction = "remote"
/// local-host = "127.0.0.1"
/// local-port = 22
/// remote-port = 2222
/// enabled = true
/// ```
///
/// `direction` is optional and defaults to `local`, so files written before
/// remote forwards existed still read the same.
enum TunnelStore {
    static var fileURL: URL {
        AppSettings.configURL.deletingLastPathComponent()
            .appendingPathComponent("tunnels.toml")
    }

    static func load() -> [TunnelDefinition] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func save(_ tunnels: [TunnelDefinition]) {
        let url = fileURL
        do {
            if tunnels.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try serialize(tunnels).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("kero: failed to write \(url.path): \(error)")
        }
    }

    /// Only `[[tunnel]]` tables are read; anything else is ignored rather than
    /// rejected, so a hand edit can't cost the user every saved forward.
    /// A table missing a host or either port is skipped, and an unknown
    /// direction reads as local rather than dropping the table.
    static func parse(_ text: String) -> [TunnelDefinition] {
        var tables: [[String: TOML.Value]] = []
        var current: [String: TOML.Value]?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                if let current { tables.append(current) }
                current = line == "[[tunnel]]" ? [:] : nil
                continue
            }
            guard current != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let value = TOML.parseValue(raw) { current?[key] = value }
        }
        if let current { tables.append(current) }

        return tables.compactMap { table in
            guard
                let host = table["host"]?.string,
                let local = table["local-port"]?.double,
                let remote = table["remote-port"]?.double
            else { return nil }
            return TunnelDefinition(
                name: table["name"]?.string ?? host,
                host: host,
                direction: table["direction"]?.string.flatMap(TunnelDirection.init(rawValue:)) ?? .local,
                localHost: table["local-host"]?.string ?? "127.0.0.1",
                localPort: Int(local),
                remoteHost: table["remote-host"]?.string ?? "127.0.0.1",
                remotePort: Int(remote),
                isEnabled: table["enabled"]?.bool ?? false
            )
        }
    }

    /// Writes only the host that matters for the direction, so a hand-read
    /// file shows one target per forward rather than an ignored default.
    static func serialize(_ tunnels: [TunnelDefinition]) -> String {
        tunnels.map { tunnel in
            var lines = [
                "[[tunnel]]",
                "name = \(TOML.quote(tunnel.name))",
                "host = \(TOML.quote(tunnel.host))",
                "direction = \(TOML.quote(tunnel.direction.rawValue))",
            ]
            switch tunnel.direction {
            case .local:
                lines += [
                    "local-port = \(tunnel.localPort)",
                    "remote-host = \(TOML.quote(tunnel.remoteHost))",
                    "remote-port = \(tunnel.remotePort)",
                ]
            case .remote:
                lines += [
                    "local-host = \(TOML.quote(tunnel.localHost))",
                    "local-port = \(tunnel.localPort)",
                    "remote-port = \(tunnel.remotePort)",
                ]
            }
            lines.append("enabled = \(tunnel.isEnabled)")
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n") + "\n"
    }
}

#if DEBUG
extension TunnelStore {
    /// Self-check standing in for a unit test target, like
    /// `RemoteCommands.runSelfCheck()`.
    static func runSelfCheck() {
        let rdp = TunnelDefinition(
            name: "A1 \"desktop\"", host: "oracle", localPort: 13389,
            remotePort: 3389, isEnabled: true)
        let back = TunnelDefinition(
            name: "A1 back", host: "oracle", direction: .remote, localPort: 22,
            remotePort: 2222, isEnabled: true)
        let parsed = parse(serialize([rdp, back]))
        assert(parsed.count == 2)
        assert(parsed[0].name == rdp.name)
        assert(parsed[0].host == "oracle" && parsed[0].direction == .local)
        assert(parsed[0].localPort == 13389 && parsed[0].remotePort == 3389)
        assert(parsed[0].remoteHost == "127.0.0.1" && parsed[0].isEnabled)
        assert(parsed[0].forwardSpecification == "127.0.0.1:13389:127.0.0.1:3389")
        assert(parsed[0].listenPort == 13389)
        assert(parsed[1].direction == .remote && parsed[1].localHost == "127.0.0.1")
        assert(parsed[1].localPort == 22 && parsed[1].remotePort == 2222)
        assert(parsed[1].forwardSpecification == "127.0.0.1:2222:127.0.0.1:22")
        assert(parsed[1].listenPort == 2222 && parsed[1].listenAddress == "127.0.0.1:2222")
        assert(parsed[1].validationProblem == nil)

        let mixed = """
            # comment
            [other]
            host = "ignored"
            [[tunnel]]
            host = "a1"
            local-port = 9292
            remote-port = 9292
            [[tunnel]]
            name = "no host"
            local-port = 1
            [[tunnel]]
            host = "a1"
            direction = "sideways"
            local-port = 8080
            remote-port = 8080
            """
        let fromMixed = parse(mixed)
        assert(fromMixed.count == 2 && fromMixed[0].name == "a1" && !fromMixed[0].isEnabled)
        assert(fromMixed[0].direction == .local && fromMixed[1].direction == .local)

        // Two forwards clash only when the same machine would listen twice.
        var otherHostBack = back
        otherHostBack.host = "a1"
        assert(back.listensAlongside(back) && !back.listensAlongside(otherHostBack))
        var rdpOn2222 = rdp
        rdpOn2222.localPort = 2222
        assert(!rdpOn2222.listensAlongside(back))
        assert(rdp.listensAlongside(rdp) && !rdp.listensAlongside(rdpOn2222))

        var bad = rdp
        bad.host = "-oProxyCommand=x"
        assert(bad.validationProblem != nil)
        bad = rdp
        bad.localPort = 80
        assert(bad.validationProblem != nil)
        assert(rdp.validationProblem == nil)
        // A remote forward may reach a privileged port on this Mac, since
        // nothing here has to bind it.
        bad = back
        bad.localPort = 80
        assert(bad.validationProblem == nil)
        bad.localHost = ""
        assert(bad.validationProblem != nil)
    }
}
#endif

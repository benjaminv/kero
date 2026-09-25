//
//  TunnelDefinition.swift
//  kero
//

import Foundation

/// One saved port forward that Kero keeps open in the background, with no
/// terminal pane involved: `127.0.0.1:<localPort>` on this Mac reaches
/// `<remoteHost>:<remotePort>` as seen from `host`.
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
    var localPort: Int
    var remoteHost: String = "127.0.0.1"
    var remotePort: Int
    var isEnabled: Bool = false

    /// Ports a user process can listen on without root.
    static let localPortRange = 1024...65535
    static let remotePortRange = 1...65535

    /// The `-L` argument. Always bound to loopback: a background forward must
    /// never be reachable from the local network.
    var forwardSpecification: String {
        "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)"
    }

    var localAddress: String { "127.0.0.1:\(localPort)" }

    /// What the forward reaches, as the settings table and log lines show it.
    var remoteDescription: String {
        "\(host) → \(remoteHost):\(remotePort)"
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
        if remoteHost.isEmpty || remoteHost.contains(where: \.isWhitespace) {
            return String(localized: "Enter the remote host the forward should reach, such as 127.0.0.1.")
        }
        if !Self.localPortRange.contains(localPort) {
            return String(localized: "The local port must be between 1024 and 65535.")
        }
        if !Self.remotePortRange.contains(remotePort) {
            return String(localized: "The remote port must be between 1 and 65535.")
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
/// local-port = 13389
/// remote-host = "127.0.0.1"
/// remote-port = 3389
/// enabled = true
/// ```
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
    /// A table missing a host or either port is skipped.
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
                localPort: Int(local),
                remoteHost: table["remote-host"]?.string ?? "127.0.0.1",
                remotePort: Int(remote),
                isEnabled: table["enabled"]?.bool ?? false
            )
        }
    }

    static func serialize(_ tunnels: [TunnelDefinition]) -> String {
        tunnels.map { tunnel in
            [
                "[[tunnel]]",
                "name = \(TOML.quote(tunnel.name))",
                "host = \(TOML.quote(tunnel.host))",
                "local-port = \(tunnel.localPort)",
                "remote-host = \(TOML.quote(tunnel.remoteHost))",
                "remote-port = \(tunnel.remotePort)",
                "enabled = \(tunnel.isEnabled)",
            ].joined(separator: "\n")
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
        let parsed = parse(serialize([rdp]))
        assert(parsed.count == 1)
        assert(parsed[0].name == rdp.name)
        assert(parsed[0].host == "oracle")
        assert(parsed[0].localPort == 13389 && parsed[0].remotePort == 3389)
        assert(parsed[0].remoteHost == "127.0.0.1" && parsed[0].isEnabled)
        assert(parsed[0].forwardSpecification == "127.0.0.1:13389:127.0.0.1:3389")

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
            """
        let fromMixed = parse(mixed)
        assert(fromMixed.count == 1 && fromMixed[0].name == "a1" && !fromMixed[0].isEnabled)

        var bad = rdp
        bad.host = "-oProxyCommand=x"
        assert(bad.validationProblem != nil)
        bad = rdp
        bad.localPort = 80
        assert(bad.validationProblem != nil)
        assert(rdp.validationProblem == nil)
    }
}
#endif

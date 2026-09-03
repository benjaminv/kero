//
//  RemoteCommands.swift
//  kero
//

import Darwin
import Foundation

/// Builds the shell command lines Kero runs on a Linux remote over the ssh
/// multiplexing channel, and parses what they print back.
///
/// Pure string work, so every command can be read and tested without a network.
/// The strings themselves were proven against Ubuntu 24.04 with OpenSSH 9.6;
/// the notes in each builder record what the probe found.
nonisolated enum RemoteCommands {

    // MARK: - Quoting

    /// Wraps a path in single quotes for `sh`, which has no escape character
    /// inside them — a literal quote has to close, escape, and reopen.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    // MARK: - Port forwarding

    /// Asks the kernel for a free loopback port by binding to port 0 and
    /// reading back what it assigned.
    ///
    /// The port is released before it is forwarded, so another process can in
    /// principle take it in between. `ssh -O forward` fails loudly when that
    /// happens, which the caller should treat as "try again", not as an error
    /// worth showing.
    static func freeLocalPort() -> UInt16? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }

        let port = UInt16(bigEndian: assigned.sin_port)
        return port == 0 ? nil : port
    }

    /// The `-L` argument. Always bound to loopback: a forwarded remote port
    /// must never be reachable from the local network.
    static func forwardSpec(localPort: UInt16, remotePort: UInt16) -> String {
        "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)"
    }

    /// Note there is no port-0 form: the OpenSSH client rejects
    /// `-L 127.0.0.1:0:...` outright ("Bad local forwarding specification"),
    /// so there is no allocated-port line to read and Kero picks the port
    /// itself with `freeLocalPort()`.
    static func forwardArguments(
        controlSocket: String, destination: String,
        localPort: UInt16, remotePort: UInt16
    ) -> [String] {
        [
            "-S", controlSocket, "-O", "forward",
            "-L", forwardSpec(localPort: localPort, remotePort: remotePort),
            destination,
        ]
    }

    /// Cancelling requires the same specification the forward was created with.
    static func cancelForwardArguments(
        controlSocket: String, destination: String,
        localPort: UInt16, remotePort: UInt16
    ) -> [String] {
        [
            "-S", controlSocket, "-O", "cancel",
            "-L", forwardSpec(localPort: localPort, remotePort: remotePort),
            destination,
        ]
    }

    // MARK: - Finding the interactive shell

    /// Finds the interactive shell on this ssh connection and reports where it
    /// is, as one line: `<pid> <directory>`.
    ///
    /// Every process on one ssh connection is given the same `SSH_CONNECTION`,
    /// so the session identifies itself with no environment variable sent from
    /// the Mac and nothing required of the remote's `AcceptEnv`. The string
    /// must expand on the remote, so `$SSH_CONNECTION` is deliberately left
    /// unexpanded here — never interpolate a local value into it.
    ///
    /// Two filters narrow the candidates, both needed: the multiplexed command
    /// running this very lookup shares the connection and therefore matches,
    /// and so may other non-interactive processes.
    /// - a controlling terminal, which `ps` reports as `?` when absent
    /// - a parent named `sshd`, or `sshd-session` on OpenSSH 9.8 and later
    ///
    /// `terminalTag` additionally requires `LC_KERO_TERMINAL`, which tells two
    /// Kero sessions to the same host over separate connections apart.
    static func shellDiscoveryCommand(terminalTag: String? = nil) -> String {
        var lines = [
            "grep -lz \"SSH_CONNECTION=$SSH_CONNECTION\" /proc/[0-9]*/environ 2>/dev/null",
            "| cut -d/ -f3 | while read -r p; do",
            "t=$(ps -o tty= -p \"$p\" 2>/dev/null | tr -d ' ');",
            "case \"$t\" in ''|'?') continue;; esac;",
            "pp=$(ps -o ppid= -p \"$p\" 2>/dev/null | tr -d ' ');",
            "c=$(ps -o comm= -p \"$pp\" 2>/dev/null);",
            "case \"$c\" in sshd*) ;; *) continue;; esac;",
        ]
        if let terminalTag, !terminalTag.isEmpty {
            lines.append(
                "grep -qz \(quote("LC_KERO_TERMINAL=" + terminalTag)) "
                    + "\"/proc/$p/environ\" 2>/dev/null || continue;"
            )
        }
        lines.append("d=$(readlink \"/proc/$p/cwd\" 2>/dev/null) || continue;")
        lines.append("printf '%s %s\\n' \"$p\" \"$d\"; break; done")
        return lines.joined(separator: " ")
    }

    /// A directory may contain spaces, so only the first space is a separator.
    static func parseShellDiscovery(_ output: String) -> (pid: pid_t, directory: String)? {
        guard let line = output.split(separator: "\n").first.map(String.init) else {
            return nil
        }
        guard let space = line.firstIndex(of: " ") else { return nil }
        guard let pid = pid_t(line[line.startIndex..<space]) else { return nil }
        let directory = String(line[line.index(after: space)...])
        return directory.isEmpty ? nil : (pid, directory)
    }

    // MARK: - Files

    /// `%y` is the entry's own type, `%Y` the type after following symlinks —
    /// both are needed because a symlinked directory has to report as a
    /// directory *and* as a symlink, matching the local backend. NUL
    /// separators keep newlines in filenames from splitting a record.
    ///
    /// `-H` follows the starting point, and only the starting point. Without
    /// it, listing a symlink that points at a directory returns nothing at all
    /// and the file tree shows an empty folder that will not expand, where the
    /// local backend follows it. Entries below are unaffected, so a symlink
    /// inside the directory still reports as a symlink.
    static func listDirectoryCommand(path: String) -> String {
        "find -H \(quote(path)) -maxdepth 1 -mindepth 1 -printf '%y\\t%Y\\t%f\\0'"
    }

    static func parseDirectoryListing(_ output: Data) -> [WorkspaceEntry] {
        output.split(separator: 0).compactMap { record in
            guard let text = String(data: Data(record), encoding: .utf8) else { return nil }
            let fields = text.components(separatedBy: "\t")
            guard fields.count >= 3 else { return nil }
            let name = fields[2...].joined(separator: "\t")
            guard !name.isEmpty else { return nil }
            return WorkspaceEntry(
                name: name,
                isDirectory: fields[1] == "d",
                isSymlink: fields[0] == "l"
            )
        }
    }

    /// Two lines: the path itself, then the path with symlinks followed. The
    /// first says whether it is a symlink, the second describes what it
    /// resolves to, which is what the editor and file tree care about. A
    /// broken symlink fails the second `stat`, leaving one line.
    static func statCommand(path: String) -> String {
        let quoted = quote(path)
        // `--printf`, not `-c`: only the former interprets the tab and newline
        // escapes, and `-c` would return the format string with them intact.
        let format = "'%F\\t%s\\t%Y\\t%a\\n'"
        return "stat --printf \(format) -- \(quoted) 2>/dev/null; "
            + "stat -L --printf \(format) -- \(quoted) 2>/dev/null"
    }

    struct RemoteStat: Equatable {
        let stat: WorkspaceStat
        /// Permission bits as `stat -c %a` prints them, e.g. 0o755.
        let mode: UInt16
    }

    static func parseStat(_ output: String) -> RemoteStat? {
        let rows = output.split(separator: "\n").compactMap(parseStatRow)
        guard let own = rows.first else { return nil }
        // A broken symlink has no resolved row; it is still a symlink.
        let resolved = rows.count > 1 ? rows[1] : own
        return RemoteStat(
            stat: WorkspaceStat(
                isRegular: resolved.kind == "regular file" || resolved.kind == "regular empty file",
                isDirectory: resolved.kind == "directory",
                isSymlink: own.kind == "symbolic link",
                size: resolved.size,
                mtime: Date(timeIntervalSince1970: TimeInterval(resolved.mtime))
            ),
            mode: resolved.mode
        )
    }

    private static func parseStatRow(
        _ line: Substring
    ) -> (kind: String, size: Int, mtime: Int, mode: UInt16)? {
        let fields = line.components(separatedBy: "\t")
        guard fields.count >= 4,
            let size = Int(fields[1]),
            let mtime = Int(fields[2]),
            let mode = UInt16(fields[3], radix: 8)
        else { return nil }
        return (fields[0], size, mtime, mode)
    }

    /// Replaces a file's contents from standard input without ever leaving it
    /// half-written: the temporary file is renamed over the original, which is
    /// atomic within a directory. The mode is copied from the original when
    /// there is one, so an executable script stays executable.
    ///
    /// `chmod --reference` is GNU coreutils, so this is Linux-only, as the
    /// remote workspace is generally.
    static func atomicWriteCommand(path: String) -> String {
        "sh -c 'cat > \"$1.kero-tmp\" && "
            + "{ [ -e \"$1\" ] && chmod --reference=\"$1\" \"$1.kero-tmp\" || :; } && "
            + "mv -f \"$1.kero-tmp\" \"$1\"' _ \(quote(path))"
    }

    /// Counts the text lines of many files in ONE round trip.
    ///
    /// Asking per file costs two round trips each, which on a repository with a
    /// few dozen untracked files is what pushes the Git snapshot past its
    /// deadline. Paths arrive NUL-separated on standard input, so any filename
    /// survives; one line comes back per path, `lines`, `bytesRead` and the
    /// path itself, tab-separated with the path last because it is the only
    /// field that may contain a tab.
    ///
    /// The rules match the local reader exactly: a symlink counts as one line
    /// and no bytes, a file over the cap counts as nothing, a file whose first
    /// 8 KB contain a NUL is binary and charges only that probe to the budget,
    /// and a final line without a newline still counts.
    ///
    /// The script deliberately contains no single quote so it can be wrapped in
    /// one, and runs under `bash` for its NUL-separated `read`.
    static func untrackedLineCountsCommand(
        totalByteBudget: Int, perFileByteCap: Int
    ) -> String {
        let script = """
            budget=\(totalByteBudget); cap=\(perFileByteCap)
            while IFS= read -r -d "" p; do
            if [ "$budget" -le 0 ]; then break; fi
            if [ -L "$p" ]; then printf "1\\t0\\t%s\\n" "$p"; continue; fi
            if [ ! -f "$p" ]; then printf "0\\t0\\t%s\\n" "$p"; continue; fi
            sz=$(stat -c %s -- "$p" 2>/dev/null || echo 0)
            lim=$cap; if [ "$budget" -lt "$lim" ]; then lim=$budget; fi
            if [ "$sz" -gt "$lim" ]; then printf "0\\t0\\t%s\\n" "$p"; continue; fi
            if [ "$sz" -eq 0 ]; then printf "0\\t0\\t%s\\n" "$p"; continue; fi
            probe=$(head -c 8000 -- "$p" | wc -c)
            kept=$(head -c 8000 -- "$p" | LC_ALL=C tr -d "\\000" | wc -c)
            if [ "$probe" -ne "$kept" ]; then
            budget=$((budget - probe)); printf "0\\t%s\\t%s\\n" "$probe" "$p"; continue
            fi
            n=$(LC_ALL=C wc -l < "$p"); t=$(tail -c 1 -- "$p" | LC_ALL=C wc -l)
            budget=$((budget - sz)); printf "%s\\t%s\\t%s\\n" "$((n + 1 - t))" "$sz" "$p"
            done
            """
        // The newlines stay: they are the statement separators, and they
        // survive quoting on the way to the remote shell.
        return "bash -c '" + script + "'"
    }

    /// Paths for ``untrackedLineCountsCommand(totalByteBudget:perFileByteCap:)``
    /// to read on standard input.
    static func untrackedLineCountsInput(paths: [String]) -> Data {
        var data = Data()
        for path in paths {
            data.append(contentsOf: Array(path.utf8))
            data.append(0)
        }
        return data
    }

    static func parseUntrackedLineCounts(
        _ output: String
    ) -> [(path: String, lines: Int, bytesRead: Int)] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3,
                let lines = Int(fields[0]),
                let bytes = Int(fields[1]),
                !fields[2].isEmpty
            else { return nil }
            return (String(fields[2]), lines, bytes)
        }
    }

    /// Which in-progress operation a repository is in, in one round trip.
    ///
    /// Asking about each marker separately is six round trips for a question
    /// answered by six `test` calls, and it is asked on every snapshot.
    /// Prints the first marker that exists, in the caller's priority order.
    static func repositoryOperationCommand(gitDirectory: String) -> String {
        let quoted = quote(gitDirectory)
        return "for n in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD "
            + "REVERT_HEAD BISECT_LOG; do if [ -e \(quoted)\"/$n\" ]; then "
            + "printf '%s\\n' \"$n\"; break; fi; done; :"
    }

    /// Whether any directory at or above `path` holds a `.git`, in one round
    /// trip rather than one per ancestor. Prints `yes` or nothing.
    ///
    /// This is what tells a plain directory apart from a repository whose
    /// metadata is broken, so it runs every time the panel leaves a repository.
    static func gitMetadataAtOrAboveCommand(path: String) -> String {
        "d=\(quote(path)); while :; do if [ -e \"$d/.git\" ]; then printf 'yes\\n'; "
            + "break; fi; if [ \"$d\" = \"/\" ]; then break; fi; "
            + "d=$(dirname \"$d\"); done; :"
    }

    /// Runs several commands in one round trip, tagging each result so the
    /// Mac can tell them apart.
    ///
    /// A remote round trip costs about 60 ms before any work happens, so a
    /// snapshot built from a dozen sequential commands spends most of its time
    /// waiting. The tag is a fresh UUID per request, which cannot appear in
    /// any command's output, and the marker is preceded by a newline so it is
    /// always at the start of a line even when the output has no trailing one.
    static func batchCommand(_ commands: [(name: String, command: String)], tag: String) -> String {
        commands
            .map { "{ \($0.command) ; }; printf '\\n%s %s %d\\n' \(quote(tag)) \(quote($0.name)) \"$?\"" }
            .joined(separator: "; ")
    }

    struct BatchResult {
        let status: Int32
        let stdout: Data
    }

    /// Splits a batch's output back into one result per command. Works on
    /// bytes, because `git log -z` and `git status -z` embed NULs.
    static func parseBatch(_ output: Data, tag: String) -> [String: BatchResult] {
        let separator = Data(("\n" + tag + " ").utf8)
        var results: [String: BatchResult] = [:]
        var chunks: [Data] = []
        var rest = output
        while let found = rest.range(of: separator) {
            chunks.append(rest[rest.startIndex..<found.lowerBound])
            rest = rest[found.upperBound...]
        }
        chunks.append(rest)

        // Each chunk after the first opens with the previous command's marker
        // line, "<name> <status>", and the rest of it is the next output.
        var pendingOutput = chunks.first ?? Data()
        for chunk in chunks.dropFirst() {
            guard let newline = chunk.firstIndex(of: 0x0A) else { break }
            let marker = String(decoding: chunk[chunk.startIndex..<newline], as: UTF8.self)
            // The name may contain spaces (they are command lines), so the
            // status is the LAST field and the name is everything before it.
            let fields = marker.split(separator: " ")
            if fields.count >= 2, let status = Int32(fields[fields.count - 1]) {
                let name = fields.dropLast().joined(separator: " ")
                results[name] = BatchResult(status: status, stdout: pendingOutput)
            }
            pendingOutput = chunk[chunk.index(after: newline)...]
        }
        return results
    }

    // MARK: - Processes and ports

    /// `args` last, because it is the only column that contains spaces.
    /// It carries the command line rather than `comm`, so the panel can show
    /// the full path a process was started with; a process started by a bare
    /// name reports that bare name, which is all the remote knows.
    static func processListCommand() -> String {
        "ps -eo pid=,ppid=,pcpu=,rss=,args="
    }

    struct RemoteProcessRow: Equatable {
        let ppid: pid_t
        let process: WorkspaceProcess
    }

    static func parseProcessList(_ output: String) -> [RemoteProcessRow] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(
                separator: " ", maxSplits: 4, omittingEmptySubsequences: true
            )
            guard fields.count == 5,
                let pid = pid_t(fields[0]),
                let ppid = pid_t(fields[1]),
                let cpu = Double(fields[2]),
                let memoryKB = Int(fields[3])
            else { return nil }
            let commandLine = String(fields[4])
            let executable = commandLine.split(separator: " ").first.map(String.init) ?? commandLine
            return RemoteProcessRow(
                ppid: ppid,
                process: WorkspaceProcess(
                    pid: pid,
                    name: (executable as NSString).lastPathComponent,
                    executable: executable,
                    cpu: cpu,
                    memoryKB: memoryKB
                )
            )
        }
    }

    /// Breadth-first, so commands the user ran come before their workers —
    /// the order the panel already shows locally.
    static func snapshot(rows: [RemoteProcessRow], descendantsOf pid: pid_t)
        -> WorkspaceProcessSnapshot
    {
        var children: [pid_t: [WorkspaceProcess]] = [:]
        var namesByPid: [pid_t: String] = [:]
        for row in rows {
            children[row.ppid, default: []].append(row.process)
            namesByPid[row.process.pid] = row.process.name
        }

        var descendants: [WorkspaceProcess] = []
        var queue = children[pid] ?? []
        var seen: Set<pid_t> = [pid]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard seen.insert(next.pid).inserted else { continue }
            descendants.append(next)
            queue.append(contentsOf: children[next.pid] ?? [])
        }
        return WorkspaceProcessSnapshot(descendants: descendants, namesByPid: namesByPid)
    }

    /// `ss` is present on any current Linux; `lsof` is the fallback for hosts
    /// without iproute2. `-H` drops the header, `-n` keeps ports numeric.
    static func listeningPortsCommand() -> String {
        "ss -ltnpH 2>/dev/null || lsof -nP -iTCP -sTCP:LISTEN -Fpn 2>/dev/null"
    }

    /// Accepts either tool's output; they are told apart by shape.
    static func parseListeningPorts(_ output: String) -> [WorkspacePort] {
        let lines = output.split(separator: "\n")
        let isLsof = lines.first?.first.map { $0 == "p" || $0 == "n" } ?? false
        let ports = isLsof ? parseLsofPorts(lines) : parseSsPorts(lines)
        // One socket bound on both IPv4 and IPv6 is two rows for one port.
        var seen = Set<String>()
        return ports.filter { seen.insert("\($0.pid):\($0.port)").inserted }
    }

    /// `LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1234,fd=3))`
    private static func parseSsPorts(_ lines: [Substring]) -> [WorkspacePort] {
        var ports: [WorkspacePort] = []
        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, let port = trailingPort(fields[3]) else { continue }
            // A socket may be shared, so every pid= in the row counts.
            for pid in pidValues(in: line) {
                ports.append(WorkspacePort(port: port, pid: pid))
            }
        }
        return ports
    }

    /// `lsof -F` prints one field per line, `p` starting a process's block and
    /// `n` naming each of its sockets.
    private static func parseLsofPorts(_ lines: [Substring]) -> [WorkspacePort] {
        var ports: [WorkspacePort] = []
        var current: pid_t?
        for line in lines {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p": current = pid_t(value)
            case "n":
                if let pid = current, let port = trailingPort(value) {
                    ports.append(WorkspacePort(port: port, pid: pid))
                }
            default: break
            }
        }
        return ports
    }

    /// The port after the last colon, which is what both tools print and what
    /// keeps an IPv6 address such as `[::]:8000` from being misread.
    private static func trailingPort(_ value: Substring) -> Int? {
        guard let colon = value.lastIndex(of: ":") else { return nil }
        return Int(value[value.index(after: colon)...])
    }

    private static func pidValues(in line: Substring) -> [pid_t] {
        line.components(separatedBy: "pid=").dropFirst().compactMap { part in
            pid_t(part.prefix { $0.isNumber })
        }
    }
}

#if DEBUG
extension RemoteCommands {
    /// Self-check standing in for a unit test target, which this project does
    /// not have. Fixtures are the literal output recorded when these commands
    /// were run against the Ubuntu test host.
    static func runSelfCheck() {
        assert(quote("/home/ubuntu/kero probe") == "'/home/ubuntu/kero probe'")
        assert(quote("it's") == #"'it'"'"'s'"#)

        assert(
            forwardSpec(localPort: 64444, remotePort: 22) == "127.0.0.1:64444:127.0.0.1:22")
        assert(
            forwardArguments(
                controlSocket: "/tmp/k.sock", destination: "oracle",
                localPort: 64444, remotePort: 22)
                == [
                    "-S", "/tmp/k.sock", "-O", "forward",
                    "-L", "127.0.0.1:64444:127.0.0.1:22", "oracle",
                ])
        assert(
            cancelForwardArguments(
                controlSocket: "/tmp/k.sock", destination: "oracle",
                localPort: 64444, remotePort: 22)[3] == "cancel")
        if let port = freeLocalPort() { assert(port >= 1024) }

        // The variable must reach the remote shell unexpanded.
        let discovery = shellDiscoveryCommand()
        assert(discovery.contains("$SSH_CONNECTION"))
        assert(discovery.contains("sshd*"))
        assert(!discovery.contains("LC_KERO_TERMINAL"))
        let tagged = shellDiscoveryCommand(terminalTag: "test-uuid-1234")
        assert(tagged.contains("'LC_KERO_TERMINAL=test-uuid-1234'"))

        // Observed: pid 314134, cwd /home/ubuntu/kero-probe-1788328105/sub.
        let found = parseShellDiscovery("314134 /home/ubuntu/kero-probe-1788328105/sub\n")
        assert(found?.pid == 314134)
        assert(found?.directory == "/home/ubuntu/kero-probe-1788328105/sub")
        assert(parseShellDiscovery("")  == nil)
        assert(parseShellDiscovery("314134\n") == nil)
        assert(parseShellDiscovery("42 /home/ubuntu/my project")?.directory
            == "/home/ubuntu/my project")

        assert(statCommand(path: "/tmp/x").contains("stat --printf '%F\\t%s\\t%Y\\t%a\\n' -- '/tmp/x'"))
        assert(statCommand(path: "/tmp/x").contains("stat -L --printf"))
        // `-H` is load-bearing: without it a symlinked directory lists as empty.
        assert(
            listDirectoryCommand(path: "/home/ubuntu/kero-probe-1788328105")
                == "find -H '/home/ubuntu/kero-probe-1788328105' -maxdepth 1 -mindepth 1"
                + " -printf '%y\\t%Y\\t%f\\0'")
        assert(listDirectoryCommand(path: "/tmp/sub-link").hasPrefix("find -H "))
        let listing = Data(
            "f\tf\tscript.sh\0d\td\tsub\0l\td\tlink-to-sub\0l\tL\tbroken\0".utf8)
        let entries = parseDirectoryListing(listing)
        assert(entries.count == 4)
        assert(entries[0] == WorkspaceEntry(name: "script.sh", isDirectory: false, isSymlink: false))
        assert(entries[1] == WorkspaceEntry(name: "sub", isDirectory: true, isSymlink: false))
        // A symlink to a directory is both, as the local backend reports it.
        assert(entries[2] == WorkspaceEntry(name: "link-to-sub", isDirectory: true, isSymlink: true))
        assert(entries[3] == WorkspaceEntry(name: "broken", isDirectory: false, isSymlink: true))

        // Observed after the atomic write: 29 bytes, mode 755.
        let statOutput = "regular file\t29\t1788328250\t755\nregular file\t29\t1788328250\t755"
        let parsed = parseStat(statOutput)
        assert(parsed?.mode == 0o755)
        assert(parsed?.stat.isRegular == true)
        assert(parsed?.stat.isSymlink == false)
        assert(parsed?.stat.size == 29)
        assert(parsed?.stat.mtime == Date(timeIntervalSince1970: 1_788_328_250))
        let symlinkToDirectory = parseStat("symbolic link\t3\t1788328250\t777\ndirectory\t4096\t1788328000\t755")
        assert(symlinkToDirectory?.stat.isSymlink == true)
        assert(symlinkToDirectory?.stat.isDirectory == true)
        assert(symlinkToDirectory?.mode == 0o755)
        // Broken symlink: the second stat prints nothing.
        let broken = parseStat("symbolic link\t7\t1788328250\t777")
        assert(broken?.stat.isSymlink == true)
        assert(broken?.stat.isDirectory == false)
        assert(parseStat("") == nil)

        assert(atomicWriteCommand(path: "/home/ubuntu/a b.sh").hasSuffix("_ '/home/ubuntu/a b.sh'"))
        assert(atomicWriteCommand(path: "/tmp/x").contains("chmod --reference="))
        assert(atomicWriteCommand(path: "/tmp/x").contains("mv -f"))

        let counts = untrackedLineCountsCommand(totalByteBudget: 32, perFileByteCap: 8)
        assert(counts.hasPrefix("bash -c '") && counts.hasSuffix("'"))
        // The script must carry no single quote of its own, or the wrapper ends early.
        assert(!counts.dropFirst("bash -c '".count).dropLast().contains("'"))
        assert(counts.contains("budget=32") && counts.contains("cap=8"))
        assert(untrackedLineCountsInput(paths: ["/a b", "/c"]) == Data("/a b\u{0}/c\u{0}".utf8))

        let countOutput = "3\t27\t/repo/a.txt\n1\t0\t/repo/link\n0\t8000\t/repo/blob.bin\n0\t0\t/repo/huge\n"
        let parsedCounts = parseUntrackedLineCounts(countOutput)
        assert(parsedCounts.count == 4)
        assert(parsedCounts[0] == ("/repo/a.txt", 3, 27))
        assert(parsedCounts[1] == ("/repo/link", 1, 0))
        assert(parsedCounts[2] == ("/repo/blob.bin", 0, 8000))
        assert(parsedCounts[3] == ("/repo/huge", 0, 0))
        assert(parsedCounts.reduce(0) { $0 + $1.lines } == 4)
        // A path containing a tab survives, because the path is the last field.
        assert(parseUntrackedLineCounts("2\t4\t/repo/od\td")[0].path == "/repo/od\td")
        assert(parseUntrackedLineCounts("rubbish").isEmpty)

        let operation = repositoryOperationCommand(gitDirectory: "/r/.git")
        assert(operation.contains("'/r/.git'\"/$n\""))
        assert(operation.contains("rebase-merge rebase-apply MERGE_HEAD"))
        let walk = gitMetadataAtOrAboveCommand(path: "/a/b")
        assert(walk.hasPrefix("d='/a/b';") && walk.contains("dirname"))

        // Names are command lines and contain spaces, which the marker parse
        // has to survive - the status is the last field, not the second.
        let batch = batchCommand(
            [("rev-parse --show-toplevel", "git rev-parse"), ("st", "git status")],
            tag: "TAG-1")
        assert(batch.contains("{ git rev-parse ; }"))
        assert(batch.contains("printf '\\n%s %s %d\\n' 'TAG-1' 'rev-parse --show-toplevel' \"$?\""))
        // Output with no trailing newline, and a NUL, both survive.
        var batchOut = Data("/repo".utf8)
        batchOut.append(Data("\nTAG-1 rev-parse --show-toplevel 0\n".utf8))
        batchOut.append(Data([0x61, 0x00, 0x62]))
        batchOut.append(Data("\nTAG-1 st 1\n".utf8))
        let parsedBatch = parseBatch(batchOut, tag: "TAG-1")
        assert(parsedBatch["rev-parse --show-toplevel"]?.status == 0)
        assert(parsedBatch["rev-parse --show-toplevel"]
            .map { String(decoding: $0.stdout, as: UTF8.self) } == "/repo")
        assert(parsedBatch["st"]?.status == 1)
        assert(parsedBatch["st"]?.stdout == Data([0x61, 0x00, 0x62]))
        assert(parseBatch(Data(), tag: "TAG-1").isEmpty)

        let psOutput = """
              313852  313851  0.0   6144 sshd: ubuntu@pts/0
              313855  313852  0.1   5632 -bash
              314000  313855  12.5 104448 /usr/bin/node /home/ubuntu/app/server.js
              314001  314000  0.0   2048 [kworker]
            """
        let rows = parseProcessList(psOutput)
        assert(rows.count == 4)
        assert(rows[2].process.pid == 314000)
        assert(rows[2].process.name == "node")
        assert(rows[2].process.executable == "/usr/bin/node")
        assert(rows[2].process.cpu == 12.5)
        assert(rows[2].process.memoryKB == 104448)
        let tree = snapshot(rows: rows, descendantsOf: 313855)
        assert(tree.descendants.map(\.pid) == [314000, 314001])
        assert(tree.namesByPid[313855] == "-bash")

        let ssOutput = """
            LISTEN 0      4096         0.0.0.0:22        0.0.0.0:* users:(("sshd",pid=1234,fd=3))
            LISTEN 0      4096            [::]:22           [::]:* users:(("sshd",pid=1234,fd=4))
            LISTEN 0      511        127.0.0.1:8000       0.0.0.0:* users:(("python3",pid=314000,fd=3))
            """
        let ssPorts = parseListeningPorts(ssOutput)
        // The IPv4 and IPv6 rows for port 22 are one listener.
        assert(ssPorts.count == 2)
        assert(ssPorts.contains(WorkspacePort(port: 22, pid: 1234)))
        assert(ssPorts.contains(WorkspacePort(port: 8000, pid: 314000)))

        let lsofOutput = """
            p1234
            n*:22
            p314000
            n127.0.0.1:8000
            """
        let lsofPorts = parseListeningPorts(lsofOutput)
        assert(lsofPorts == [
            WorkspacePort(port: 22, pid: 1234),
            WorkspacePort(port: 8000, pid: 314000),
        ])
        assert(parseListeningPorts("").isEmpty)
    }
}
#endif

//
//  WorkspaceBackend.swift
//  kero
//

import Darwin
import Foundation

/// One directory entry, as the file tree needs it.
struct WorkspaceEntry: Sendable, Equatable {
    let name: String
    /// Directory after following symlinks, matching `FileManager.fileExists`.
    let isDirectory: Bool
    let isSymlink: Bool
}

/// Metadata about one path, following symlinks for everything but `isSymlink`.
struct WorkspaceStat: Sendable, Equatable {
    let isRegular: Bool
    let isDirectory: Bool
    /// True when the path *itself* is a symlink, whatever it resolves to.
    let isSymlink: Bool
    let size: Int
    let mtime: Date
}

/// One process under the session's shell.
struct WorkspaceProcess: Sendable, Equatable {
    let pid: pid_t
    /// Executable name, e.g. "node".
    let name: String
    /// Full executable path.
    let executable: String
    let cpu: Double
    let memoryKB: Int
}

/// Descendants of one process, plus the names of every process on the machine.
/// The names come along because a listening socket can belong to the shell
/// itself, which is not one of its own descendants.
struct WorkspaceProcessSnapshot: Sendable {
    /// Breadth-first, so commands the user ran come before their workers.
    let descendants: [WorkspaceProcess]
    let namesByPid: [pid_t: String]
}

/// One TCP port a process is listening on.
struct WorkspacePort: Sendable, Equatable {
    let port: Int
    let pid: pid_t
}

struct WorkspaceRunResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// Failures a consumer has to tell apart to keep its own wording. Anything
/// else propagates as the original system error, so messages built from
/// `localizedDescription` read exactly as they do without a backend.
enum WorkspaceError: Error {
    case notFound
    case tooLarge
    /// `FileManager.createFile` reports failure without an error.
    case createFileFailed
    case timedOut
}

/// The workspace a project's panels, editor and diff viewer operate on: the
/// Mac's own disk and process table today, a machine reached over SSH later.
///
/// Every method is `async throws` because the remote implementation costs a
/// round trip per call and must never run on the main actor — the shape has to
/// be async even where the local implementation answers immediately.
protocol WorkspaceBackend: Sendable {
    // MARK: Files
    func list(directory: String) async throws -> [WorkspaceEntry]
    func stat(path: String) async throws -> WorkspaceStat?
    /// The target of a symlink, or nil when `path` is not one.
    func readSymlinkDestination(path: String) async throws -> String?
    /// At most `maxBytes`; throws `WorkspaceError.tooLarge` beyond that and
    /// `.notFound` when the path is gone.
    func read(path: String, maxBytes: Int) async throws -> Data
    func write(path: String, data: Data) async throws
    func createFile(path: String) async throws
    func createDirectory(path: String) async throws
    func rename(from: String, to: String) async throws
    /// Locally this moves to the Trash.
    func delete(paths: [String]) async throws

    // MARK: Git geography
    /// Directory of the nearest enclosing git repository, walking up.
    func gitRoot(containing path: String) async throws -> String?
    /// Whether `root` is a linked worktree rather than a normal checkout.
    func isLinkedWorktree(_ root: String) async throws -> Bool

    // MARK: Processes
    func run(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?
    ) async throws -> WorkspaceRunResult
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort]
    func kill(pid: pid_t, force: Bool) async throws
}

/// Mutable pipe storage for one reader thread each, so a child process can
/// never deadlock on a full pipe while we wait for it to exit.
private final class RunPipeData: @unchecked Sendable {
    var value = Data()
}

/// The Mac's own disk and process table. Wraps exactly the calls the panels
/// made inline before the seam existed.
///
/// Nothing is stored, so the type is `Sendable` and its `nonisolated async`
/// methods run off the main actor even when a main-actor model awaits them.
final class LocalWorkspaceBackend: WorkspaceBackend {
    static let shared = LocalWorkspaceBackend()

    // MARK: - Files

    func list(directory: String) async throws -> [WorkspaceEntry] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        return names.map { name in
            let path = (directory as NSString).appendingPathComponent(name)
            var info = Darwin.stat()
            // lstat describes the link itself, and its mode already answers
            // "directory?" for everything that is not a link. Only a link
            // needs the second, symlink-following call.
            guard lstat(path, &info) == 0 else {
                return WorkspaceEntry(name: name, isDirectory: false, isSymlink: false)
            }
            guard (info.st_mode & S_IFMT) == S_IFLNK else {
                return WorkspaceEntry(
                    name: name,
                    isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
                    isSymlink: false
                )
            }
            var isDirectory: ObjCBool = false
            let resolved = FileManager.default.fileExists(
                atPath: path, isDirectory: &isDirectory
            )
            return WorkspaceEntry(
                name: name,
                isDirectory: resolved && isDirectory.boolValue,
                isSymlink: true
            )
        }
    }

    func stat(path: String) async throws -> WorkspaceStat? {
        Self.statSync(path)
    }

    func readSymlinkDestination(path: String) async throws -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    func read(path: String, maxBytes: Int) async throws -> Data {
        try Self.readSync(path: path, maxBytes: maxBytes)
    }

    /// The same read, for the two places that cannot await: `Project`'s
    /// synchronous panel root and a file tab's initial content, which is
    /// produced in a synchronous initializer.
    static func readSync(path: String, maxBytes: Int) throws -> Data {
        do {
            // Keep one descriptor for the whole read: replacing the path while
            // an agent writes cannot redirect us to a different, larger file.
            // Seek checks catch growth without ever loading more than maxBytes.
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let initialSize = try handle.seekToEnd()
            guard initialSize <= UInt64(maxBytes) else { throw WorkspaceError.tooLarge }
            try handle.seek(toOffset: 0)

            var data = Data()
            while data.count < maxBytes {
                let remaining = min(64 * 1024, maxBytes - data.count)
                guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
            let finalSize = try handle.seekToEnd()
            guard finalSize <= UInt64(maxBytes) else { throw WorkspaceError.tooLarge }
            return data
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            throw WorkspaceError.notFound
        }
    }

    /// The initial content of a file tab, which is built synchronously.
    /// Nil on any failure, matching the tolerance that read has always had.
    func readImmediately(path: String) -> Data? {
        try? Self.readSync(path: path, maxBytes: .max)
    }

    func write(path: String, data: Data) async throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func createFile(path: String) async throws {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw WorkspaceError.createFileFailed
        }
    }

    func createDirectory(path: String) async throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: false
        )
    }

    func rename(from: String, to: String) async throws {
        try FileManager.default.moveItem(atPath: from, toPath: to)
    }

    func delete(paths: [String]) async throws {
        for path in paths {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: path), resultingItemURL: nil
            )
        }
    }

    // MARK: - Git geography

    func gitRoot(containing path: String) async throws -> String? {
        Self.gitRootSync(containing: path)
    }

    func isLinkedWorktree(_ root: String) async throws -> Bool {
        Self.isLinkedWorktreeSync(root)
    }

    /// Shared with `Project.panelRoot`, which still has a synchronous form for
    /// callers that cannot await (the command palette and the Git panel).
    static func statSync(_ path: String) -> WorkspaceStat? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        // Following symlinks matches `FileManager.fileExists`, so a dangling
        // link reads as "does not exist" here as it did inline.
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
        // Attributes describe the link rather than its target, so a symlink is
        // never reported as a regular file — the editability gate this
        // replaces drew the same conclusion the same way.
        let attributes = try? fm.attributesOfItem(atPath: path)
        return WorkspaceStat(
            isRegular: (attributes?[.type] as? FileAttributeType) == .typeRegular,
            isDirectory: isDirectory.boolValue,
            isSymlink: isSymlink,
            size: (attributes?[.size] as? Int) ?? 0,
            mtime: (attributes?[.modificationDate] as? Date) ?? .distantPast
        )
    }

    /// Walks up from `path` looking for a `.git` entry — a directory in normal
    /// checkouts, a file in worktrees and submodules.
    static func gitRootSync(containing path: String) -> String? {
        var dir = (path as NSString).standardizingPath
        guard dir.hasPrefix("/") else { return nil }
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                return dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { return nil }
            dir = parent
        }
    }

    /// A linked worktree's `.git` is a file pointing into the main
    /// repository's `worktrees` directory (a submodule's points into
    /// `modules` instead).
    static func isLinkedWorktreeSync(_ root: String) -> Bool {
        let gitPath = (root as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let contents = try? String(contentsOfFile: gitPath, encoding: .utf8)
        else { return false }
        return contents.contains("/worktrees/")
    }

    // MARK: - Processes

    func run(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?
    ) async throws -> WorkspaceRunResult {
        // Waiting on pipe readers blocks, which an async function may not do,
        // so the whole launch runs on a background thread — where the panels
        // ran their `ps` and `lsof` calls before the seam existed.
        try await Task.detached(priority: .utility) {
            try Self.runSync(
                argv: argv, cwd: cwd, env: env, stdin: stdin, timeout: timeout
            )
        }.value
    }

    private static func runSync(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?
    ) throws -> WorkspaceRunResult {
        guard let executable = argv.first else { throw WorkspaceError.notFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
        if let env {
            process.environment = env
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            try? input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }

        // Drain both pipes on their own threads so a chatty child cannot
        // deadlock against our wait for it to exit.
        let outData = RunPipeData()
        let errData = RunPipeData()
        let readers = DispatchGroup()
        readers.enter()
        Thread {
            outData.value = stdout.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }.start()
        readers.enter()
        Thread {
            errData.value = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }.start()

        if let timeout, readers.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            readers.wait()
            process.waitUntilExit()
            throw WorkspaceError.timedOut
        }
        readers.wait()
        process.waitUntilExit()
        return WorkspaceRunResult(
            status: process.terminationStatus,
            stdout: outData.value,
            stderr: errData.value
        )
    }

    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot {
        // `comm` is the executable path with no arguments, so the only
        // free-form field is the last one and column parsing stays safe.
        let psOut = try await text(
            argv: ["/bin/ps", "-axo", "pid=,ppid=,stat=,pcpu=,rss=,comm="]
        )
        var itemsByPid: [pid_t: WorkspaceProcess] = [:]
        var names: [pid_t: String] = [:]
        var childPids: [pid_t: [pid_t]] = [:]
        for line in psOut.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6,
                  let pid = pid_t(fields[0]),
                  let ppid = pid_t(fields[1]) else { continue }
            // Recorded before the zombie check so the descendant walk below
            // still traverses the tree through anything we skip.
            childPids[ppid, default: []].append(pid)
            // Zombies are children that already exited and are waiting to be
            // reaped: `ps` names them "<defunct>", they hold no CPU or memory,
            // and no signal can touch them. Nothing to show or act on.
            guard !fields[2].hasPrefix("Z") else { continue }
            let executable = String(fields[5])
            let name = (executable as NSString).lastPathComponent
            names[pid] = name
            itemsByPid[pid] = WorkspaceProcess(
                pid: pid,
                name: name,
                executable: executable,
                cpu: Double(fields[3]) ?? 0,
                memoryKB: Int(fields[4]) ?? 0
            )
        }

        // Descendants breadth-first: the commands the user ran come before
        // the workers they spawned.
        var descendants: [WorkspaceProcess] = []
        var queue = childPids[pid] ?? []
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let item = itemsByPid[next] {
                descendants.append(item)
            }
            queue.append(contentsOf: childPids[next] ?? [])
        }
        return WorkspaceProcessSnapshot(descendants: descendants, namesByPid: names)
    }

    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] {
        guard !pids.isEmpty else { return [] }
        let list = pids.map(String.init).joined(separator: ",")
        // -a ANDs the selectors, so this only inspects the session's own
        // processes instead of walking every fd on the machine.
        let out = try await text(
            argv: [
                "/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", list, "-Fpn",
            ]
        )

        var ports: [WorkspacePort] = []
        var seen = Set<String>()
        var currentPid: pid_t = 0
        for line in out.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            switch field {
            case "p":
                currentPid = pid_t(value) ?? 0
            case "n":
                // Addresses look like "*:3000", "127.0.0.1:3000", "[::1]:3000".
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                // The same socket shows once for IPv4 and once for IPv6.
                if seen.insert("\(currentPid):\(port)").inserted {
                    ports.append(WorkspacePort(port: port, pid: currentPid))
                }
            default:
                break
            }
        }
        return ports.sorted { $0.port < $1.port }
    }

    func kill(pid: pid_t, force: Bool) async throws {
        Darwin.kill(pid, force ? SIGKILL : SIGTERM)
    }

    /// Decoded stdout, empty when the tool could not be launched — the
    /// tolerance `ps` and `lsof` parsing has always had.
    private func text(argv: [String]) async throws -> String {
        guard let result = try? await run(
            argv: argv, cwd: nil, env: nil, stdin: nil, timeout: nil
        ) else { return "" }
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }
}

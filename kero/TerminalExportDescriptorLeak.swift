//
//  TerminalExportDescriptorLeak.swift
//  kero
//

import Darwin
import Foundation

/// Reclaims file descriptors that libghostty's screen export leaks.
///
/// Ghostty's `write_screen_file`/`write_scrollback_file` actions create a
/// fresh temporary directory per export via `os.TempDir`, which opens two
/// directory descriptors: the new random-name subdirectory and its parent,
/// the process temporary directory. On the success path neither is closed -
/// `tmp_dir.deinit()` runs only under `errdefer`, and even `deinit` never
/// closes the parent (ghostty `src/Surface.zig` `writeScreenFile`,
/// `src/os/TempDir.zig`). Every export therefore leaks two descriptors
/// inside the prebuilt GhosttyKit binary, where Kero cannot fix it directly.
///
/// Kero exports a screen file roughly every 0.75s per recognized agent
/// session (the agent monitor's viewport read), so the process descriptor
/// table fills after a few hours of agent use. From then on `openpty()`
/// fails and every new split or tab opens as an empty pane with no shell.
///
/// The reclaim is deliberately conservative. Only descriptors that appeared
/// during the bracketed export call, are directories, and resolve to the
/// temporary root - or to the export's own subdirectory - are closed;
/// everything else is left untouched.
enum TerminalExportDescriptorLeak {
    /// `F_GETPATH` reports kernel-resolved paths, so canonicalize with
    /// `realpath(3)` - Foundation's `resolvingSymlinksInPath` strips the
    /// `/private` prefix that the kernel keeps, which would make every
    /// comparison against `/private/var/folders/…/T` silently fail.
    private static let temporaryRootPath: String =
        canonicalPath(FileManager.default.temporaryDirectory.path)
            ?? FileManager.default.temporaryDirectory.path

    private static func canonicalPath(_ path: String) -> String? {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &resolved) != nil else { return nil }
        return String(cString: resolved)
    }

    /// Every descriptor currently open in this process.
    static func openDescriptors() -> Set<Int32> {
        let pid = getpid()
        let entrySize = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        // Headroom for descriptors another thread opens between the two calls.
        let capacity = Int(size) / entrySize + 32
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let filled = proc_pidinfo(
            pid, PROC_PIDLISTFDS, 0, &buffer, Int32(capacity * entrySize)
        )
        guard filled > 0 else { return [] }
        return Set(buffer.prefix(Int(filled) / entrySize).map(\.proc_fd))
    }

    /// Closes descriptors the bracketed export leaked: ones not in `before`,
    /// open on a directory that is the temporary root or the export's own
    /// subdirectory beneath it. When the export produced no file (an empty
    /// alternate screen, or a failure inside Ghostty) the temporary directory
    /// was still created, so any fresh direct child of the root qualifies.
    static func reclaim(appearedSince before: Set<Int32>, exportedFilePath: String?) {
        let exportDirectory = exportedFilePath.flatMap {
            canonicalPath(($0 as NSString).deletingLastPathComponent)
        }
        for descriptor in openDescriptors().subtracting(before) {
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR
            else { continue }
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let resolved = pathBuffer.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return fcntl(descriptor, F_GETPATH, base)
            }
            guard resolved != -1 else { continue }
            let path = String(cString: pathBuffer)
            guard isLeakedExportDirectory(
                path: path, exportDirectory: exportDirectory
            ) else { continue }
            close(descriptor)
        }
    }

    private static func isLeakedExportDirectory(
        path: String, exportDirectory: String?
    ) -> Bool {
        if path == temporaryRootPath { return true }
        if let exportDirectory { return path == exportDirectory }
        // No file was emitted, so the subdirectory's random name is unknown;
        // accept a direct child of the root but nothing deeper.
        return path.hasPrefix(temporaryRootPath + "/")
            && !path.dropFirst(temporaryRootPath.count + 1).contains("/")
    }
}

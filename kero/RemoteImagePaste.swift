//
//  RemoteImagePaste.swift
//  kero
//

import AppKit

/// Image paste for panes running `ssh`.
///
/// Image-aware TUIs such as Claude Code answer Ctrl-V by reading the
/// clipboard of the machine they run on. Over ssh that is a headless server
/// with no clipboard, so the paste silently does nothing. Kero instead
/// uploads the Mac's image over the session's own control socket and pastes
/// the remote path, which those TUIs attach exactly like a local file.
enum RemoteImagePaste {
    /// Uploads older than this are removed on the next paste, so the folder
    /// cannot grow without bound.
    private static let retentionMinutes = 1440

    /// The clipboard image as PNG, or nil when the clipboard holds text or
    /// files. Copying a file in Finder also offers its icon as an image; that
    /// paste belongs to the ordinary text path, never this one.
    @MainActor
    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if pasteboard.string(forType: .string) != nil { return nil }
        if pasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) { return nil }
        if let png = pasteboard.data(forType: .png) { return png }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Writes `png` to the remote cache, owner-only, and returns its absolute
    /// path. Wrapped in `sh -c` because the remote login shell may not be
    /// POSIX.
    static func upload(_ png: Data, over connection: RemoteConnection) async throws -> String {
        let name = UUID().uuidString.lowercased() + ".png"
        let script = """
        umask 077
        d="${XDG_CACHE_HOME:-$HOME/.cache}/kero/paste"
        mkdir -p "$d" || exit 1
        find "$d" -type f -name '*.png' -mmin +\(retentionMinutes) -exec rm -f {} + 2>/dev/null
        f="$d/\(name)"
        cat > "$f" || exit 1
        printf '%s' "$f"
        """
        let result = try await connection.run(
            [RemoteConnection.remoteScript(["sh", "-c", script], cwd: nil)],
            stdin: png
        )
        let path = RemoteConnection.text(result.stdout)
        guard result.status == 0, path.hasPrefix("/") else {
            throw RemoteConnectionError.commandFailed(
                status: result.status,
                message: RemoteConnection.text(result.stderr)
            )
        }
        return path
    }
}

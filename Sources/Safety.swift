// Dandelion - safety checks before anything goes to the Trash.
// MIT License. See LICENSE.

import Darwin
import Foundation

enum Safety {
    /// Why an item can't go to the Trash, or nil if it can.
    /// macOS (and your account) need certain folders to exist. Their *contents* are often fair game
    /// (old downloads, caches), but the folders themselves, and anything inside the system, are not.
    static func protectionReason(_ node: Node) -> String? {
        if node.isSynthetic { return "Hidden space isn't a real file, so there's nothing to remove." }
        if node.isRoot { return "That's the folder you scanned. Pick things inside it instead." }
        return protectionReason(path: node.path, title: node.title)
    }

    /// The same rules for any path (used by the Duplicate Finder and Folder Rules).
    static func protectionReason(path: String, title: String) -> String? {
        let p = logicalPath(path)
        let home = logicalPath(NSHomeDirectory())

        let exact: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/Users/Shared", "/Volumes", "/bin", "/sbin",
            "/usr", "/usr/local", "/private", "/private/var", "/private/etc", "/private/tmp", "/private/var/folders",
            "/opt", "/opt/homebrew", "/cores", "/dev", "/etc", "/var", "/tmp", "/Network",
            home, home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Movies",
            home + "/Music", home + "/Pictures", home + "/Public", home + "/Applications",
            home + "/Library/Application Support", home + "/Library/Preferences", home + "/Library/Containers",
            home + "/Library/Group Containers", home + "/Library/Mobile Documents", home + "/Library/Keychains",
        ]
        if exact.contains(p) { return "macOS needs \u{201C}\(title)\u{201D} itself. You can remove things inside it, though." }

        let inside = ["/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/lib/", "/usr/libexec/", "/usr/sbin/", "/usr/share/",
                      "/private/var/db/", "/private/var/vm/", "/private/etc/", "/dev/", "/Library/Apple/",
                      home + "/Library/Keychains/"]
        if inside.contains(where: { p.hasPrefix($0) }) {
            return "\u{201C}\(title)\u{201D} is part of macOS. Removing it could stop your Mac from working, so Dandelion won't."
        }
        // someone's whole home folder
        let parts = p.split(separator: "/")
        if parts.count == 2 && parts[0] == "Users" {
            return "That's a whole user's home folder. Pick things inside it instead."
        }
        return nil
    }

    /// The startup disk is scanned through its Data volume; this maps those paths back to the ones you know.
    static func logicalPath(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        if path == data { return "/" }
        if path.hasPrefix(data + "/") { return String(path.dropFirst(data.count)) }
        return path
    }

    /// Makes sure the item on disk is still exactly what was scanned before it's moved:
    /// same file, inside the same real folder (so a link swapped in can't redirect the move somewhere else).
    /// Returns a problem to show, or nil if it's safe.
    static func verify(_ node: Node) -> String? {
        let path = node.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return "\u{201C}\(node.title)\u{201D} isn't there anymore." }
        let isDirNow = (Int(st.st_mode) & 0o170000) == 0o040000
        if (node.fileID != 0 && UInt64(st.st_ino) != node.fileID) || isDirNow != node.isDir {
            return "\u{201C}\(node.title)\u{201D} changed since the scan. Rescan, then try again."
        }
        guard let parent = node.parent else { return "That's the folder you scanned." }
        var ps = stat()
        let parentPath = (path as NSString).deletingLastPathComponent
        guard lstat(parentPath, &ps) == 0, (Int(ps.st_mode) & 0o170000) == 0o040000,
              parent.fileID == 0 || UInt64(ps.st_ino) == parent.fileID else {
            return "The folder holding \u{201C}\(node.title)\u{201D} changed since the scan. Rescan, then try again."
        }
        return nil
    }
}

// Dandelion - file icons, fast.
// Asking Finder for each file's own icon reads the disk every time. Plain files and folders share one
// icon per type instead, so a long list draws instantly; only app-style bundles get their real icon.
// MIT License. See LICENSE.

import AppKit
import UniformTypeIdentifiers

@MainActor
final class Icons {
    static let shared = Icons()

    private var byType: [String: NSImage] = [:]
    private var byPath: [String: NSImage] = [:]
    private let folder = NSWorkspace.shared.icon(for: .folder)
    private let generic = NSWorkspace.shared.icon(for: .data)
    private let hidden = NSImage(systemSymbolName: "eye.slash.circle.fill", accessibilityDescription: "Hidden space") ?? NSImage()
    /// Folders that Finder shows as a single item with their own icon.
    private let bundles: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "pkg", "mpkg", "prefpane", "saver", "qlgenerator",
        "photoslibrary", "fcpbundle", "logicx", "band", "imovielibrary", "musiclibrary", "tvlibrary", "xcarchive",
        "xcodeproj", "xcworkspace", "playground", "rtfd", "pages", "numbers", "key", "sparsebundle", "photolibrary",
    ]

    func icon(for node: Node) -> NSImage {
        if node.isSynthetic { return hidden }
        if node.isRoot { return icon(forPath: node.path) }
        let ext = (node.name as NSString).pathExtension.lowercased()
        if node.isDir {
            return !ext.isEmpty && bundles.contains(ext) ? icon(forPath: node.path) : folder
        }
        if ext.isEmpty { return generic }
        if let cached = byType[ext] { return cached }
        let img = UTType(filenameExtension: ext).map { NSWorkspace.shared.icon(for: $0) } ?? generic
        byType[ext] = img
        return img
    }

    func icon(forPath path: String) -> NSImage {
        if let cached = byPath[path] { return cached }
        let img = NSWorkspace.shared.icon(forFile: path)
        if byPath.count > 2000 { byPath.removeAll() }
        byPath[path] = img
        return img
    }

    func forget() { byPath.removeAll() }
}

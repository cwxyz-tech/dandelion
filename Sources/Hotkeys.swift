// Dandelion - global keyboard shortcuts (work from any app while Dandelion is running).
// Uses the Carbon hot key API, which needs no special permission.
// MIT License. See LICENSE.

import AppKit
import Carbon.HIToolbox

final class Hotkeys {
    static let shared = Hotkeys()

    /// The shortcuts Dandelion registers, all Option-Shift-number so they sit next to the system's Command-Shift ones.
    enum Shortcut: UInt32, CaseIterable {
        case captureScreen = 1, captureArea, captureWindow, record

        var keyCode: UInt32 {
            switch self {
            case .captureScreen: return UInt32(kVK_ANSI_3)
            case .captureArea: return UInt32(kVK_ANSI_4)
            case .captureWindow: return UInt32(kVK_ANSI_5)
            case .record: return UInt32(kVK_ANSI_6)
            }
        }

        /// How it's written in menus and on screen.
        var label: String {
            switch self {
            case .captureScreen: return "⌥⇧3"
            case .captureArea: return "⌥⇧4"
            case .captureWindow: return "⌥⇧5"
            case .record: return "⌥⇧6"
            }
        }

        var keyEquivalent: KeyEquivalentInfo {
            switch self {
            case .captureScreen: return KeyEquivalentInfo(key: "3")
            case .captureArea: return KeyEquivalentInfo(key: "4")
            case .captureWindow: return KeyEquivalentInfo(key: "5")
            case .record: return KeyEquivalentInfo(key: "6")
            }
        }
    }

    struct KeyEquivalentInfo { let key: Character }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    /// Registers (or replaces) a shortcut. Returns false if another app already owns it.
    @discardableResult
    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        installHandler()
        if let old = refs[shortcut.rawValue] { UnregisterEventHotKey(old); refs[shortcut.rawValue] = nil }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4441_4E44), id: shortcut.rawValue)   // "DAND"
        let status = RegisterEventHotKey(shortcut.keyCode, UInt32(optionKey | shiftKey), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[shortcut.rawValue] = ref
        actions[shortcut.rawValue] = action
        return true
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard status == noErr else { return status }
            let id = hk.id
            DispatchQueue.main.async { Hotkeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Windows Dandelion opens besides the main one (screenshot editors). Kept alive until they're closed.
@MainActor
enum ExtraWindows {
    private static var shown: [NSWindow] = []
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    @discardableResult
    static func show(_ controller: NSViewController, title: String, size: NSSize, minSize: NSSize = NSSize(width: 520, height: 380)) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = controller
        w.setContentSize(size)
        w.contentMinSize = minSize
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        shown.append(w)
        let key = ObjectIdentifier(w)
        observers[key] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in
                shown.removeAll { $0 === w }
                if let o = observers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(o) }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        return w
    }
}

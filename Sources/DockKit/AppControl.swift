import AppKit
import ApplicationServices

/// Reaches into another running app through the Accessibility API: mirrors its
/// menu bar as Dock-menu actions, lists/raises/cycles its windows, and screenshots
/// its front window. Everything is on-demand (when a menu opens); nothing polls.
public enum AppControl {

    // MARK: AX helpers

    static func element(for app: NSRunningApplication) -> AXUIElement {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 1.0)          // a hung app must not freeze the Dock
        return el
    }
    static func value(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }
    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    static func title(_ el: AXUIElement) -> String? {
        (value(el, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Menu-bar actions

    /// Top-level menus of `app` (File, Edit, …), skipping the Apple menu.
    static func topMenus(of app: NSRunningApplication) -> [(title: String, element: AXUIElement)] {
        guard AXIsProcessTrusted(), let bar = value(element(for: app), kAXMenuBarAttribute) else { return [] }
        return children(bar as! AXUIElement).dropFirst().compactMap { item in
            title(item).map { ($0, item) }
        }
    }

    /// Run a menu command found by its title path, e.g. ["File", "Export", "PNG"].
    @discardableResult
    static func perform(path: [String], in app: NSRunningApplication) -> Bool {
        guard let first = path.first,
              var current = topMenus(of: app).first(where: { $0.title == first })?.element else { return false }
        for name in path.dropFirst() {
            guard let menu = children(current).first,
                  let next = children(menu).first(where: { title($0) == name }) else { return false }
            current = next
        }
        press(current, in: app)
        return true
    }

    static func press(_ item: AXUIElement, in app: NSRunningApplication) {
        app.activate()
        // Give the app a beat to come forward so the command targets its front window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
    }

    /// Fills NSMenus from an app's AX menus one level at a time, when each opens.
    final class MenuMirror: NSObject, NSMenuDelegate {
        private let app: NSRunningApplication
        private let source: AXUIElement           // a menu-bar item or a menu item with a submenu
        private let path: [String]
        private let onPin: ([String]) -> Void
        private var children: [MenuMirror] = []

        init(app: NSRunningApplication, source: AXUIElement, path: [String], onPin: @escaping ([String]) -> Void) {
            self.app = app; self.source = source; self.path = path; self.onPin = onPin
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard menu.items.isEmpty, let axMenu = AppControl.children(source).first else { return }
            for item in AppControl.children(axMenu) {
                guard let name = AppControl.title(item) else {
                    if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                    continue
                }
                let enabled = (AppControl.value(item, kAXEnabledAttribute) as? Bool) ?? true
                let hasSubmenu = !AppControl.children(item).isEmpty
                let mi = NSMenuItem(title: name, action: hasSubmenu ? nil : #selector(run(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = item
                mi.isEnabled = enabled
                if hasSubmenu {
                    let sub = NSMenu(title: name)
                    let child = MenuMirror(app: app, source: item, path: path + [name], onPin: onPin)
                    children.append(child)
                    sub.delegate = child
                    sub.autoenablesItems = false
                    mi.submenu = sub
                    menu.addItem(mi)
                } else {
                    Self.applyShortcut(of: item, to: mi)
                    menu.addItem(mi)
                    // Holding Option swaps the command for "Pin" (native alternate item).
                    let pin = NSMenuItem(title: "Pin “\(name)” to Dock Menu", action: #selector(pin(_:)), keyEquivalent: "")
                    pin.target = self
                    pin.representedObject = path + [name]
                    pin.isAlternate = true
                    pin.keyEquivalentModifierMask = .option
                    menu.addItem(pin)
                }
            }
            if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
            if menu.items.isEmpty { menu.addItem(withTitle: "No commands", action: nil, keyEquivalent: "").isEnabled = false }
        }

        @objc private func run(_ sender: NSMenuItem) {
            guard let el = sender.representedObject else { return }
            AppControl.press(el as! AXUIElement, in: app)
        }
        @objc private func pin(_ sender: NSMenuItem) {
            if let path = sender.representedObject as? [String] { onPin(path) }
        }

        /// Show the app's own keyboard shortcut next to the command (display only).
        private static func applyShortcut(of item: AXUIElement, to mi: NSMenuItem) {
            guard let char = AppControl.value(item, "AXMenuItemCmdChar") as? String, char.count == 1,
                  char.unicodeScalars.first!.value > 32 else { return }
            let mods = (AppControl.value(item, "AXMenuItemCmdModifiers") as? Int) ?? 0
            var mask: NSEvent.ModifierFlags = mods & 8 == 0 ? [.command] : []
            if mods & 1 != 0 { mask.insert(.shift) }
            if mods & 2 != 0 { mask.insert(.option) }
            if mods & 4 != 0 { mask.insert(.control) }
            mi.keyEquivalent = char.lowercased()
            mi.keyEquivalentModifierMask = mask
        }
    }

    /// Keeps the mirrors of the currently open Dock menu alive (NSMenu.delegate is weak).
    static var liveMirrors: [MenuMirror] = []

    /// An "App Actions" submenu mirroring `app`'s menu bar, or nil without Accessibility.
    static func actionsMenu(for app: NSRunningApplication, onPin: @escaping ([String]) -> Void) -> NSMenu? {
        let menus = topMenus(of: app)
        guard !menus.isEmpty else { return nil }
        liveMirrors.removeAll()
        let root = NSMenu(title: "App Actions")
        for (name, el) in menus {
            let mi = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: name)
            sub.autoenablesItems = false
            let mirror = MenuMirror(app: app, source: el, path: [name], onPin: onPin)
            liveMirrors.append(mirror)
            sub.delegate = mirror
            mi.submenu = sub
            root.addItem(mi)
        }
        return root
    }

    // MARK: Windows

    /// The app's standard windows (title + element), front to back.
    static func windows(of app: NSRunningApplication) -> [(title: String, element: AXUIElement)] {
        guard AXIsProcessTrusted() else { return [] }
        let list = (value(element(for: app), kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return list.compactMap { w in
            guard (value(w, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole as String else { return nil }
            let minimized = (value(w, kAXMinimizedAttribute) as? Bool) ?? false
            let name = title(w) ?? app.localizedName ?? "Window"
            return (minimized ? name + " (minimized)" : name, w)
        }
    }

    static func raise(_ window: AXUIElement, in app: NSRunningApplication) {
        if (value(window, kAXMinimizedAttribute) as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if app.isHidden { app.unhide() }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        app.activate()
    }

    /// Bring the app's next (or previous) window to the front.
    static func cycleWindows(of app: NSRunningApplication, forward: Bool) {
        let list = windows(of: app)
        guard list.count > 1 else { if let w = list.first { raise(w.element, in: app) }; return }
        // Front window is first; forward raises the backmost so repeated scrolls rotate through all.
        raise(forward ? list[list.count - 1].element : list[1].element, in: app)
    }

    // MARK: Screenshot

    /// Capture `app`'s frontmost on-screen window to the user's screenshot folder (as
    /// set in the Screenshot app). macOS asks once for Screen Recording permission.
    static func screenshotFrontWindow(of app: NSRunningApplication) {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard let win = info.first(where: {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }), let id = win[kCGWindowNumber as String] as? Int else { NSSound.beep(); return }

        let folder = (CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String)
            .map { ($0 as NSString).expandingTildeInPath } ?? (NSHomeDirectory() + "/Desktop")
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "\(app.localizedName ?? "App") \(stamp.string(from: Date())).png"
            .replacingOccurrences(of: "/", with: "-")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-l\(id)", (folder as NSString).appendingPathComponent(name)]
        try? process.run()
    }
}

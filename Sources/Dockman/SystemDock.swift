import AppKit
import ConfigKit

/// Hides/restores the built-in macOS Dock via its documented `autohide` preference
/// (docs/05 R-17). We remember the prior value so restore is exact, and a failsafe
/// "Restore System Dock" path is always available.
enum SystemDock {
    /// The system Dock's current autohide setting.
    static var autohide: Bool {
        UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
    }

    /// Hide the Dock far off-screen (autohide + a huge reveal delay so it never peeks).
    static func hide() {
        defaultsWrite(["write", "com.apple.dock", "autohide", "-bool", "true"])
        defaultsWrite(["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
        restartDock()
    }

    /// Restore to `priorAutohide` and remove our reveal-delay override.
    static func restore(priorAutohide: Bool) {
        defaultsWrite(["delete", "com.apple.dock", "autohide-delay"])
        defaultsWrite(["write", "com.apple.dock", "autohide", "-bool", priorAutohide ? "true" : "false"])
        restartDock()
    }

    private static func defaultsWrite(_ args: [String]) {
        run("/usr/bin/defaults", args)
    }
    private static func restartDock() {
        run("/usr/bin/killall", ["Dock"])
    }
    private static func run(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        try? process.run()
        process.waitUntilExit()
    }
}

/// Reads the macOS Dock's pinned apps/folders so a Dockman dock can mirror them, and
/// watches its preferences file so mirrors update the moment the macOS Dock changes.
final class SystemDockMirror {
    var onChange: (() -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private let plist = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist"

    /// The macOS Dock's layout as Dockman items: apps, the running-apps zone, folders, Trash.
    static func items() -> [DockItem] {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        func paths(_ key: String) -> [(path: String, isApp: Bool)] {
            let tiles = CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? []
            return tiles.compactMap { tile in
                guard let data = tile["tile-data"] as? [String: Any],
                      let file = data["file-data"] as? [String: Any],
                      let s = file["_CFURLString"] as? String,
                      let url = URL(string: s) ?? URL(fileURLWithPath: s) as URL? else { return nil }
                let path = url.isFileURL ? url.path : s
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return (path, (tile["tile-type"] as? String) == "file-tile" && path.hasSuffix(".app"))
            }
        }
        var items: [DockItem] = paths("persistent-apps").filter(\.isApp).map { .app(bundlePath: $0.path, label: nil) }
        items.append(.runningAppsZone)
        let others = paths("persistent-others")
        if !others.isEmpty { items.append(.separator) }
        for other in others {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: other.path, isDirectory: &isDir)
            items.append(isDir.boolValue ? .folder(path: other.path, label: nil, style: .grid) : .file(path: other.path, label: nil))
        }
        items.append(.widget(.trash))
        return items
    }

    func start() {
        guard source == nil else { return }
        let fd = open(plist, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                            queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self else { return }
            // Preferences are saved by atomic replace: re-attach to the new file.
            if let src, src.data.contains(.rename) || src.data.contains(.delete) {
                self.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.start() }
            }
            self.onChange?()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() { source?.cancel(); source = nil }
}

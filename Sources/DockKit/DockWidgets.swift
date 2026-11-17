import AppKit
import IOKit.ps
import ConfigKit

/// Live widgets (clock, battery, shelf, recent items). Updates are event-driven:
/// the clock ticks once a minute on the minute, the battery redraws only when the
/// system posts a power-source change. Nothing runs until a widget is on a Dock.
public enum DockWidgets {
    public static let changed = Notification.Name("xyz.waqas.dockman.widgetsChanged")

    // MARK: Ticker

    private static var minuteTimer: Timer?
    private static var powerSource: CFRunLoopSource?

    /// Start the shared minute tick / power notifications (idempotent).
    static func startUpdates(for kind: WidgetKind) {
        switch kind {
        case .clock where minuteTimer == nil:
            // Fire on the next minute boundary, then every 60 s.
            let next = ceil(Date().timeIntervalSinceReferenceDate / 60) * 60
            let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: next + 0.05), interval: 60, repeats: true) { _ in
                NotificationCenter.default.post(name: changed, object: WidgetKind.clock)
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            minuteTimer = timer
        case .battery where powerSource == nil:
            guard let source = IOPSNotificationCreateRunLoopSource({ _ in
                NotificationCenter.default.post(name: DockWidgets.changed, object: WidgetKind.battery)
            }, nil)?.takeRetainedValue() else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        default:
            break
        }
    }

    // MARK: Icons

    static func image(for kind: WidgetKind, size: CGFloat) -> NSImage? {
        switch kind {
        case .clock:   return tile(size: size, top: dayText(), main: timeText(), mainColor: .labelColor)
        case .battery: return batteryImage(size: size)
        default:       return nil
        }
    }

    /// Spoken description for VoiceOver.
    static func accessibilityText(for kind: WidgetKind) -> String {
        switch kind {
        case .clock:
            return "Clock, " + DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .short)
        case .battery:
            guard let b = battery() else { return "Battery, on power adapter" }
            return "Battery \(b.percent)%" + (b.charging ? ", charging" : "")
        default:
            return kind.displayName
        }
    }

    private static func timeText() -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: Date()).replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "")
    }
    private static func dayText() -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d")
        return f.string(from: Date()).uppercased()
    }

    /// A rounded tile with a small caption over a large value; drawn lazily so it
    /// follows light/dark mode.
    private static func tile(size: CGFloat, top: String, main: String, mainColor: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: size * 0.06, dy: size * 0.06)
            let path = NSBezierPath(roundedRect: inset, xRadius: size * 0.22, yRadius: size * 0.22)
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
            let center = NSMutableParagraphStyle()
            center.alignment = .center
            let small: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * 0.15, weight: .semibold),
                .foregroundColor: NSColor.systemRed, .paragraphStyle: center]
            let big: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size * 0.3, weight: .medium),
                .foregroundColor: mainColor, .paragraphStyle: center]
            (top as NSString).draw(in: NSRect(x: inset.minX, y: inset.maxY - size * 0.3, width: inset.width, height: size * 0.2), withAttributes: small)
            (main as NSString).draw(in: NSRect(x: inset.minX, y: inset.minY + size * 0.14, width: inset.width, height: size * 0.4), withAttributes: big)
            return true
        }
    }

    struct BatteryState { let percent: Int; let charging: Bool }

    static func battery() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            return BatteryState(percent: Int((Double(cur) / Double(max) * 100).rounded()), charging: charging)
        }
        return nil
    }

    private static func batteryImage(size: CGFloat) -> NSImage {
        guard let b = battery() else { return tile(size: size, top: "POWER", main: "AC", mainColor: .labelColor) }
        let color: NSColor = b.charging ? .systemGreen : (b.percent <= 20 ? .systemRed : .labelColor)
        return tile(size: size, top: b.charging ? "⚡︎ CHARGING" : "BATTERY", main: "\(b.percent)%", mainColor: color)
    }

    // MARK: Shelf (a folder of links to parked files)

    public static var shelfDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xyz.waqas.dockman/Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Park files on the shelf as symlinks (the originals never move).
    static func addToShelf(_ urls: [URL]) {
        let dir = shelfDirectory
        for url in urls {
            var dest = dir.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while (try? dest.checkResourceIsReachable()) == true || FileManager.default.destinationOfSymbolicLinkSafe(dest) != nil {
                dest = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n)")
                    .appendingPathExtension(url.pathExtension)
                n += 1
            }
            try? FileManager.default.createSymbolicLink(at: dest, withDestinationURL: url)
        }
    }

    static func clearShelf() {
        let dir = shelfDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))   // removes the link only
        }
    }

    // MARK: Recent items (Spotlight's last-used dates; no extra permission)

    private static var query: NSMetadataQuery?
    private static var queryToken: NSObjectProtocol?

    static func recentItems(limit: Int = 24, completion: @escaping ([URL]) -> Void) {
        query?.stop()
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@", Date().addingTimeInterval(-7 * 86_400) as NSDate)
        q.searchScopes = [NSMetadataQueryLocalComputerScope]
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        if let queryToken { NotificationCenter.default.removeObserver(queryToken) }
        queryToken = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in
            q.stop()
            var urls: [URL] = []
            for i in 0..<q.resultCount where urls.count < limit {
                guard let item = q.result(at: i) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      !path.contains("/Library/"), !path.contains("/."),
                      FileManager.default.fileExists(atPath: path) else { continue }
                urls.append(URL(fileURLWithPath: path))
            }
            completion(urls)
        }
        query = q
        q.start()
    }

    // MARK: Click actions

    static func open(_ kind: WidgetKind) {
        switch kind {
        case .clock:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        case .battery:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        case .trash:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
        case .shelf, .recents:
            break   // shown as popovers by DockContentView
        }
    }
}

private extension FileManager {
    /// Non-nil when `url` is a symlink (even a dangling one).
    func destinationOfSymbolicLinkSafe(_ url: URL) -> String? { try? destinationOfSymbolicLink(atPath: url.path) }
}

import AppKit

/// ⌃⌥Space: a small Spotlight-style box to find and launch apps and Dock items by
/// typing. A non-activating panel, so the app you were in stays frontmost.
public final class SearchPanel: NSObject, NSSearchFieldDelegate {
    public static let shared = SearchPanel()

    private let panel: NSPanel
    private let field = NSSearchField()
    private let list = NSStackView()
    private var candidates: [URL] = []
    private var results: [URL] = []
    private var selected = 0
    private let maxResults = 8

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 60),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true

        field.placeholderString = "Open app or Dock item…"
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("Search apps and Dock items")
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2

        let column = NSStackView(views: [field, list])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        column.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            column.topAnchor.constraint(equalTo: bg.topAnchor),
            column.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 416),
        ])
        panel.contentView = bg
    }

    /// Show the box, searching `dockItems` (paths) first, then every installed app.
    public func show(dockItems: [String]) {
        if panel.isVisible { close(); return }
        candidates = Self.uniqued(dockItems.map { URL(fileURLWithPath: $0) } + Self.installedApps())
        field.stringValue = ""
        update()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 220, y: f.minY + f.height * 0.72))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func close() { panel.orderOut(nil) }

    // MARK: Matching

    private func update() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            results = []
        } else {
            // Prefix of the name, then prefix of any word, then anywhere — Dock items first within each.
            func score(_ url: URL) -> Int? {
                let name = Self.name(url).lowercased()
                if name.hasPrefix(q) { return 0 }
                if name.split(whereSeparator: { $0 == " " || $0 == "-" }).contains(where: { $0.hasPrefix(q) }) { return 1 }
                return name.contains(q) ? 2 : nil
            }
            results = candidates.enumerated()
                .compactMap { i, url in score(url).map { (rank: $0, i: i, url: url) } }
                .sorted { ($0.rank, $0.i) < ($1.rank, $1.i) }
                .prefix(maxResults).map(\.url)
        }
        selected = 0
        render()
    }

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, url) in results.enumerated() {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 24, height: 24)
            let row = NSButton(title: "  " + Self.name(url), image: icon, target: self, action: #selector(pick(_:)))
            row.tag = i
            row.imagePosition = .imageLeading
            row.alignment = .left
            row.isBordered = false
            row.lineBreakMode = .byTruncatingTail
            row.font = .systemFont(ofSize: 14, weight: i == selected ? .semibold : .regular)
            row.wantsLayer = true
            row.layer?.cornerRadius = 6
            row.layer?.backgroundColor = i == selected ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil
            row.setAccessibilityLabel(Self.name(url))
            row.widthAnchor.constraint(equalToConstant: 416).isActive = true
            row.heightAnchor.constraint(equalToConstant: 30).isActive = true
            list.addArrangedSubview(row)
        }
        list.isHidden = results.isEmpty
        if let first = results[safe: selected] {
            NSAccessibility.post(element: field, notification: .announcementRequested,
                                 userInfo: [.announcement: Self.name(first), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        let height = 44 + 24 + (results.isEmpty ? 0 : CGFloat(results.count) * 32 + 8)
        var frame = panel.frame
        frame.origin.y += frame.height - height       // grow downward from the top edge
        frame.size = NSSize(width: 440, height: height)
        panel.setFrame(frame, display: true)
    }

    @objc private func pick(_ sender: NSButton) { launch(sender.tag) }

    private func launch(_ index: Int) {
        guard let url = results[safe: index] else { NSSound.beep(); return }
        close()
        NSWorkspace.shared.open(url)
    }

    // MARK: Field delegate

    public func controlTextDidChange(_ obj: Notification) { update() }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if !results.isEmpty { selected = (selected + 1) % results.count; render() }
        case #selector(NSResponder.moveUp(_:)):
            if !results.isEmpty { selected = (selected - 1 + results.count) % results.count; render() }
        case #selector(NSResponder.insertNewline(_:)):
            launch(selected)
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    // MARK: Sources

    static func name(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Apps in the standard folders (one level deep, plus Utilities). Read fresh on each open.
    static func installedApps() -> [URL] {
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        return roots.flatMap { root in
            ((try? fm.contentsOfDirectory(atPath: root)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: root).appendingPathComponent($0) }
        }
    }

    private static func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

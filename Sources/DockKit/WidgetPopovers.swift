import AppKit
import EventKit

/// Popover contents for the Clipboard History, Quick Notes and Next Event widgets.
enum WidgetPopovers {

    /// Recent clipboard texts; clicking one copies it back, ready to paste.
    static func clipboard(close: @escaping () -> Void) -> NSView {
        let entries = DockWidgets.clipboardHistory
        let rows: [NSView] = entries.isEmpty
            ? [note("Copied text appears here. Nothing is saved to disk.")]
            : entries.map { text in
                let title = text.replacingOccurrences(of: "\n", with: " ")
                return ActionRow(title: String(title.prefix(70)) + (title.count > 70 ? "…" : ""), help: text) {
                    DockWidgets.restoreClipboard(text)
                    close()
                }
            }
        var footer: [NSView] = []
        if !entries.isEmpty {
            footer = [ActionRow(title: "Clear History", symbol: "trash", help: "Forget all entries") {
                DockWidgets.clearClipboardHistory()
                close()
            }]
        }
        return list(title: "Clipboard", rows: rows + footer)
    }

    /// A small text area saved to Notes.txt as you type.
    static func notes() -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
        scroll.borderType = .noBorder
        let text = scroll.documentView as! NSTextView
        text.font = .systemFont(ofSize: 13)
        text.isRichText = false
        text.allowsUndo = true
        let url = DockWidgets.notesURL
        let saved = try? String(contentsOf: url, encoding: .utf8)
        text.string = saved ?? ""
        text.setAccessibilityLabel("Quick notes")
        // A file that exists but isn't UTF-8 is shown read-only so typing can't overwrite it.
        if saved == nil, FileManager.default.fileExists(atPath: url.path) {
            text.isEditable = false
            text.string = "Notes.txt couldn't be read as text, so it was left untouched."
        } else {
            let saver = NotesSaver(textView: text)
            text.delegate = saver
            objc_setAssociatedObject(text, &NotesSaver.key, saver, .OBJC_ASSOCIATION_RETAIN)
        }
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        scroll.frame = box.bounds.insetBy(dx: 10, dy: 10)
        scroll.autoresizingMask = [.width, .height]
        box.addSubview(scroll)
        box.widthAnchor.constraint(equalToConstant: 320).isActive = true
        box.heightAnchor.constraint(equalToConstant: 240).isActive = true
        DispatchQueue.main.async { text.window?.makeFirstResponder(text) }
        return box
    }

    /// Remaining events today and tomorrow; click one to open Calendar.
    static func calendar(close: @escaping () -> Void) -> NSView {
        let events = DockWidgets.upcomingEvents()
        let openCalendar = { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")); close() }
        let rows: [NSView]
        if events.isEmpty {
            rows = [note(EKEventStore.authorizationStatus(for: .event) == .fullAccess
                         ? "Nothing else scheduled today or tomorrow."
                         : "Allow Calendar access in System Settings ▸ Privacy & Security ▸ Calendars.")]
        } else {
            rows = events.map { e in ActionRow(title: DockWidgets.eventLine(e), help: e.location, action: openCalendar) }
        }
        return list(title: "Upcoming", rows: rows + [ActionRow(title: "Open Calendar", symbol: "calendar", action: openCalendar)])
    }

    // MARK: Building blocks

    private static func list(title: String, rows: [NSView]) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return stack
    }

    private static func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 290
        return label
    }

    /// A full-width, hover-highlighted row button.
    final class ActionRow: NSButton {
        private let run: () -> Void
        init(title: String, symbol: String? = nil, help: String? = nil, action: @escaping () -> Void) {
            run = action
            super.init(frame: .zero)
            self.title = title
            image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            imagePosition = .imageLeading
            alignment = .left
            isBordered = false
            lineBreakMode = .byTruncatingTail
            toolTip = help
            target = self
            self.action = #selector(fire)
            wantsLayer = true
            layer?.cornerRadius = 6
            translatesAutoresizingMaskIntoConstraints = false
            widthAnchor.constraint(equalToConstant: 296).isActive = true
            heightAnchor.constraint(equalToConstant: 26).isActive = true
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                           owner: self, userInfo: nil))
        }
        required init?(coder: NSCoder) { fatalError() }
        @objc private func fire() { run() }
        override func mouseEntered(with event: NSEvent) {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        }
        override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    }

    /// Saves the notes a moment after typing stops (no write per keystroke).
    private final class NotesSaver: NSObject, NSTextViewDelegate {
        static var key = 0
        weak var textView: NSTextView?
        private var pending: DispatchWorkItem?
        init(textView: NSTextView) { self.textView = textView }
        func textDidChange(_ notification: Notification) {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let text = self?.textView?.string else { return }
                try? text.write(to: DockWidgets.notesURL, atomically: true, encoding: .utf8)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        // Flush anything typed in the last moment, when the popover closes.
        func textDidEndEditing(_ notification: Notification) {
            pending?.cancel()
            if let text = textView?.string { try? text.write(to: DockWidgets.notesURL, atomically: true, encoding: .utf8) }
        }
    }
}

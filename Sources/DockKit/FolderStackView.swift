import AppKit
import ConfigKit

/// Popover contents for a folder stack (or any list of files): a grid of entries;
/// clicking one opens it, dragging one out drops the real file elsewhere (docs/04 §4.2).
public final class FolderStackView: NSView {
    public var onOpen: ((URL) -> Void)?
    /// An entry was dragged out and dropped somewhere (the shelf uses this to un-park it).
    public var onDraggedOut: ((URL) -> Void)?
    private let emptyText: String

    public convenience init(path: String, style: FolderStyle, emptyText: String = "Empty folder") {
        self.init(urls: FolderContents.entries(at: path, limit: 60), style: style, emptyText: emptyText)
    }

    public init(urls: [URL], style: FolderStyle, emptyText: String = "Empty folder") {
        self.emptyText = emptyText
        super.init(frame: .zero)
        build(entries: urls, style: style)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build(entries: [URL], style: FolderStyle) {
        let cols = style == .list ? 1 : min(6, max(1, Int(Double(entries.count).squareRootRoundedUp())))
        let iconSize: CGFloat = style == .list ? 24 : 44
        let cellW: CGFloat = style == .list ? 220 : 72
        let cellH: CGFloat = style == .list ? 30 : 72
        let pad: CGFloat = 12

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 6

        var row: [NSView] = []
        func flushRow() {
            while row.count < cols { row.append(NSView()) }
            grid.addRow(with: row)
            row.removeAll()
        }
        if entries.isEmpty {
            let empty = NSTextField(labelWithString: emptyText)
            empty.textColor = .secondaryLabelColor
            grid.addRow(with: [empty])
        } else {
            for url in entries {
                row.append(makeEntry(url: url, iconSize: iconSize, w: cellW, h: cellH, list: style == .list))
                if row.count == cols { flushRow() }
            }
            if !row.isEmpty { flushRow() }
        }

        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])
    }

    private func makeEntry(url: URL, iconSize: CGFloat, w: CGFloat, h: CGFloat, list: Bool) -> NSView {
        let button = StackEntryButton(title: url.lastPathComponent, target: self, action: #selector(open(_:)))
        button.onDraggedOut = { [weak self] in self?.onDraggedOut?(url) }
        button.identifier = NSUserInterfaceItemIdentifier(url.path)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: iconSize, height: iconSize)
        button.image = icon
        button.imagePosition = list ? .imageLeading : .imageAbove
        button.bezelStyle = .smallSquare
        button.isBordered = false
        button.lineBreakMode = .byTruncatingTail
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: w).isActive = true
        button.heightAnchor.constraint(equalToConstant: h).isActive = true
        return button
    }

    @objc private func open(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onOpen?(URL(fileURLWithPath: path))
    }
}

/// A stack entry that opens on click and can be dragged out as the real file.
private final class StackEntryButton: NSButton, NSDraggingSource {
    var onDraggedOut: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let window, let path = identifier?.rawValue,
              let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { return }
        guard next.type == .leftMouseDragged else { sendAction(action, to: target); return }
        // Links (shelf entries) drag their original file.
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { onDraggedOut?() }
    }
}

private extension Double {
    func squareRootRoundedUp() -> Int { Int(self.squareRoot().rounded(.up)) }
}

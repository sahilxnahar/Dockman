import AppKit
import ConfigKit

/// Renders a Dock's items as a row of cells over a frosted background, with running
/// indicators, a dynamic running-apps zone, folder-stack popovers, drag-and-drop
/// (reorder + drop-from-Finder), and per-item context menus (docs/04 §4).
public final class DockContentView: NSView {
    /// app/file/zone-app item activated.
    public var onActivateItem: ((DockItem) -> Void)?
    /// an action item fired.
    public var onRunAction: ((DockAction) -> Void)?
    /// items changed via add/remove/reorder — persist upstream.
    public var onItemsChanged: (([DockItem]) -> Void)?
    /// user set (or cleared, nil) a custom icon for the item at `path` — persist upstream.
    public var onCustomIconChanged: ((_ path: String, _ spec: String?) -> Void)?
    /// Per-item icon overrides keyed by path (see `DockModel.customIcons`).
    public var customIcons: [String: String] = [:]
    /// Folded to a single expand button (see `Behavior.collapsed`).
    public var collapsed = false
    /// user asked to collapse/expand the Dock — persist upstream.
    public var onToggleCollapsed: (() -> Void)?
    private var renderedCollapsed: Bool?

    static let gap: CGFloat = 8
    static let internalType = NSPasteboard.PasteboardType("xyz.waqas.dockman.itemindex")

    private let contentHolder = NSView()
    let stack = NSStackView()
    private var styleWrapper: NSView?
    private(set) var items: [DockItem] = []
    private var iconSize: CGFloat = 52
    private var padding: CGFloat = CGFloat(Appearance.defaultPadding)
    private(set) var vertical = false
    private(set) var edge: Appearance.Edge = .bottom
    private var magnify = false
    private var magnifyScale: CGFloat = CGFloat(Appearance.defaultMagnificationScale)
    var folderPopover: NSPopover?
    private var magnifyTracking: NSTrackingArea?
    /// Bar-region pins for `contentHolder`, rebuilt when edge/headroom change.
    private var holderConstraints: [NSLayoutConstraint] = []

    // Track applied appearance so we only rebuild the background when it changes.
    private var appliedStyle: Appearance.Style?
    private var appliedTint: String?
    private var appliedReduceTransparency = false
    private var appliedEdge: Appearance.Edge?
    private var appliedMagnify: Bool?
    private var appliedMagnifyScale: CGFloat?
    private var cornerRadius = CGFloat(Appearance.defaultCornerRadius)
    private var backgroundOpacity: CGFloat = 1
    private var appliedCorner: CGFloat?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        stack.orientation = .horizontal
        stack.spacing = Self.gap
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        // contentHolder lives directly on `self` (a sibling above the background
        // slab) so magnified icons can overflow the bar into the headroom without
        // being clipped by the slab's rounded-corner mask.
        contentHolder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentHolder)
        contentHolder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentHolder.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentHolder.centerYAnchor),
        ])
        pinToBarRegion(contentHolder, headroom: 0)
        registerForDraggedTypes([.fileURL, Self.internalType])
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Dockman dock")
    }

    /// Pin `view` to the bar sub-region of `self`: full length along the bar,
    /// `barThickness == self.thickness - headroom` against the screen-edge side,
    /// leaving `headroom` of transparent space on the inward side for magnified
    /// icons to grow into. headroom == 0 ⇒ fills the whole view (the non-magnified
    /// layout, byte-identical to before).
    private func pinToBarRegion(_ view: NSView, headroom: CGFloat) {
        let isHolder = (view === contentHolder)
        if isHolder { NSLayoutConstraint.deactivate(holderConstraints) }
        let c: [NSLayoutConstraint]
        switch edge {
        case .bottom:
            c = [view.leadingAnchor.constraint(equalTo: leadingAnchor),
                 view.trailingAnchor.constraint(equalTo: trailingAnchor),
                 view.bottomAnchor.constraint(equalTo: bottomAnchor),
                 view.topAnchor.constraint(equalTo: topAnchor, constant: headroom)]
        case .top:
            c = [view.leadingAnchor.constraint(equalTo: leadingAnchor),
                 view.trailingAnchor.constraint(equalTo: trailingAnchor),
                 view.topAnchor.constraint(equalTo: topAnchor),
                 view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -headroom)]
        case .left:
            c = [view.topAnchor.constraint(equalTo: topAnchor),
                 view.bottomAnchor.constraint(equalTo: bottomAnchor),
                 view.leadingAnchor.constraint(equalTo: leadingAnchor),
                 view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -headroom)]
        case .right:
            c = [view.topAnchor.constraint(equalTo: topAnchor),
                 view.bottomAnchor.constraint(equalTo: bottomAnchor),
                 view.trailingAnchor.constraint(equalTo: trailingAnchor),
                 view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: headroom)]
        }
        NSLayoutConstraint.activate(c)
        if isHolder { holderConstraints = c }
    }

    // MARK: - Background style

    private func applyStyle(_ style: Appearance.Style, tintHex: String?, headroom: CGFloat) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        // Reduced-transparency: substitute translucent styles with a solid slab.
        let effective: Appearance.Style = (reduce && (style == .liquidGlass || style == .classic)) ? .solid : style

        styleWrapper?.removeFromSuperview()

        let tint = tintHex.flatMap { NSColor(hex: $0) }
        // Never round past half the bar's thickness, or the corners would pinch.
        let thickness = iconSize + DockItemCell.dotZone + padding * 2
        let radius = min(cornerRadius, thickness / 2)
        // Background-only slab. The icons live in `contentHolder`, a sibling
        // *above* this wrapper, so the wrapper's rounded-corner clipping never
        // touches a magnified icon that has grown past the bar.
        let wrapper: NSView

        switch effective {
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.cornerRadius = radius
                glass.tintColor = tint
                glass.contentView = NSView()           // decorative slab; icons sit on top
                wrapper = glass
            } else {
                wrapper = makeVisualEffect(radius: radius)
            }
        case .classic:
            wrapper = makeVisualEffect(radius: radius)
        case .solid:
            let v = NSView(); v.wantsLayer = true
            v.layer?.backgroundColor = (tint ?? .windowBackgroundColor).withAlphaComponent(0.96).cgColor
            v.layer?.cornerRadius = radius
            v.layer?.masksToBounds = true
            wrapper = v
        case .minimal:
            wrapper = NSView()
        }

        wrapper.alphaValue = backgroundOpacity
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wrapper, positioned: .below, relativeTo: contentHolder)
        pinToBarRegion(wrapper, headroom: headroom)
        pinToBarRegion(contentHolder, headroom: headroom)
        styleWrapper = wrapper
        appliedStyle = style
        appliedTint = tintHex
        appliedReduceTransparency = reduce
        appliedEdge = edge
        appliedMagnify = magnify
        appliedMagnifyScale = magnifyScale
        appliedCorner = radius
    }

    private func makeVisualEffect(radius: CGFloat) -> NSVisualEffectView {
        let e = NSVisualEffectView()
        e.material = .hudWindow
        e.blendingMode = .behindWindow
        e.state = .active
        e.wantsLayer = true
        e.layer?.cornerRadius = radius
        e.layer?.masksToBounds = true
        return e
    }

    public func configure(items: [DockItem], iconSize: CGFloat, running: [RunningAppInfo],
                          vertical: Bool = false, maxLength: CGFloat = .greatestFiniteMagnitude,
                          style: Appearance.Style = .classic, tintHex: String? = nil,
                          edge: Appearance.Edge = .bottom, magnify: Bool = false,
                          magnifyScale: CGFloat = CGFloat(Appearance.defaultMagnificationScale),
                          padding: CGFloat = CGFloat(Appearance.defaultPadding),
                          cornerRadius: CGFloat = CGFloat(Appearance.defaultCornerRadius),
                          backgroundOpacity: CGFloat = 1) {
        self.cornerRadius = cornerRadius
        self.backgroundOpacity = backgroundOpacity
        self.items = items
        self.iconSize = iconSize
        self.vertical = vertical
        self.edge = edge
        self.magnify = magnify
        self.magnifyScale = magnifyScale
        self.padding = padding

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let headroom = Magnifier.headroom(iconSize: iconSize, enabled: magnify, maxScale: magnifyScale)
        if style != appliedStyle || tintHex != appliedTint || reduce != appliedReduceTransparency
            || edge != appliedEdge || magnify != appliedMagnify || magnifyScale != appliedMagnifyScale
            || min(cornerRadius, (iconSize + DockItemCell.dotZone + padding * 2) / 2) != appliedCorner {
            applyStyle(style, tintHex: tintHex, headroom: headroom)
        }
        styleWrapper?.alphaValue = backgroundOpacity
        updateTrackingAreas()   // install/tear down the cursor-move area as magnify toggles

        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .centerX : .centerY
        if let renderedCollapsed, renderedCollapsed != collapsed,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()                     // crossfade between bar and button
            fade.type = .fade
            fade.duration = 0.2
            contentHolder.wantsLayer = true
            contentHolder.layer?.add(fade, forKey: "collapse")
        }
        renderedCollapsed = collapsed
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if collapsed {
            stack.addArrangedSubview(makeExpandButton())
            return
        }

        let runningPaths = Set(running.compactMap { $0.bundlePath })
        let pinnedPaths = Set(items.compactMap { $0.appPath })

        // Budget so the Dock never grows past its display (docs/05 R-7). Pinned items
        // always show; the dynamic running-apps zone fills whatever room is left.
        let budget = maxLength.isFinite ? maxLength - lengthPad * 2 : .greatestFiniteMagnitude
        let separatorLen = DockGapCell.separatorLength
        // A cell is iconSize wide but iconSize+10 tall (the running-indicator dot), so
        // its length along the stack axis differs between orientations.
        let cellLen = vertical ? iconSize + DockItemCell.dotZone : iconSize
        var used: CGFloat = 0
        func wouldFit(_ length: CGFloat) -> Bool {
            used + (used > 0 ? Self.gap : 0) + length <= budget
        }
        func consume(_ length: CGFloat) { used += (used > 0 ? Self.gap : 0) + length }

        for (index, item) in items.enumerated() {
            switch item {
            case .app, .file, .folder, .action, .widget:
                stack.addArrangedSubview(makeCell(item: item, modelIndex: index, running: runningPaths))
                consume(cellLen)
            case .separator:
                stack.addArrangedSubview(makeGapCell(item: item, modelIndex: index, length: separatorLen))
                consume(separatorLen)
            case .spacer(let points):
                stack.addArrangedSubview(makeGapCell(item: item, modelIndex: index, length: CGFloat(points)))
                consume(CGFloat(points))
            case .runningAppsZone:
                let zoneApps = RunningZone.apps(running: running, pinnedAppPaths: pinnedPaths)
                if (!pinnedPaths.isEmpty || !zoneApps.isEmpty), wouldFit(separatorLen) {
                    stack.addArrangedSubview(makeZoneDivider()); consume(separatorLen)
                }
                for app in zoneApps {
                    guard let path = app.bundlePath else { continue }
                    guard wouldFit(cellLen) else { break }   // stop when out of room
                    let synthetic = DockItem.app(bundlePath: path, label: app.name)
                    let cell = makeCell(item: synthetic, modelIndex: nil, running: runningPaths)
                    cell.isRunning = true
                    stack.addArrangedSubview(cell)
                    consume(cellLen)
                }
            }
        }
    }

    /// Margin at the bar's two ends (along its length). Slightly larger than the
    /// cross-axis margin so the first/last icons don't look cramped against the
    /// rounded corners.
    private var lengthPad: CGFloat { padding + 2 }

    public func fittingSize() -> NSSize {
        stack.layoutSubtreeIfNeeded()
        let inner = stack.fittingSize
        let lengthMin = iconSize + lengthPad * 2
        let crossMin = iconSize + padding * 2
        var size = vertical
            ? NSSize(width: max(inner.width + padding * 2, crossMin),
                     height: max(inner.height + lengthPad * 2, lengthMin))
            : NSSize(width: max(inner.width + lengthPad * 2, lengthMin),
                     height: max(inner.height + padding * 2, crossMin))
        // Reserve room on the cross axis so the peak magnified icon clears the bar.
        let headroom = Magnifier.headroom(iconSize: iconSize, enabled: magnify, maxScale: magnifyScale)
        if vertical { size.width += headroom } else { size.height += headroom }
        return size
    }

    // MARK: - Magnification

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let magnifyTracking { removeTrackingArea(magnifyTracking) }
        magnifyTracking = nil
        guard magnify else { return }
        // .activeAlways + .mouseMoved so the non-activating Dock panel still gets
        // moves while another app is key.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        magnifyTracking = area
    }

    public override func mouseMoved(with event: NSEvent) {
        guard magnify else { return }
        magnify(towardCursor: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        guard magnify else { return }
        for case let cell as DockItemCell in stack.arrangedSubviews { cell.setMagnification(1) }
    }

    private func magnify(towardCursor p: NSPoint) {
        let cursor = vertical ? p.y : p.x
        let stride = iconSize + Self.gap
        for case let cell as DockItemCell in stack.arrangedSubviews {
            let f = cell.convert(cell.bounds, to: self)
            let center = vertical ? f.midY : f.midX
            cell.setMagnification(Magnifier.scale(distance: cursor - center, stride: stride,
                                                  maxScale: magnifyScale))
        }
    }

    // MARK: Cell construction

    private func makeCell(item: DockItem, modelIndex: Int?, running: Set<String>) -> DockItemCell {
        let cell = DockItemCell(item: item, modelIndex: modelIndex, iconSize: iconSize, edge: edge,
                                customIcon: item.path.flatMap { customIcons[$0] })
        cell.magnificationEnabled = magnify
        if let path = item.path { cell.isRunning = running.contains(path) }
        if let path = item.appPath { cell.badgeText = DockBadges.current[URL(fileURLWithPath: path).standardizedFileURL.path] }
        cell.onActivate = { [weak self, weak cell] in
            guard let self, let cell else { return }
            self.activate(item: item, from: cell)
        }
        cell.onContextMenu = { [weak self, weak cell] event in
            guard let self, let cell else { return }
            self.showContextMenu(for: cell, event: event)
        }
        cell.onBeginDrag = { [weak self] cell, event in
            self?.beginReorderDrag(cell: cell, event: event)
        }
        return cell
    }

    /// A user-managed separator or spacer: draggable to reorder, right-click to remove.
    private func makeGapCell(item: DockItem, modelIndex: Int, length: CGFloat) -> DockGapCell {
        let cell = DockGapCell(item: item, modelIndex: modelIndex,
                               length: max(length, 1), cross: iconSize * 0.7, vertical: vertical)
        cell.onContextMenu = { [weak self, weak cell] event in
            guard let self, let cell else { return }
            self.showGapContextMenu(for: cell, event: event)
        }
        cell.onBeginDrag = { [weak self] cell, event in
            self?.beginReorderDrag(view: cell, modelIndex: cell.modelIndex, event: event)
        }
        return cell
    }

    /// The lone button a collapsed Dock shows; its chevron points into the screen.
    private func makeExpandButton() -> NSButton {
        let symbol: String
        switch edge {
        case .bottom: symbol = "chevron.compact.up"
        case .top:    symbol = "chevron.compact.down"
        case .left:   symbol = "chevron.compact.right"
        case .right:  symbol = "chevron.compact.left"
        }
        let config = NSImage.SymbolConfiguration(pointSize: iconSize * 0.4, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Expand Dock")?
            .withSymbolConfiguration(config) ?? NSImage()
        let button = NSButton(image: image, target: self, action: #selector(toggleCollapsed))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel("Expand Dock")
        button.toolTip = "Expand Dock"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: iconSize + DockItemCell.dotZone).isActive = true
        return button
    }

    @objc func toggleCollapsed() {
        HoverLabel.shared.hide()
        onToggleCollapsed?()
    }

    /// The synthetic hairline before the running-apps zone. Not a model item, so inert.
    private func makeZoneDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        // A horizontal stack needs a vertical separator and vice-versa.
        if vertical {
            box.widthAnchor.constraint(equalToConstant: iconSize * 0.7).isActive = true
        } else {
            box.heightAnchor.constraint(equalToConstant: iconSize * 0.7).isActive = true
        }
        return box
    }

    // MARK: Activation

    func activate(item: DockItem, from cell: DockItemCell) {
        switch item {
        case .folder(let path, _, let style):
            showFolderPopover(path: path, style: style, from: cell)
        case .action(let action):
            onRunAction?(action)
        case .widget(.shelf):
            let stack = FolderStackView(path: DockWidgets.shelfDirectory.path, style: .grid,
                                        emptyText: "Drop files here to park them")
            stack.onDraggedOut = { [weak self] link in
                try? FileManager.default.removeItem(at: link)   // un-park: removes the link only
                self?.folderPopover?.performClose(nil)
            }
            showStack(stack, from: cell)
        case .widget(.recents):
            DockWidgets.recentItems { [weak self, weak cell] urls in
                guard let self, let cell, cell.window != nil else { return }
                self.showStack(FolderStackView(urls: urls, style: .list, emptyText: "Nothing opened recently"), from: cell)
            }
        case .widget(let kind):
            DockWidgets.open(kind)
        case .app where Self.runningApp(for: item) == nil:
            cell.startBounce()
            onActivateItem?(item)
        default:
            onActivateItem?(item)
        }
    }

    private func showFolderPopover(path: String, style: FolderStyle, from cell: NSView) {
        showStack(FolderStackView(path: path, style: style), from: cell)
    }

    func showStack(_ content: FolderStackView, from cell: NSView) {
        folderPopover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        content.onOpen = { [weak popover] url in
            NSWorkspace.shared.open(url)
            popover?.performClose(nil)
        }
        let vc = NSViewController()
        vc.view = content
        popover.contentViewController = vc
        content.layoutSubtreeIfNeeded()
        popover.contentSize = content.fittingSize
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: cell.bounds, of: cell, preferredEdge: Self.inwardEdge(edge))
        folderPopover = popover
    }

    /// Insertion index in `items` for a drop at `cursor` along the length axis.
    /// Collects (modelIndex, center) for every rendered model item — icons AND
    /// separators/spacers — so the index is correct even with gaps in the row.
    func insertionIndex(at cursor: CGFloat) -> Int {
        var centers: [(index: Int, center: CGFloat)] = []
        for view in stack.arrangedSubviews {
            let modelIndex: Int?
            if let cell = view as? DockItemCell { modelIndex = cell.modelIndex }
            else if let gap = view as? DockGapCell { modelIndex = gap.modelIndex }
            else { modelIndex = nil }
            guard let modelIndex else { continue }   // zone-synthetic cells / zone divider
            let f = view.convert(view.bounds, to: self)
            centers.append((modelIndex, vertical ? f.midY : f.midX))
        }
        return Self.insertionIndex(cursor: cursor, centers: centers,
                                   descending: vertical, itemCount: items.count)
    }

    /// Pure insertion computation (unit-tested): the model index of the first item
    /// the cursor sits *before*, else `itemCount` (append). `centers` must be in
    /// model order. `descending` is true for vertical docks, whose first item has
    /// the LARGEST Cocoa y (the stack lays out top-down while y grows upward).
    static func insertionIndex(cursor: CGFloat, centers: [(index: Int, center: CGFloat)],
                               descending: Bool, itemCount: Int) -> Int {
        for (index, center) in centers {
            let cursorIsBefore = descending ? cursor > center : cursor < center
            if cursorIsBefore { return index }
        }
        return itemCount
    }
}

extension DockContentView: NSDraggingSource {
    public func draggingSession(_ session: NSDraggingSession,
                                sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }
}

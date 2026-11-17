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
    /// Per-app preferences (pinned commands, …) keyed by bundle path.
    public var appPrefs: [String: AppPrefs] = [:]
    /// user changed an app's preferences from the Dock menu — persist upstream.
    public var onAppPrefsChanged: ((_ appPath: String, _ prefs: AppPrefs) -> Void)?
    /// Folded to a single expand button (see `Behavior.collapsed`).
    public var collapsed = false
    /// user asked to collapse/expand the Dock — persist upstream.
    public var onToggleCollapsed: (() -> Void)?
    private var renderedCollapsed: Bool?
    /// Number of rows (columns on a side dock); >1 wraps items instead of one long bar.
    public var rows = 1
    /// Per-dock motion style, handed to each cell.
    public var hoverEffect: Appearance.HoverEffect = .grow
    public var launchEffect: Appearance.LaunchEffect = .bounce
    public var motionSpeed: CGFloat = 1
    /// The row stacks inside `stack` (one per row).
    private var rowStacks: [NSStackView] { stack.arrangedSubviews.compactMap { $0 as? NSStackView } }
    /// Every rendered cell across all rows, in model order.
    var allCells: [NSView] { rowStacks.flatMap(\.arrangedSubviews) }
    /// Layout frozen: no reordering by drag.
    public var locked = false
    /// Click action "Bring Windows Here" for one app, regardless of the dock's setting.
    public var onSummonApp: ((String) -> Void)?
    /// Keyboard navigation state (see DockContentView+Keyboard).
    var keyboardIndex: Int?
    var typeBuffer = ""
    var lastTypeTime = Date.distantPast
    public var onKeyboardFocusEnded: (() -> Void)?
    public var onFocusNextDock: (() -> Void)?
    var activeAppPath: String?
    private var appliedHighContrast: Bool?
    var scrollAccum: CGFloat = 0
    var lastCycle = Date.distantPast

    static let gap: CGFloat = 8
    static let internalType = NSPasteboard.PasteboardType("xyz.waqas.dockman.itemindex")

    private let contentHolder = NSView()
    let stack = NSStackView()
    private var styleWrapper: NSView?
    private(set) var items: [DockItem] = []
    private(set) var iconSize: CGFloat = 52
    private var padding: CGFloat = CGFloat(Appearance.defaultPadding)
    private(set) var vertical = false
    private(set) var edge: Appearance.Edge = .bottom
    private(set) var magnify = false
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

    public override var acceptsFirstResponder: Bool { keyboardIndex != nil }
    public override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }
    public override func resignFirstResponder() -> Bool {
        endKeyboardFocus(returnToApp: false)
        return super.resignFirstResponder()
    }

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

        // High contrast: an outline so the bar's edge is clear on any wallpaper.
        appliedHighContrast = DockAccess.highContrast
        if DockAccess.highContrast, effective != .minimal {
            wrapper.wantsLayer = true
            wrapper.layer?.borderWidth = 2
            wrapper.layer?.borderColor = NSColor.labelColor.cgColor
            wrapper.layer?.cornerRadius = radius
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
        let magnify = magnify && rows <= 1        // magnification is a single-row effect
        self.magnify = magnify
        self.magnifyScale = magnifyScale
        self.padding = padding

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let headroom = Magnifier.headroom(iconSize: iconSize, enabled: magnify, maxScale: magnifyScale)
        if style != appliedStyle || tintHex != appliedTint || reduce != appliedReduceTransparency
            || edge != appliedEdge || magnify != appliedMagnify || magnifyScale != appliedMagnifyScale
            || min(cornerRadius, (iconSize + DockItemCell.dotZone + padding * 2) / 2) != appliedCorner
            || DockAccess.highContrast != appliedHighContrast {
            applyStyle(style, tintHex: tintHex, headroom: headroom)
        }
        styleWrapper?.alphaValue = DockAccess.highContrast ? 1 : backgroundOpacity
        updateTrackingAreas()   // install/tear down the cursor-move area as magnify toggles

        // `stack` holds the rows; rows run along the edge, so the stack runs across it.
        stack.orientation = vertical ? .horizontal : .vertical
        stack.alignment = vertical ? .centerY : .centerX
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
        var views: [NSView] = []
        defer { layoutRows(views) }
        if collapsed {
            views.append(makeExpandButton())
            return
        }

        let runningPaths = Set(running.compactMap { $0.bundlePath })
        activeAppPath = running.first(where: \.isActive)?.bundlePath
        let pinnedPaths = Set(items.compactMap { $0.appPath })

        // Budget so the Dock never grows past its display (docs/05 R-7). Pinned items
        // always show; the dynamic running-apps zone fills whatever room is left.
        let budget = maxLength.isFinite ? (maxLength - lengthPad * 2) * CGFloat(max(rows, 1)) : .greatestFiniteMagnitude
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
                views.append(makeCell(item: item, modelIndex: index, running: runningPaths))
                consume(cellLen)
            case .separator:
                views.append(makeGapCell(item: item, modelIndex: index, length: separatorLen))
                consume(separatorLen)
            case .spacer(let points):
                views.append(makeGapCell(item: item, modelIndex: index, length: CGFloat(points)))
                consume(CGFloat(points))
            case .runningAppsZone:
                let zoneApps = RunningZone.apps(running: running, pinnedAppPaths: pinnedPaths)
                if (!pinnedPaths.isEmpty || !zoneApps.isEmpty), wouldFit(separatorLen) {
                    views.append(makeZoneDivider()); consume(separatorLen)
                }
                for app in zoneApps {
                    guard let path = app.bundlePath else { continue }
                    guard wouldFit(cellLen) else { break }   // stop when out of room
                    let synthetic = DockItem.app(bundlePath: path, label: app.name)
                    let cell = makeCell(item: synthetic, modelIndex: nil, running: runningPaths)
                    cell.isRunning = true
                    views.append(cell)
                    consume(cellLen)
                }
            }
        }
    }

    /// Split `views` evenly into `rows` rows (first row nearest the top/left).
    private func layoutRows(_ views: [NSView]) {
        let count = max(1, min(rows, views.count))
        let perRow = Int((Double(views.count) / Double(count)).rounded(.up))
        for r in 0..<count {
            let row = NSStackView(views: Array(views.dropFirst(r * perRow).prefix(perRow)))
            row.orientation = vertical ? .vertical : .horizontal
            row.alignment = vertical ? .centerX : .centerY
            row.spacing = Self.gap
            stack.addArrangedSubview(row)
        }
        stack.spacing = Self.gap
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
        for case let cell as DockItemCell in allCells { cell.setMagnification(1) }
    }

    private func magnify(towardCursor p: NSPoint) {
        let cursor = vertical ? p.y : p.x
        let stride = iconSize + Self.gap
        for case let cell as DockItemCell in allCells {
            let f = cell.convert(cell.bounds, to: self)
            let center = vertical ? f.midY : f.midX
            cell.setMagnification(Magnifier.scale(distance: cursor - center, stride: stride,
                                                  maxScale: magnifyScale))
        }
    }

    /// Insertion index in `items` for a drop at `cursor` along the length axis.
    /// Collects (modelIndex, center) for every rendered model item — icons AND
    /// separators/spacers — so the index is correct even with gaps in the row.
    func insertionIndex(at point: NSPoint) -> Int {
        let cursor = vertical ? point.y : point.x
        // Multi-row: only the row under the cursor decides the slot.
        let row = rowStacks.first { r in
            let f = r.convert(r.bounds, to: self)
            return vertical ? (point.x >= f.minX - Self.gap && point.x <= f.maxX + Self.gap)
                            : (point.y >= f.minY - Self.gap && point.y <= f.maxY + Self.gap)
        } ?? rowStacks.last
        var centers: [(index: Int, center: CGFloat)] = []
        for view in row?.arrangedSubviews ?? [] {
            let modelIndex: Int?
            if let cell = view as? DockItemCell { modelIndex = cell.modelIndex }
            else if let gap = view as? DockGapCell { modelIndex = gap.modelIndex }
            else { modelIndex = nil }
            guard let modelIndex else { continue }   // zone-synthetic cells / zone divider
            let f = view.convert(view.bounds, to: self)
            centers.append((modelIndex, vertical ? f.midY : f.midX))
        }
        let slot = Self.insertionIndex(cursor: cursor, centers: centers,
                                       descending: vertical, itemCount: items.count)
        // Past the end of a row that isn't the last: insert right after that row's last item.
        if slot == items.count, row !== rowStacks.last, let last = centers.last { return last.index + 1 }
        return slot
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

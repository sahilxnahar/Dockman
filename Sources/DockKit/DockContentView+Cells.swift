import AppKit
import ConfigKit

// Building icon, gap and expand-button cells for `DockContentView`.
extension DockContentView {
    // MARK: Cell construction

    func makeCell(item: DockItem, modelIndex: Int?, running: Set<String>) -> DockItemCell {
        let prefs = item.appPath.flatMap { appPrefs[$0] }
        let cell = DockItemCell(item: item, modelIndex: modelIndex, iconSize: iconSize, edge: edge,
                                customIcon: item.path.flatMap { customIcons[$0] }, labelOverride: prefs?.label)
        cell.magnificationEnabled = magnify
        cell.hoverEffect = hoverEffect
        cell.launchEffect = launchEffect
        cell.motionSpeed = motionSpeed
        if let path = item.path {
            cell.isRunning = running.contains(path)
            cell.isActive = path == activeAppPath
        }
        if let path = item.appPath, prefs?.showBadge ?? true {
            cell.badgeText = DockBadges.current[URL(fileURLWithPath: path).standardizedFileURL.path]
        }
        if item.appPath != nil {
            cell.onScroll = { [weak self] event in self?.cycleWindows(for: item, event: event) }
        }
        cell.onActivate = { [weak self, weak cell] in
            guard let self, let cell else { return }
            self.activate(item: item, from: cell)
        }
        cell.onContextMenu = { [weak self, weak cell] event in
            guard let self, let cell else { return }
            self.showContextMenu(for: cell, event: event)
        }
        cell.onBeginDrag = { [weak self] cell, event in
            guard let self, !self.locked else { return }
            self.beginReorderDrag(cell: cell, event: event)
        }
        return cell
    }

    /// Scroll over an app: each notch (or trackpad swipe) brings its next window forward.
    func cycleWindows(for item: DockItem, event: NSEvent) {
        guard let app = Self.runningApp(for: item) else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        scrollAccum += delta
        guard abs(scrollAccum) >= 1, Date().timeIntervalSince(lastCycle) > 0.25 else { return }
        AppControl.cycleWindows(of: app, forward: scrollAccum < 0)
        scrollAccum = 0
        lastCycle = Date()
    }

    /// A user-managed separator or spacer: draggable to reorder, right-click to remove.
    func makeGapCell(item: DockItem, modelIndex: Int, length: CGFloat) -> DockGapCell {
        let cell = DockGapCell(item: item, modelIndex: modelIndex,
                               length: max(length, 1), cross: iconSize * 0.7, vertical: vertical)
        cell.onContextMenu = { [weak self, weak cell] event in
            guard let self, let cell else { return }
            self.showGapContextMenu(for: cell, event: event)
        }
        cell.onBeginDrag = { [weak self] cell, event in
            guard let self, !self.locked else { return }
            self.beginReorderDrag(view: cell, modelIndex: cell.modelIndex, event: event)
        }
        return cell
    }

    /// The lone button a collapsed Dock shows; its chevron points into the screen.
    func makeExpandButton() -> NSButton {
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
    func makeZoneDivider() -> NSView {
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
}

import AppKit
import ConfigKit

/// Accessibility options shared by every Dock (set by the app from `GlobalSettings.access`).
public enum DockAccess {
    public static var prefs = AccessPrefs()
    /// User's choice, or macOS Increase Contrast.
    static var highContrast: Bool { prefs.highContrast || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
}

/// Undo/redo of dock edits, offered from every Dock's menu (state owned by the app).
public enum DockUndo {
    public static var canUndo = false
    public static var canRedo = false
    public static var undo: (() -> Void)?
    public static var redo: (() -> Void)?
}

/// One interactive icon in a Dock: detects click vs drag, shows a running dot,
/// and raises context-menu/drag callbacks. Used for app/file/folder/action items
/// and for synthetic running-apps-zone entries.
public final class DockItemCell: NSView {
    /// Extra height below the icon reserved for the running-indicator dot.
    public static let dotZone: CGFloat = 10

    public let item: DockItem
    /// Index in the Dock's `items` array, or nil for dynamic zone entries.
    public let modelIndex: Int?
    public var isRunning = false { didSet { updateIndicator() } }
    /// The app is frontmost: drawn with a different *shape*, never colour alone.
    public var isActive = false { didSet { updateIndicator() } }

    public var onActivate: (() -> Void)?
    public var onContextMenu: ((NSEvent) -> Void)?
    public var onBeginDrag: ((DockItemCell, NSEvent) -> Void)?
    /// Scroll-wheel over the icon (used to cycle the app's windows).
    public var onScroll: ((NSEvent) -> Void)?
    /// Per-dock motion style (set by the Dock right after creating the cell).
    public var hoverEffect: Appearance.HoverEffect = .grow
    public var launchEffect: Appearance.LaunchEffect = .bounce
    public var motionSpeed: CGFloat = 1
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// When true the Dock drives the icon size via `setMagnification` on cursor
    /// movement, so the cell's own hover-grow stands down to avoid fighting it.
    public var magnificationEnabled = false { didSet { if !magnificationEnabled { iconView.frame = baseIconFrame } } }

    private let iconView = NSImageView()
    private let dot = NSView()
    private var downPoint: NSPoint = .zero
    private var dragging = false
    private let iconSize: CGFloat
    private let edge: Appearance.Edge
    private var tracking: NSTrackingArea?
    private let customIcon: String?
    private var bouncePanel: NSPanel?
    private let badge = NSTextField(labelWithString: "")
    private var widgetObserver: NSObjectProtocol?
    private var dwellLayer: CAShapeLayer?
    private var dwellWork: DispatchWorkItem?

    /// Display name used for the hover label and VoiceOver.
    public let displayName: String?

    public init(item: DockItem, modelIndex: Int?, iconSize: CGFloat, edge: Appearance.Edge = .bottom,
                customIcon: String? = nil, labelOverride: String? = nil) {
        self.item = item
        self.modelIndex = modelIndex
        self.iconSize = iconSize
        self.edge = edge
        self.customIcon = customIcon
        displayName = labelOverride ?? item.label ?? (item.path.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") })
        super.init(frame: NSRect(x: 0, y: 0, width: iconSize, height: iconSize + Self.dotZone))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: iconSize).isActive = true
        heightAnchor.constraint(equalToConstant: iconSize + Self.dotZone).isActive = true

        iconView.image = Self.customImage(customIcon, size: iconSize) ?? Self.image(for: item, size: iconSize)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: 0, y: Self.dotZone, width: iconSize, height: iconSize)
        iconView.autoresizingMask = [.width]
        addSubview(iconView)

        dot.wantsLayer = true
        dot.isHidden = true
        addSubview(dot)

        badge.font = .systemFont(ofSize: max(10, iconSize * 0.2), weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.drawsBackground = true
        badge.backgroundColor = .systemRed
        badge.isHidden = true
        addSubview(badge)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(displayName)
        if case .widget(.clipboard) = item { DockWidgets.startUpdates(for: .clipboard) }
        if case .widget(let kind) = item, kind == .clock || kind == .battery || kind == .calendar {
            DockWidgets.startUpdates(for: kind)
            setAccessibilityLabel(DockWidgets.accessibilityText(for: kind))
            widgetObserver = NotificationCenter.default.addObserver(
                forName: DockWidgets.changed, object: kind, queue: .main
            ) { [weak self] _ in
                self?.reloadIcon()
                self?.setAccessibilityLabel(DockWidgets.accessibilityText(for: kind))
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { widgetObserver.map(NotificationCenter.default.removeObserver) }

    /// Unread-count badge text from the system Dock (nil hides it). Sits on the icon's
    /// top-right corner, like the system Dock's.
    public var badgeText: String? {
        didSet {
            badge.isHidden = (badgeText ?? "").isEmpty
            guard let badgeText, !badgeText.isEmpty else { return }
            badge.stringValue = badgeText
            let h = ceil(badge.font!.pointSize * 1.45)
            let w = max(h, ceil(badge.intrinsicContentSize.width) + h * 0.5)
            badge.frame = NSRect(x: iconSize - w * 0.8, y: Self.dotZone + iconSize - h * 0.85, width: w, height: h)
            badge.layer?.cornerRadius = h / 2
            badge.layer?.masksToBounds = true
            setAccessibilityLabel([displayName, "\(badgeText) unread"].compactMap { $0 }.joined(separator: ", "))
        }
    }

    public func reloadIcon() {
        iconView.image = Self.customImage(customIcon, size: iconSize) ?? Self.image(for: item, size: iconSize)
    }

    // MARK: Running indicator

    /// Running = small mark, frontmost = longer/filled mark, in the chosen style.
    private func updateIndicator() {
        let style = DockAccess.prefs.indicator
        dot.isHidden = !isRunning || style == .none
        setAccessibilityValue(isRunning ? (isActive ? "running, frontmost" : "running") : nil)
        guard !dot.isHidden, let layer = dot.layer else { return }
        let k: CGFloat = DockAccess.highContrast ? 1.5 : 1
        var size: NSSize
        switch style {
        case .bar:  size = NSSize(width: (isActive ? 22 : 10) * k, height: 3 * k)
        case .ring: size = NSSize(width: 7 * k, height: 7 * k)
        default:    size = NSSize(width: (isActive ? 14 : 5) * k, height: 5 * k)
        }
        size.height = min(size.height, Self.dotZone - 1)
        dot.frame = NSRect(x: (iconSize - size.width) / 2, y: (Self.dotZone - size.height) / 2, width: size.width, height: size.height)
        let color = NSColor.labelColor.withAlphaComponent(DockAccess.highContrast ? 1 : 0.75).cgColor
        layer.cornerRadius = size.height / 2
        if style == .ring && !isActive {
            layer.backgroundColor = nil
            layer.borderWidth = 1.5 * k
            layer.borderColor = color
        } else {
            layer.backgroundColor = color
            layer.borderWidth = 0
        }
    }

    // MARK: Dwell-click

    /// Rest the cursor on the icon: a ring fills over the dwell delay, then it opens.
    private func startDwell() {
        cancelDwell()
        let delay = DockAccess.prefs.dwellDelay
        let ring = CAShapeLayer()
        let r = baseIconFrame.insetBy(dx: -2, dy: -2)
        ring.path = CGPath(roundedRect: r, cornerWidth: iconSize * 0.24, cornerHeight: iconSize * 0.24, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 3
        ring.strokeEnd = 1
        layer?.addSublayer(ring)
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = 0
        fill.toValue = 1
        fill.duration = delay
        ring.add(fill, forKey: "dwell")
        dwellLayer = ring
        let work = DispatchWorkItem { [weak self] in
            self?.cancelDwell()
            self?.onActivate?()
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelDwell() {
        dwellWork?.cancel(); dwellWork = nil
        dwellLayer?.removeFromSuperlayer(); dwellLayer = nil
    }

    /// Accent outline on the icon while it has keyboard focus.
    public func setKeyboardFocus(_ on: Bool) {
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = iconSize * 0.22
        iconView.layer?.borderWidth = on ? 3 : 0
        iconView.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
    }

    /// Accent ring while something is dragged over a drop target (the Trash).
    public func setDropHighlight(_ on: Bool) {
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = iconSize * 0.22
        iconView.layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor : nil
    }

    /// Bounce the icon away from the screen edge while the app launches, like the system
    /// Dock. Drawn in a temporary overlay window so the hop isn't clipped by the bar; it
    /// ends on its own after a few hops, or sooner when the Dock re-renders on launch.
    public func startBounce() {
        guard bouncePanel == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window, let image = iconView.image else { return }
        let iconRect = window.convertToScreen(convert(baseIconFrame, to: nil))
        let lift = iconSize * 0.5
        var frame = iconRect
        var imageOrigin = NSPoint.zero
        var hop = CGSize.zero
        switch edge {
        case .bottom: frame.size.height += lift; hop.height = lift
        case .top:    frame.origin.y -= lift; frame.size.height += lift; imageOrigin.y = lift; hop.height = -lift
        case .left:   frame.size.width += lift; hop.width = lift
        case .right:  frame.origin.x -= lift; frame.size.width += lift; imageOrigin.x = lift; hop.width = -lift
        }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = window.level + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = window.backingScaleFactor
        layer.frame = NSRect(origin: imageOrigin, size: iconRect.size)
        host.layer?.addSublayer(layer)
        panel.contentView = host
        panel.orderFrontRegardless()
        bouncePanel = panel
        iconView.alphaValue = 0

        let start = layer.position
        let top = CGPoint(x: start.x + hop.width, y: start.y + hop.height)
        let anim = CAKeyframeAnimation(keyPath: "position")
        anim.values = [start, top, start].map { NSValue(point: $0) }
        anim.keyTimes = [0, 0.45, 1]
        anim.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        anim.duration = 0.6 / Double(motionSpeed)
        anim.repeatCount = 5
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.stopBounce() }
        layer.add(anim, forKey: "bounce")
        CATransaction.commit()
    }

    private func stopBounce() {
        bouncePanel?.orderOut(nil)
        bouncePanel = nil
        iconView.alphaValue = 1
    }

    // VoiceOver: VO-Space activates, VO-Shift-M opens the item's menu.
    public override func accessibilityPerformPress() -> Bool { onActivate?(); return true }
    public override func accessibilityPerformShowMenu() -> Bool {
        guard let window,
              let event = NSEvent.mouseEvent(with: .rightMouseDown, location: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil),
                                             modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
        onContextMenu?(event)
        return true
    }

    public override func scrollWheel(with event: NSEvent) {
        if let onScroll { onScroll(event) } else { super.scrollWheel(with: event) }
    }

    public override func mouseDown(with event: NSEvent) {
        cancelDwell()
        HoverLabel.shared.hide()
        downPoint = event.locationInWindow
        dragging = false
    }
    public override func mouseDragged(with event: NSEvent) {
        guard item.isUserManaged, modelIndex != nil, !dragging else { return }
        let dx = event.locationInWindow.x - downPoint.x
        let dy = event.locationInWindow.y - downPoint.y
        if (dx * dx + dy * dy) > 36 {
            dragging = true
            onBeginDrag?(self, event)
        }
    }
    public override func mouseUp(with event: NSEvent) {
        if !dragging { onActivate?() }
    }
    public override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }

    // MARK: Hover feedback

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseEntered(with event: NSEvent) {
        if !magnificationEnabled { setHovered(true) }
        if DockAccess.prefs.dwellClick { startDwell() }
        if let displayName { HoverLabel.shared.show(displayName, beside: self, edge: edge) }
    }
    public override func mouseExited(with event: NSEvent) {
        if !magnificationEnabled { setHovered(false) }
        cancelDwell()
        HoverLabel.shared.hide(ifOwnedBy: self)
    }
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { HoverLabel.shared.hide(ifOwnedBy: self); stopBounce() }
        super.viewWillMove(toWindow: newWindow)
    }

    private var baseIconFrame: NSRect { NSRect(x: 0, y: Self.dotZone, width: iconSize, height: iconSize) }

    private func setHovered(_ hovered: Bool) {
        var target = baseIconFrame
        switch hoverEffect {
        case .grow where hovered:
            let grow = iconSize * 0.18
            target = NSRect(x: -grow / 2, y: Self.dotZone - grow / 2, width: iconSize + grow, height: iconSize + grow)
        case .lift where hovered:
            // Rise toward the screen's middle, whichever edge the dock is on (stays inside the cell).
            let d = min(Self.dotZone, iconSize * 0.12)
            switch edge {
            case .bottom: target.origin.y += d
            case .top:    target.origin.y -= d
            case .left:   target.origin.x += d
            case .right:  target.origin.x -= d
            }
        case .glow:
            iconView.wantsLayer = true
            iconView.shadow = hovered ? {
                let s = NSShadow()
                s.shadowColor = NSColor.controlAccentColor.withAlphaComponent(0.9)
                s.shadowBlurRadius = iconSize * 0.18
                return s
            }() : nil
        default:
            break
        }
        if reduceMotion {
            iconView.frame = target                    // respect Reduce Motion: no animation
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14 / motionSpeed
                ctx.timingFunction = CAMediaTimingFunction(name: hovered ? .easeOut : .easeInEaseOut)
                iconView.animator().frame = target
            }
        }
    }

    /// Quick press-in on click: the icon dips and springs back, confirming the open.
    public func playPress() {
        guard !reduceMotion, let layer = iconView.layer ?? { iconView.wantsLayer = true; return iconView.layer }() else { return }
        let squash = CAKeyframeAnimation(keyPath: "transform.scale")
        squash.values = [1, 0.86, 1.04, 1]
        squash.keyTimes = [0, 0.35, 0.75, 1]
        squash.duration = 0.28 / Double(motionSpeed)
        // Scale about the icon's centre, not its corner.
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: iconView.frame.midX, y: iconView.frame.midY)
        layer.add(squash, forKey: "press")
    }

    /// Launch feedback in this dock's style: bounce (overlay hop) or pulse (in place).
    public func playLaunch() {
        switch launchEffect {
        case .bounce: startBounce()
        case .pulse:
            guard !reduceMotion, let layer = iconView.layer ?? { iconView.wantsLayer = true; return iconView.layer }() else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.autoreverses = true
            pulse.duration = 0.45 / Double(motionSpeed)
            pulse.repeatCount = 3
            layer.add(pulse, forKey: "pulse")
        case .none: break
        }
    }

    /// Resize the icon to `iconSize * scale`, anchored against the bar so it
    /// grows *inward* (away from the screen edge) and stays centered on the
    /// Dock's length axis. Driven per cursor-move by `DockContentView`, so it
    /// is set instantly (animating each move would lag).
    public func setMagnification(_ scale: CGFloat) {
        let s = max(1, scale)
        let size = iconSize * s
        let frame: NSRect
        switch edge {
        case .bottom:                                  // grow up; bottom of icon on the bar
            frame = NSRect(x: (iconSize - size) / 2, y: Self.dotZone, width: size, height: size)
        case .top:                                     // grow down; top of icon on the bar
            frame = NSRect(x: (iconSize - size) / 2, y: Self.dotZone + iconSize - size, width: size, height: size)
        case .left:                                    // grow right; left of icon on the bar
            frame = NSRect(x: 0, y: Self.dotZone + (iconSize - size) / 2, width: size, height: size)
        case .right:                                   // grow left; right of icon on the bar
            frame = NSRect(x: iconSize - size, y: Self.dotZone + (iconSize - size) / 2, width: size, height: size)
        }
        iconView.frame = frame
    }

    /// `spec` is an image file path or "sf:<symbol name>"; nil/unreadable falls back to the item's own icon.
    static func customImage(_ spec: String?, size: CGFloat) -> NSImage? {
        guard let spec, !spec.isEmpty else { return nil }
        let image: NSImage?
        if spec.hasPrefix("sf:") {
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .regular)
            image = NSImage(systemSymbolName: String(spec.dropFirst(3)), accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        } else {
            image = NSImage(contentsOfFile: spec)
        }
        image?.size = NSSize(width: size, height: size)
        return image
    }

    static func image(for item: DockItem, size: CGFloat) -> NSImage {
        let image: NSImage
        switch item {
        case .app(let path, _), .file(let path, _):
            image = NSWorkspace.shared.icon(forFile: path)
        case .folder(let path, _, _):
            image = NSWorkspace.shared.icon(forFile: path)
        case .action(let action):
            image = NSImage(systemSymbolName: action.symbol ?? "bolt.circle.fill",
                            accessibilityDescription: action.label)
                ?? NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: nil)!
        case .widget(.trash):
            let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            let full = trash.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }
                .map { !$0.filter { $0 != ".DS_Store" }.isEmpty } ?? false
            image = NSImage(named: full ? NSImage.trashFullName : NSImage.trashEmptyName)
                ?? NSImage(systemSymbolName: "trash", accessibilityDescription: "Trash")!
        case .widget(let kind):
            image = DockWidgets.image(for: kind, size: size)
                ?? NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.displayName)!
        default:
            image = NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: nil)!
        }
        image.size = NSSize(width: size, height: size)
        return image
    }
}


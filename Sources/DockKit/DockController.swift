import AppKit
import SpacesKit
import ConfigKit

/// Owns the on-screen windows for a single `DockModel` (one window per target
/// display) and keeps them pinned to the bound Space(s). Idempotent: `reconcile`
/// can be called on every Space/display change and converges to the desired
/// state (docs/03 §4, docs/05 R-15).
public final class DockController {
    public private(set) var model: DockModel
    private let spaces: SkyLightSpacesService

    private var windows: [String: DockPanel] = [:]        // displayUUID -> window
    private var views: [String: DockContentView] = [:]

    /// True when the bound Space(s) no longer exist and the Dock is parked on the
    /// current desktop awaiting a re-pin (docs/05 R-3, AC-4).
    public private(set) var isOrphaned = false
    /// Whether we've ever resolved this binding by an EXACT (uuid/id) match this
    /// session. Once true, a later exact miss means the Space was deleted (orphan)
    /// rather than IDs churning at login — so we stop trusting the ordinal fallback.
    private var everResolvedExact = false

    /// User edited the Dock's items via the UI (drag/drop/remove/keep). The app
    /// persists the new model and re-renders.
    public var onModelEdited: ((DockModel) -> Void)?
    /// An action item issued a dockman command (handled at app level).
    public var onActionCommand: ((DockAction) -> Void)?
    /// Per-app preferences (global, shared by all docks) and their edit callback.
    public var appPrefs: [String: AppPrefs] = [:]
    public var onAppPrefsEdited: ((String, AppPrefs) -> Void)?

    private var lastRunning: [RunningAppInfo] = []

    // Auto-hide state, per display window.
    private var revealed: [String: Bool] = [:]
    private var hideWork: [String: DispatchWorkItem] = [:]
    private var revealWork: [String: DispatchWorkItem] = [:]
    private var floatSave: DispatchWorkItem?
    private var moveObservers: [String: NSObjectProtocol] = [:]
    private let hideDelay: TimeInterval = 0.45

    /// Floating islands have no edge to hide against, so auto-hide is off for them.
    private var autoHides: Bool { model.behavior.autoHide && !model.appearance.floating }

    public init(model: DockModel, spaces: SkyLightSpacesService) {
        self.model = model
        self.spaces = spaces
    }

    public func update(model: DockModel) {
        // A changed binding restarts the exact/ordinal heuristic.
        if model.binding != self.model.binding { everResolvedExact = false }
        self.model = model
    }

    /// Re-render items only (running indicators / zone) without re-pinning windows.
    public func refreshItems(running: [RunningAppInfo]) {
        lastRunning = running
        for (uuid, view) in views {
            let maxLen = screen(for: uuid).map { maxLength(forScreenFrame: $0.frame) } ?? .greatestFiniteMagnitude
            configure(view, maxLength: maxLen)
        }
        resizeWindowsToFit()
    }

    private func configure(_ view: DockContentView, maxLength maxLen: CGFloat) {
        view.customIcons = model.customIcons
        view.appPrefs = appPrefs
        view.locked = model.appearance.locked
        view.rows = model.appearance.rows
        view.hoverEffect = model.appearance.hoverEffect
        view.launchEffect = model.appearance.launchEffect
        view.motionSpeed = CGFloat(model.appearance.motionSpeed)
        view.collapsed = model.behavior.collapsed
        view.setAccessibilityLabel("\(model.name) dock")
        // Big targets: never smaller than 64 px.
        let size = DockAccess.prefs.bigTargets ? max(model.appearance.iconSize, 64) : model.appearance.iconSize
        view.configure(items: model.items, iconSize: CGFloat(size),
                       running: lastRunning, vertical: model.appearance.edge.isVertical, maxLength: maxLen,
                       style: model.appearance.style, tintHex: model.appearance.tintHex,
                       edge: model.appearance.edge, magnify: model.appearance.magnification,
                       magnifyScale: CGFloat(model.appearance.magnificationScale),
                       padding: CGFloat(model.appearance.padding),
                       cornerRadius: CGFloat(model.appearance.cornerRadius),
                       backgroundOpacity: CGFloat(model.appearance.backgroundOpacity))
    }

    /// Create/position/pin windows to match `model` against `topology`.
    public func reconcile(topology: SpacesTopology, running: [RunningAppInfo] = []) {
        lastRunning = running
        return reconcileImpl(topology: topology)
    }

    private func reconcileImpl(topology: SpacesTopology) {
        guard model.enabled else { teardown(); return }

        let targetScreens = resolveTargetScreens(NSScreen.screens)
        let targetUUIDs = Set(targetScreens.compactMap(Self.uuid(for:)))

        // Drop windows for displays we no longer target.
        for (uuid, panel) in windows where !targetUUIDs.contains(uuid) {
            spaces.unregisterOwnedWindow(CGWindowID(panel.windowNumber))
            panel.orderOut(nil)
            windows[uuid] = nil
            moveObservers.removeValue(forKey: uuid).map(NotificationCenter.default.removeObserver)
            views[uuid] = nil
        }

        var orphanedThisPass = false
        for screen in targetScreens {
            guard let uuid = Self.uuid(for: screen) else { continue }

            let panel: DockPanel
            let view: DockContentView
            if let existingPanel = windows[uuid], let existingView = views[uuid] {
                panel = existingPanel
                view = existingView
            } else {
                panel = DockPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80))
                view = DockContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
                view.autoresizingMask = [.width, .height]
                wireView(view, uuid: uuid)
                panel.contentView = view
                windows[uuid] = panel
                views[uuid] = view
            }

            configure(view, maxLength: maxLength(forScreenFrame: screen.frame))
            panel.hasShadow = model.appearance.style != .minimal
            let size = view.fittingSize()
            let revealedFrame = Self.frame(for: model.appearance, size: size, screenFrame: screen.frame)
            // Auto-hide fades the window in place (alpha + mouse-transparency) rather
            // than sliding it off-screen — robust across stacked-display layouts where
            // "below the screen" is another display, not empty space.
            panel.setFrame(revealedFrame, display: true)
            if autoHides {
                let shown = revealed[uuid] ?? false
                panel.alphaValue = shown ? 1 : 0
                panel.ignoresMouseEvents = !shown
            } else {
                revealed[uuid] = nil
                hideWork[uuid]?.cancel(); hideWork[uuid] = nil
                panel.alphaValue = 1
                panel.ignoresMouseEvents = false
                panel.contentView?.layer?.sublayerTransform = CATransform3DIdentity
            }
            panel.isMovableByWindowBackground = model.appearance.floating && !model.appearance.locked
            observeFloatingMoves(panel, uuid: uuid)

            // All-spaces docks use the public path; pinned docks omit it.
            if model.binding.mode == .allSpaces {
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            } else {
                panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
            }

            panel.orderFrontRegardless()
            let wid = CGWindowID(panel.windowNumber)
            spaces.registerOwnedWindow(wid)

            switch model.binding.mode {
            case .spaces:
                // Pin to the resolved Space(s) — own window only, SIP-safe.
                let res = BindingResolver.resolveDetailed(model.binding, topology: topology,
                                                          displayUUID: uuid,
                                                          allowOrdinal: !everResolvedExact)
                if !res.spaceIDs.isEmpty {
                    spaces.set(window: wid, spaces: res.spaceIDs)
                    if res.matchedExactly { everResolvedExact = true }
                } else if !model.binding.spaces.isEmpty {
                    // Orphaned: bound Space(s) gone. Park on the current desktop so the
                    // Dock stays usable; the menu surfaces a one-click re-pin (AC-4).
                    if let park = currentSpaceInfo(displayUUID: uuid, topology: topology)?.id {
                        spaces.move(window: wid, toExactly: park)
                    }
                    orphanedThisPass = true
                }

            case .allSpaces:
                // Visible on every desktop, but hide on fullscreen Spaces unless opted in.
                let type = currentSpaceInfo(displayUUID: uuid, topology: topology)?.type ?? .unknown
                if type == .fullscreen && !model.behavior.showOverFullscreen {
                    panel.orderOut(nil)
                } else {
                    panel.orderFrontRegardless()
                }
            }
        }
        isOrphaned = orphanedThisPass
    }

    public func teardown() {
        for (_, panel) in windows {
            spaces.unregisterOwnedWindow(CGWindowID(panel.windowNumber))
            panel.orderOut(nil)
        }
        hideWork.values.forEach { $0.cancel() }
        hideWork.removeAll()
        revealWork.values.forEach { $0.cancel() }
        revealWork.removeAll()
        moveObservers.values.forEach(NotificationCenter.default.removeObserver)
        moveObservers.removeAll()
        revealed.removeAll()
        windows.removeAll()
        views.removeAll()
        isOrphaned = false
    }

    // MARK: - Auto-hide

    /// Fed the global cursor location; fades auto-hide windows in/out by edge proximity.
    public func handleMouseMoved(_ location: NSPoint) {
        guard model.enabled, autoHides else { return }
        for (uuid, panel) in windows {
            guard let screen = screen(for: uuid) else { continue }
            let revealedFrame = panel.frame   // window stays put; only visibility changes
            let zone = Self.revealZone(edge: model.appearance.edge, revealed: revealedFrame, screenFrame: screen.frame)
            if revealed[uuid] == true {
                // Stay revealed while the cursor is over the Dock (or the edge strip).
                let keep = revealedFrame.insetBy(dx: -8, dy: -8).union(zone)
                if keep.contains(location) {
                    hideWork[uuid]?.cancel(); hideWork[uuid] = nil
                } else {
                    scheduleHide(uuid: uuid)
                }
            } else if zone.contains(location) {
                scheduleReveal(uuid: uuid)
            } else {
                revealWork[uuid]?.cancel(); revealWork[uuid] = nil   // left the edge before the delay ran out
            }
        }
    }

    private func scheduleReveal(uuid: String) {
        let delay = model.behavior.revealDelay
        guard delay > 0 else { reveal(uuid: uuid); return }
        guard revealWork[uuid] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.revealWork[uuid] = nil
            self?.reveal(uuid: uuid)
        }
        revealWork[uuid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reveal(uuid: String) {
        hideWork[uuid]?.cancel(); hideWork[uuid] = nil
        guard revealed[uuid] != true, let panel = windows[uuid] else { return }
        revealed[uuid] = true
        setVisible(panel, true)
    }

    private func scheduleHide(uuid: String) {
        guard revealed[uuid] == true, hideWork[uuid] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.windows[uuid] else { return }
            self.hideWork[uuid] = nil
            guard self.autoHides else { return }
            self.revealed[uuid] = false
            self.setVisible(panel, false)
        }
        hideWork[uuid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }

    /// Slide the Dock's contents toward its screen edge while fading. Only the contents
    /// move — the window itself stays in place, so it never crosses onto another display.
    private func setVisible(_ panel: NSPanel, _ visible: Bool) {
        panel.ignoresMouseEvents = !visible
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let layer = panel.contentView?.layer, !reduceMotion {
            let hidden = Self.hiddenOffset(edge: model.appearance.edge, size: panel.frame.size)
            let from = visible ? hidden : CATransform3DIdentity
            let to = visible ? CATransform3DIdentity : hidden
            let anim = CABasicAnimation(keyPath: "sublayerTransform")
            anim.fromValue = NSValue(caTransform3D: from)
            anim.toValue = NSValue(caTransform3D: to)
            anim.duration = visible ? 0.22 : 0.28
            anim.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
            layer.sublayerTransform = to
            layer.add(anim, forKey: "autohide-slide")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.18 : 0.28
            panel.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: - Keyboard focus

    public var onFocusNextDock: (() -> Void)?

    /// Give this Dock keyboard focus on the screen under the cursor (or any visible one).
    /// Returns false when the Dock isn't showing on the current desktop.
    @discardableResult
    public func beginKeyboardFocus() -> Bool {
        let visible = windows.filter { $0.value.isOnActiveSpace && $0.value.isVisible }
        let mouse = NSEvent.mouseLocation
        guard let (uuid, panel) = visible.first(where: { screen(for: $0.key)?.frame.contains(mouse) == true }) ?? visible.first,
              let view = views[uuid] else { return false }
        if autoHides { reveal(uuid: uuid) }
        panel.allowsKeyboardFocus = true
        panel.makeKeyAndOrderFront(nil)
        view.onKeyboardFocusEnded = { [weak self, weak panel] in
            panel?.allowsKeyboardFocus = false
            if let self, self.autoHides { self.scheduleHide(uuid: uuid) }
        }
        view.onFocusNextDock = { [weak self] in self?.onFocusNextDock?() }
        view.beginKeyboardFocus()
        return true
    }

    /// Floating islands: remember where the user dragged them (as fractions of the
    /// display, so the spot survives resolution changes). Saves once the drag settles.
    private func observeFloatingMoves(_ panel: NSPanel, uuid: String) {
        guard moveObservers[uuid] == nil else { return }
        moveObservers[uuid] = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, let panel, self.model.appearance.floating,
                  let f = self.screen(for: uuid)?.frame else { return }
            let x = f.width > panel.frame.width ? (panel.frame.minX - f.minX) / (f.width - panel.frame.width) : 0.5
            let y = f.height > panel.frame.height ? (panel.frame.minY - f.minY) / (f.height - panel.frame.height) : 0.5
            let fx = min(max(Double(x), 0), 1), fy = min(max(Double(y), 0), 1)
            // Our own setFrame lands exactly on the saved spot: ignore it.
            guard abs(fx - self.model.appearance.floatX) > 0.001 || abs(fy - self.model.appearance.floatY) > 0.001 else { return }
            self.floatSave?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                var edited = self.model
                edited.appearance.floatX = fx
                edited.appearance.floatY = fy
                self.model = edited
                self.onModelEdited?(edited)
            }
            self.floatSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private func screen(for uuid: String) -> NSScreen? {
        NSScreen.screens.first { Self.uuid(for: $0) == uuid }
    }

    /// Current Space on a given display, honoring DHSS topology.
    private func currentSpaceInfo(displayUUID: String, topology: SpacesTopology) -> SpaceInfo? {
        if topology.spansDisplays { return topology.displays.first?.currentSpace }
        return topology.displays.first(where: { $0.displayIdentifier == displayUUID })?.currentSpace
    }

    // MARK: - Actions

    private func wireView(_ view: DockContentView, uuid: String) {
        view.onActivateItem = { [weak self] item in self?.activate(item, fromDisplay: uuid) }
        view.onRunAction = { [weak self] action in self?.run(action) }
        view.onSummonApp = { [weak self] path in
            guard let self, let screen = self.screen(for: uuid) else { return }
            AXWindowControl.summon(appPath: path, toScreen: screen)
        }
        view.onItemsChanged = { [weak self] items in
            guard let self else { return }
            var edited = self.model
            edited.items = items
            self.model = edited
            self.onModelEdited?(edited)        // persist upstream
            self.refreshItems(running: self.lastRunning)
        }
        view.onAppPrefsChanged = { [weak self] path, prefs in self?.onAppPrefsEdited?(path, prefs) }
        view.onToggleCollapsed = { [weak self] in
            guard let self else { return }
            var edited = self.model
            edited.behavior.collapsed.toggle()
            self.model = edited
            self.onModelEdited?(edited)
            self.refreshItems(running: self.lastRunning)
        }
        view.onCustomIconChanged = { [weak self] path, spec in
            guard let self else { return }
            var edited = self.model
            edited.customIcons[path] = spec
            self.model = edited
            self.onModelEdited?(edited)
            self.refreshItems(running: self.lastRunning)
        }
    }

    private func resizeWindowsToFit() {
        for (uuid, view) in views {
            guard let panel = windows[uuid],
                  let screen = NSScreen.screens.first(where: { Self.uuid(for: $0) == uuid }) else { continue }
            panel.setFrame(Self.frame(for: model.appearance, size: view.fittingSize(), screenFrame: screen.frame), display: true)
        }
    }

    private func activate(_ item: DockItem, fromDisplay uuid: String) {
        switch item {
        case .app(let path, _):
            // "Summon" mode: bring the app's window to this Dock's screen (Accessibility).
            if model.behavior.summonWindows, let screen = screen(for: uuid) {
                AXWindowControl.summon(appPath: path, toScreen: screen)
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true   // the TARGET app activates; Dockman stays an agent
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                               configuration: configuration, completionHandler: nil)
        case .file(let path, _):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        default:
            break
        }
    }

    private func run(_ action: DockAction) {
        switch action.kind {
        case .openURL:
            if let url = URL(string: action.value) { NSWorkspace.shared.open(url) }
        case .command:
            onActionCommand?(action)
        }
    }

    // MARK: - Geometry helpers

    private func resolveTargetScreens(_ screens: [NSScreen]) -> [NSScreen] {
        if model.binding.displayUUIDs.isEmpty { return screens }
        return screens.filter { screen in
            guard let uuid = Self.uuid(for: screen) else { return false }
            return model.binding.displayUUIDs.contains(uuid)
        }
    }

    public static func uuid(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cf) as String?
    }

    /// Max Dock length (along its axis) that fits on a display, leaving edge margins.
    func maxLength(forScreenFrame f: NSRect) -> CGFloat {
        // Keep at least a small clearance on the length axis even when the dock
        // itself sits flush (edgeGap 0) against its screen edge.
        let margin = max(CGFloat(model.appearance.edgeGap), 8)
        return model.appearance.edge.isVertical ? f.height - margin * 2 : f.width - margin * 2
    }
}

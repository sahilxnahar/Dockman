import AppKit
import ConfigKit

// Context menus and drag-and-drop for `DockContentView` (split out to keep files small).
extension DockContentView {
    /// The side of a cell that faces into the screen, for popovers on any Dock edge.
    static func inwardEdge(_ edge: Appearance.Edge) -> NSRectEdge {
        switch edge {
        case .bottom: return .maxY
        case .top:    return .minY
        case .left:   return .maxX
        case .right:  return .minX
        }
    }

    // MARK: Context menu

    func showContextMenu(for cell: DockItemCell, event: NSEvent) {
        let menu = NSMenu()
        let isZone = cell.modelIndex == nil

        switch cell.item {
        case .action:
            menu.addItem(withTitle: "Run", action: #selector(ctxOpen(_:)), keyEquivalent: "").representedObject = cell
        default:
            menu.addItem(withTitle: "Open", action: #selector(ctxOpen(_:)), keyEquivalent: "").representedObject = cell
        }
        if cell.item.path != nil {
            menu.addItem(withTitle: "Show in Finder", action: #selector(ctxReveal(_:)), keyEquivalent: "").representedObject = cell
        }
        if cell.item == .widget(.shelf) {
            menu.addItem(withTitle: "Clear Shelf", action: #selector(ctxClearShelf), keyEquivalent: "")
        }
        if let app = Self.runningApp(for: cell.item), let appPath = cell.item.appPath {
            menu.addItem(.separator())
            addAppSection(to: menu, app: app, appPath: appPath)
            menu.addItem(.separator())
            menu.addItem(withTitle: app.isHidden ? "Unhide" : "Hide", action: #selector(ctxHide(_:)), keyEquivalent: "").representedObject = app
            // Holding Option turns Quit into Force Quit, like the system Dock.
            let force = NSEvent.modifierFlags.contains(.option)
            menu.addItem(withTitle: force ? "Force Quit" : "Quit",
                         action: force ? #selector(ctxForceQuit(_:)) : #selector(ctxQuit(_:)),
                         keyEquivalent: "").representedObject = app
        }
        if !isZone, let path = cell.item.path {
            let icon = NSMenu()
            icon.addItem(withTitle: "Choose Image…", action: #selector(ctxChooseIcon(_:)), keyEquivalent: "").representedObject = path
            icon.addItem(withTitle: "Use SF Symbol…", action: #selector(ctxSymbolIcon(_:)), keyEquivalent: "").representedObject = path
            if customIcons[path] != nil {
                icon.addItem(.separator())
                icon.addItem(withTitle: "Reset to Default", action: #selector(ctxResetIcon(_:)), keyEquivalent: "").representedObject = path
            }
            for i in icon.items { i.target = self }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Change Icon", action: nil, keyEquivalent: "").submenu = icon
        }
        if let appPath = cell.item.appPath {
            menu.addItem(withTitle: "Customize App", action: nil, keyEquivalent: "").submenu = customizeMenu(appPath: appPath)
        }
        menu.addItem(.separator())
        if isZone {
            menu.addItem(withTitle: "Keep in Dock", action: #selector(ctxKeep(_:)), keyEquivalent: "").representedObject = cell
        } else {
            menu.addItem(withTitle: "Add Separator After", action: #selector(ctxAddSeparator(_:)), keyEquivalent: "").representedObject = cell
            menu.addItem(withTitle: "Add Spacer After", action: #selector(ctxAddSpacer(_:)), keyEquivalent: "").representedObject = cell
            menu.addItem(.separator())
            menu.addItem(withTitle: "Remove from Dock", action: #selector(ctxRemove(_:)), keyEquivalent: "").representedObject = cell
        }
        menu.addItem(.separator())
        if DockUndo.canUndo { menu.addItem(withTitle: "Undo Last Change", action: #selector(ctxUndo), keyEquivalent: "") }
        if DockUndo.canRedo { menu.addItem(withTitle: "Redo", action: #selector(ctxRedo), keyEquivalent: "") }
        menu.addItem(withTitle: "Collapse Dock", action: #selector(toggleCollapsed), keyEquivalent: "")
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: cell)
    }

    func showGapContextMenu(for cell: DockGapCell, event: NSEvent) {
        let menu = NSMenu()
        let title = { if case .spacer = cell.item { return "Remove Spacer" } else { return "Remove Separator" } }()
        let remove = menu.addItem(withTitle: title, action: #selector(ctxRemoveGap(_:)), keyEquivalent: "")
        remove.representedObject = cell
        remove.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Collapse Dock", action: #selector(toggleCollapsed), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: cell)
    }

    @objc func ctxOpen(_ sender: NSMenuItem) {
        guard let cell = sender.representedObject as? DockItemCell else { return }
        activate(item: cell.item, from: cell)
    }
    @objc func ctxReveal(_ sender: NSMenuItem) {
        guard let cell = sender.representedObject as? DockItemCell, let path = cell.item.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    /// Running-app extras: its windows, pinned commands, the full menu-bar mirror, screenshot.
    private func addAppSection(to menu: NSMenu, app: NSRunningApplication, appPath: String) {
        let windows = AppControl.windows(of: app)
        if !windows.isEmpty {
            let sub = NSMenu()
            for w in windows {
                let item = sub.addItem(withTitle: w.title, action: #selector(ctxRaiseWindow(_:)), keyEquivalent: "")
                item.representedObject = (app, w.element) as (NSRunningApplication, AXUIElement)
                item.target = self
            }
            menu.addItem(withTitle: "Windows (\(windows.count))", action: nil, keyEquivalent: "").submenu = sub
        }
        let pinned = appPrefs[appPath]?.pinnedActions ?? []
        for path in pinned {
            let run = menu.addItem(withTitle: path.last ?? "", action: #selector(ctxRunPinned(_:)), keyEquivalent: "")
            run.representedObject = (app, path) as (NSRunningApplication, [String])
            run.toolTip = path.joined(separator: " ▸ ")
            run.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
            let unpin = menu.addItem(withTitle: "Unpin “\(path.last ?? "")”", action: #selector(ctxUnpin(_:)), keyEquivalent: "")
            unpin.representedObject = (appPath, path) as (String, [String])
            unpin.isAlternate = true
            unpin.keyEquivalentModifierMask = .option
        }
        if let actions = AppControl.actionsMenu(for: app, onPin: { [weak self] path in
            guard let self else { return }
            var prefs = self.appPrefs[appPath] ?? AppPrefs()
            if !prefs.pinnedActions.contains(path) { prefs.pinnedActions.append(path) }
            self.onAppPrefsChanged?(appPath, prefs)
        }) {
            menu.addItem(withTitle: "App Actions", action: nil, keyEquivalent: "").submenu = actions
        }
        menu.addItem(withTitle: "Screenshot Window", action: #selector(ctxScreenshot(_:)), keyEquivalent: "").representedObject = app
    }

    /// Per-app settings shared by every dock: name, click behaviour, badge.
    private func customizeMenu(appPath: String) -> NSMenu {
        let prefs = appPrefs[appPath] ?? AppPrefs()
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename…", action: #selector(ctxRenameApp(_:)), keyEquivalent: "").representedObject = appPath
        menu.addItem(.separator())
        let header = menu.addItem(withTitle: "When Clicked", action: nil, keyEquivalent: "")
        header.isEnabled = false
        for action in AppPrefs.ClickAction.allCases {
            let mi = menu.addItem(withTitle: action.displayName, action: #selector(ctxSetClick(_:)), keyEquivalent: "")
            mi.representedObject = (appPath, action) as (String, AppPrefs.ClickAction)
            mi.state = prefs.clickAction == action ? .on : .off
            mi.indentationLevel = 1
        }
        menu.addItem(.separator())
        let badge = menu.addItem(withTitle: "Show Notification Badge", action: #selector(ctxToggleBadge(_:)), keyEquivalent: "")
        badge.representedObject = appPath
        badge.state = prefs.showBadge ? .on : .off
        if prefs != AppPrefs() {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Reset App Settings", action: #selector(ctxResetApp(_:)), keyEquivalent: "").representedObject = appPath
        }
        for i in menu.items { i.target = self }
        return menu
    }

    private func updatePrefs(_ appPath: String, _ change: (inout AppPrefs) -> Void) {
        var prefs = appPrefs[appPath] ?? AppPrefs()
        change(&prefs)
        onAppPrefsChanged?(appPath, prefs)
    }
    @objc func ctxRenameApp(_ sender: NSMenuItem) {
        guard let appPath = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Rename in Dock"
        alert.informativeText = "Shown in the hover label and to VoiceOver. Leave empty to use the app's own name."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = appPrefs[appPath]?.label ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        updatePrefs(appPath) { $0.label = name.isEmpty ? nil : String(name.prefix(60)) }
    }
    @objc func ctxSetClick(_ sender: NSMenuItem) {
        guard let (appPath, action) = sender.representedObject as? (String, AppPrefs.ClickAction) else { return }
        updatePrefs(appPath) { $0.clickAction = action }
    }
    @objc func ctxToggleBadge(_ sender: NSMenuItem) {
        guard let appPath = sender.representedObject as? String else { return }
        updatePrefs(appPath) { $0.showBadge.toggle() }
    }
    @objc func ctxResetApp(_ sender: NSMenuItem) {
        guard let appPath = sender.representedObject as? String else { return }
        onAppPrefsChanged?(appPath, AppPrefs())
    }

    @objc func ctxRaiseWindow(_ sender: NSMenuItem) {
        guard let (app, window) = sender.representedObject as? (NSRunningApplication, AXUIElement) else { return }
        AppControl.raise(window, in: app)
    }
    @objc func ctxRunPinned(_ sender: NSMenuItem) {
        guard let (app, path) = sender.representedObject as? (NSRunningApplication, [String]) else { return }
        if !AppControl.perform(path: path, in: app) { NSSound.beep() }   // command renamed or app lacks it now
    }
    @objc func ctxUnpin(_ sender: NSMenuItem) {
        guard let (appPath, path) = sender.representedObject as? (String, [String]) else { return }
        var prefs = appPrefs[appPath] ?? AppPrefs()
        prefs.pinnedActions.removeAll { $0 == path }
        onAppPrefsChanged?(appPath, prefs)
    }
    @objc func ctxScreenshot(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? NSRunningApplication else { return }
        AppControl.screenshotFrontWindow(of: app)
    }

    @objc func ctxUndo() { DockUndo.undo?() }
    @objc func ctxRedo() { DockUndo.redo?() }

    @objc func ctxClearShelf() { DockWidgets.clearShelf() }

    static func runningApp(for item: DockItem) -> NSRunningApplication? {
        guard let path = item.appPath else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path }
    }
    @objc func ctxHide(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? NSRunningApplication else { return }
        if app.isHidden { app.unhide() } else { app.hide() }
    }
    @objc func ctxQuit(_ sender: NSMenuItem) {
        (sender.representedObject as? NSRunningApplication)?.terminate()
    }
    @objc func ctxForceQuit(_ sender: NSMenuItem) {
        (sender.representedObject as? NSRunningApplication)?.forceTerminate()
    }
    @objc func ctxChooseIcon(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image to use as this item's icon"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onCustomIconChanged?(path, url.path)
    }
    @objc func ctxSymbolIcon(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Use an SF Symbol"
        alert.informativeText = "Type a symbol name, for example star.fill or terminal."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        if let current = customIcons[path], current.hasPrefix("sf:") { input.stringValue = String(current.dropFirst(3)) }
        alert.accessoryView = input
        alert.addButton(withTitle: "Use Symbol")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
            NSSound.beep(); return                       // unknown symbol: keep the current icon
        }
        onCustomIconChanged?(path, "sf:" + name)
    }
    @objc func ctxResetIcon(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onCustomIconChanged?(path, nil)
    }
    @objc func ctxRemove(_ sender: NSMenuItem) {
        guard let cell = sender.representedObject as? DockItemCell, let index = cell.modelIndex else { return }
        DockSound.play(.remove)
        onItemsChanged?(DockItemOps.removeAt(items, index))
    }
    @objc func ctxKeep(_ sender: NSMenuItem) {
        guard let cell = sender.representedObject as? DockItemCell else { return }
        onItemsChanged?(DockItemOps.insert(items, [cell.item], at: items.count))
    }
    @objc func ctxAddSeparator(_ sender: NSMenuItem) {
        guard let cell = sender.representedObject as? DockItemCell, let index = cell.modelIndex else { return }
        onItemsChanged?(DockItemOps.insert(items, [.separator], at: index + 1))
    }
    @objc func ctxAddSpacer(_ sender: NSMenuItem) {
        guard let cell = sender.representedObject as? DockItemCell, let index = cell.modelIndex else { return }
        onItemsChanged?(DockItemOps.insert(items, [.spacer(points: 24)], at: index + 1))
    }
    @objc func ctxRemoveGap(_ sender: NSMenuItem) {
        guard let cell = sender.representedObject as? DockGapCell else { return }
        onItemsChanged?(DockItemOps.removeAt(items, cell.modelIndex))
    }

    // MARK: Drag & drop

    func beginReorderDrag(cell: DockItemCell, event: NSEvent) {
        guard let index = cell.modelIndex else { return }
        beginReorderDrag(view: cell, modelIndex: index, event: event)
    }

    /// Shared drag entry for icons and gap cells — both ride the same
    /// internal-pasteboard reorder flow.
    func beginReorderDrag(view: NSView, modelIndex: Int, event: NSEvent) {
        let pbItem = NSPasteboardItem()
        pbItem.setString(String(modelIndex), forType: Self.internalType)
        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        let snapshot = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        if let snapshot { view.cacheDisplay(in: view.bounds, to: snapshot) }
        dragItem.setDraggingFrame(view.convert(view.bounds, to: self),
                                  contents: snapshot.map { NSImage(cgImage: $0.cgImage!, size: view.bounds.size) })
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(sender)
    }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(sender)
    }
    public override func draggingExited(_ sender: NSDraggingInfo?) {
        for case let cell as DockItemCell in allCells where Self.isDropTarget(cell.item) {
            cell.setDropHighlight(false)
        }
    }

    static func isDropTarget(_ item: DockItem) -> Bool {
        if case .app = item { return true }
        return item == .widget(.trash) || item == .widget(.shelf)
    }

    /// The app icon under `point`, for "drop a file on an app to open it with that app".
    private func appCell(at point: NSPoint) -> DockItemCell? {
        allCells.lazy.compactMap { $0 as? DockItemCell }.first {
            $0.item.appPath != nil && $0.convert($0.bounds, to: self).contains(point)
        }
    }

    /// The Trash/Shelf widget under `point` (self coords), if any.
    func dropTarget(at point: NSPoint) -> DockItemCell? {
        allCells.lazy.compactMap { $0 as? DockItemCell }.first {
            Self.isDropTarget($0.item) && $0.convert($0.bounds, to: self).contains(point)
        }
    }

    func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let isInternal = sender.draggingPasteboard.types?.contains(Self.internalType) == true
        let over = dropTarget(at: convert(sender.draggingLocation, from: nil))
        for case let cell as DockItemCell in allCells where Self.isDropTarget(cell.item) {
            // Internal (reorder) drags can only land on the Trash; files can land on any target.
            cell.setDropHighlight(cell === over && (!isInternal || cell.item == .widget(.trash)))
        }
        if over?.item == .widget(.trash) { return .delete }
        if !isInternal, let app = appCell(at: convert(sender.draggingLocation, from: nil)) {
            app.setDropHighlight(true)
            return .copy
        }
        if over?.item == .widget(.shelf), !isInternal { return .link }
        return sender.draggingPasteboard.types?.contains(Self.internalType) == true ? .move : .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let drop = convert(sender.draggingLocation, from: nil)
        let target = insertionIndex(at: drop)

        if let shelf = dropTarget(at: drop), shelf.item == .widget(.shelf),
           !(pb.types?.contains(Self.internalType) ?? false),
           let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            shelf.setDropHighlight(false)
            DockSound.play(.drop)
            DockWidgets.addToShelf(urls)
            return true
        }
        if let trash = dropTarget(at: drop), trash.item == .widget(.trash) {
            trash.setDropHighlight(false)
            if let s = pb.string(forType: Self.internalType), let from = Int(s) {
                // Dragging a Dock item onto the Trash removes it from the Dock (never deletes the file).
                if from != trash.modelIndex { DockSound.play(.remove); onItemsChanged?(DockItemOps.removeAt(items, from)) }
                return true
            }
            guard let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return false }
            DockSound.play(.remove)
            NSWorkspace.shared.recycle(urls) { _, _ in DispatchQueue.main.async { trash.reloadIcon() } }
            return true
        }

        if !(pb.types?.contains(Self.internalType) ?? false), let app = appCell(at: drop), let appPath = app.item.appPath,
           let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            app.setDropHighlight(false)
            NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: appPath),
                                    configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            return true
        }
        if let s = pb.string(forType: Self.internalType), let from = Int(s) {
            guard !locked else { return false }
            onItemsChanged?(DockItemOps.reorder(items, from: from, to: target))
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let newItems = urls.map { DockItemOps.item(forDroppedPath: $0.path) }
            DockSound.play(.drop)
            onItemsChanged?(DockItemOps.insert(items, newItems, at: target))
            return true
        }
        return false
    }
}

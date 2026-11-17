import AppKit
import ConfigKit

// Clicking items: apps (per-app click actions), folders, widgets and their popovers.
extension DockContentView {
    // MARK: Activation

    func activate(item: DockItem, from cell: DockItemCell) {
        cell.playPress()
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
        case .widget(.clipboard):
            showPopover(WidgetPopovers.clipboard { [weak self] in self?.folderPopover?.performClose(nil) }, from: cell)
        case .widget(.notes):
            showPopover(WidgetPopovers.notes(), from: cell)
        case .widget(.calendar):
            showPopover(WidgetPopovers.calendar { [weak self] in self?.folderPopover?.performClose(nil) }, from: cell)
        case .widget(let kind):
            DockWidgets.open(kind)
        case .app(let path, _):
            let running = Self.runningApp(for: item)
            switch (appPrefs[path]?.clickAction ?? .open, running) {
            case (.windowList, let app?):
                let menu = NSMenu()
                for w in AppControl.windows(of: app) {
                    let mi = menu.addItem(withTitle: w.title, action: #selector(ctxRaiseWindow(_:)), keyEquivalent: "")
                    mi.representedObject = (app, w.element) as (NSRunningApplication, AXUIElement)
                    mi.target = self
                }
                if menu.items.isEmpty { onActivateItem?(item); return }
                menu.popUp(positioning: nil, at: NSPoint(x: cell.bounds.midX, y: cell.bounds.maxY), in: cell)
            case (.screenshot, let app?):
                AppControl.screenshotFrontWindow(of: app)
            case (.summon, _):
                if running == nil { cell.playLaunch() }
                onSummonApp?(path)
            case (.hideOthers, _):
                if running == nil { cell.playLaunch() }
                onActivateItem?(item)
                for other in NSWorkspace.shared.runningApplications
                where other.activationPolicy == .regular && other.bundleURL?.path != path {
                    other.hide()
                }
            default:
                if running == nil { cell.playLaunch() }
                DockSound.play(.launch)
                onActivateItem?(item)
            }
        default:
            onActivateItem?(item)
        }
    }

    func showFolderPopover(path: String, style: FolderStyle, from cell: NSView) {
        showStack(FolderStackView(path: path, style: style), from: cell)
    }

    func showStack(_ content: FolderStackView, from cell: NSView) {
        content.onOpen = { [weak self] url in
            NSWorkspace.shared.open(url)
            self?.folderPopover?.performClose(nil)
        }
        showPopover(content, from: cell)
    }

    /// Any popover anchored to a Dock cell, opening toward the screen on every edge.
    func showPopover(_ content: NSView, from cell: NSView) {
        folderPopover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        let vc = NSViewController()
        vc.view = content
        popover.contentViewController = vc
        content.layoutSubtreeIfNeeded()
        popover.contentSize = content.fittingSize
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: cell.bounds, of: cell, preferredEdge: Self.inwardEdge(edge))
        folderPopover = popover
    }
}

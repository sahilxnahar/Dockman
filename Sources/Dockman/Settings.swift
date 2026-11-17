import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ConfigKit
import DockKit

private enum SettingsTab: Hashable {
    case general
    case dock(UUID)
}

extension Color {
    init?(dockHex hex: String) {
        guard let ns = NSColor(hex: hex) else { return nil }
        self = Color(nsColor: ns)
    }
}

// MARK: - Root

// Local patch: @State is a SwiftUI macro whose plugin ships only with full Xcode, not the
// Command Line Tools, so the selected tab lives in a plain ObservableObject instead.
private final class SettingsTabModel: ObservableObject {
    static let shared = SettingsTabModel()
    @Published var selection: SettingsTab = .general
}

struct SettingsRootView: View {
    @ObservedObject var controller: DockmanController
    @ObservedObject private var tab = SettingsTabModel.shared
    private var selection: SettingsTab { tab.selection }

    var body: some View {
        NavigationSplitView {
            List(selection: $tab.selection) {
                Section("Docks") {
                    ForEach(controller.config.docks) { dock in
                        Label(dock.name, systemImage: dock.enabled ? "rectangle.stack.fill" : "rectangle.stack")
                            .tag(SettingsTab.dock(dock.id))
                    }
                }
                Section {
                    Label("General", systemImage: "gearshape").tag(SettingsTab.general)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .toolbar {
                Button {
                    controller.newDockHere()
                } label: { Image(systemName: "plus") }
                .help("Add a dock on the current desktop")
            }
        } detail: {
            switch selection {
            case .general:
                GeneralSettingsView(controller: controller)
            case .dock(let id):
                if controller.config.docks.contains(where: { $0.id == id }) {
                    DockSettingsView(controller: controller, dockID: id)
                } else {
                    ContentUnavailableViewCompat(text: "Dock removed")
                }
            }
        }
        .frame(minWidth: 660, minHeight: 500)
    }
}

// MARK: - Per-dock

struct DockSettingsView: View {
    @ObservedObject var controller: DockmanController
    let dockID: UUID

    private let tints: [(String, String?)] = [
        ("Default", nil), ("Blue", "#0A84FF"), ("Purple", "#BF5AF2"),
        ("Pink", "#FF375F"), ("Orange", "#FF9F0A"), ("Green", "#30D158"), ("Gray", "#8E8E93"),
    ]

    var body: some View {
        if let dock = controller.dock(dockID) {
            Form {
                Section("Dock") {
                    TextField("Name", text: Binding(
                        get: { dock.name }, set: { controller.renameDock(dockID, $0) }))
                    Toggle("Enabled", isOn: Binding(
                        get: { dock.enabled }, set: { controller.setEnabled(dockID, $0) }))
                    Toggle("Mirror the macOS Dock", isOn: Binding(
                        get: { dock.mirrorsSystemDock }, set: { controller.setMirrorsSystemDock(dockID, $0) }))
                        .help("Keep this dock's items in sync with the built-in Dock's apps and folders")
                    focusMenu(dock)
                    appTriggerMenu(dock)
                }

                Section("Behavior") {
                    Toggle("Auto-hide", isOn: Binding(
                        get: { dock.behavior.autoHide }, set: { controller.setAutoHide(dockID, $0) }))
                        .disabled(dock.appearance.floating)
                        .help(dock.appearance.floating ? "Floating docks don't auto-hide" : "Slide away until the cursor reaches the screen edge")
                    if dock.behavior.autoHide && !dock.appearance.floating {
                        VStack(alignment: .leading) {
                            LabeledContent("Reveal Delay", value: String(format: "%.2f s", dock.behavior.revealDelay))
                            Slider(value: Binding(
                                get: { dock.behavior.revealDelay },
                                set: { controller.setRevealDelay(dockID, $0) }), in: 0...1, step: 0.05)
                        }
                        .help("How long the cursor rests at the edge before the dock appears")
                    }
                    Toggle("Collapsed to a button", isOn: Binding(
                        get: { dock.behavior.collapsed }, set: { controller.setCollapsed(dockID, $0) }))
                    Picker("Show/Hide Shortcut", selection: Binding(
                        get: { dock.behavior.hotkeyDigit ?? 0 },
                        set: { controller.setHotkey(dockID, $0 == 0 ? nil : $0) })) {
                        Text("None").tag(0)
                        ForEach(1...9, id: \.self) { Text("⌃⌥\($0)").tag($0) }
                    }
                    Toggle("Summon windows to this screen", isOn: Binding(
                        get: { dock.behavior.summonWindows }, set: { controller.setSummonWindows(dockID, $0) }))
                    Toggle("Show over fullscreen apps", isOn: Binding(
                        get: { dock.behavior.showOverFullscreen }, set: { controller.setShowOverFullscreen(dockID, $0) }))
                }

                Section {
                    PlacementPicker(controller: controller, dockID: dockID)
                } header: {
                    Text("Monitors & Desktops")
                } footer: {
                    Text("Changes apply immediately. Hovering a monitor flashes its number on the real screen.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Layout") {
                    Picker("Position", selection: Binding(
                        get: { dock.appearance.edge }, set: { controller.setEdge(dockID, $0) })) {
                        Text("Bottom").tag(Appearance.Edge.bottom)
                        Text("Top").tag(Appearance.Edge.top)
                        Text("Left").tag(Appearance.Edge.left)
                        Text("Right").tag(Appearance.Edge.right)
                    }
                    .pickerStyle(.segmented)
                    Picker("Alignment", selection: Binding(
                        get: { dock.appearance.alignment }, set: { controller.setAlignment(dockID, $0) })) {
                        let vertical = dock.appearance.edge.isVertical
                        Text(vertical ? "Top" : "Left").tag(Appearance.Alignment.start)
                        Text("Center").tag(Appearance.Alignment.center)
                        Text(vertical ? "Bottom" : "Right").tag(Appearance.Alignment.end)
                    }
                    .pickerStyle(.segmented)
                    .disabled(dock.appearance.floating)
                    Toggle("Floating island (drag anywhere)", isOn: Binding(
                        get: { dock.appearance.floating }, set: { controller.setFloating(dockID, $0) }))
                        .help("Drag the dock's background to move it. Position still sets row vs column and which side labels open.")
                    Stepper(value: Binding(get: { dock.appearance.rows }, set: { controller.setRows(dockID, $0) }), in: 1...4) {
                        LabeledContent(dock.appearance.edge.isVertical ? "Columns" : "Rows", value: "\(dock.appearance.rows)")
                    }
                    .help("Wrap items into several rows instead of one long bar (turns magnification off)")
                    VStack(alignment: .leading) {
                        LabeledContent("Margin", value: "\(Int(dock.appearance.padding)) px")
                        Slider(value: Binding(
                            get: { dock.appearance.padding },
                            set: { controller.setPadding(dockID, $0) }), in: 0...32, step: 2)
                    }
                    .help("Space between the icons and the edge of the bar")
                    VStack(alignment: .leading) {
                        LabeledContent("Screen Edge Gap", value: "\(Int(dock.appearance.edgeGap)) px")
                        Slider(value: Binding(
                            get: { dock.appearance.edgeGap },
                            set: { controller.setEdgeGap(dockID, $0) }), in: 0...64, step: 2)
                    }
                    .help("Distance between the bar and the edge of the screen (0 = flush)")
                    Toggle("Lock layout", isOn: Binding(
                        get: { dock.appearance.locked }, set: { controller.setLocked(dockID, $0) }))
                        .help("Stops items being dragged out of order and a floating dock being moved")
                }

                Section("Look") {
                    Menu("Apply Theme") {
                        ForEach(Appearance.themes, id: \.name) { theme in
                            Button(theme.name) { controller.applyTheme(dockID, theme) }
                        }
                    }
                    .help("One-click look: style, tint, corners and opacity")
                    Picker("Style", selection: Binding(
                        get: { dock.appearance.style }, set: { controller.setStyle(dockID, $0) })) {
                        ForEach([Appearance.Style.liquidGlass, .classic, .solid, .minimal], id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Icon Size", value: "\(Int(dock.appearance.iconSize)) px")
                        Slider(value: Binding(
                            get: { dock.appearance.iconSize },
                            set: { controller.setIconSize(dockID, $0) }), in: 24...128, step: 4)
                    }
                    Toggle("Magnification", isOn: Binding(
                        get: { dock.appearance.magnification },
                        set: { controller.setMagnification(dockID, $0) }))

                    if dock.appearance.magnification {
                        VStack(alignment: .leading) {
                            LabeledContent("Magnification Size",
                                           value: String(format: "%.1f×", dock.appearance.magnificationScale))
                            Slider(value: Binding(
                                get: { dock.appearance.magnificationScale },
                                set: { controller.setMagnificationScale(dockID, $0) }), in: 1.1...2.2, step: 0.1)
                        }
                        .help("How large icons grow under the cursor")
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Corner Radius", value: "\(Int(dock.appearance.cornerRadius)) px")
                        Slider(value: Binding(
                            get: { dock.appearance.cornerRadius },
                            set: { controller.setCornerRadius(dockID, $0) }), in: 0...40, step: 1)
                    }
                    if dock.appearance.style != .minimal {
                        VStack(alignment: .leading) {
                            LabeledContent("Background Opacity", value: "\(Int(dock.appearance.backgroundOpacity * 100))%")
                            Slider(value: Binding(
                                get: { dock.appearance.backgroundOpacity },
                                set: { controller.setBackgroundOpacity(dockID, $0) }), in: 0.2...1, step: 0.05)
                        }
                    }
                    HStack {
                        Text("Tint")
                        Spacer()
                        ForEach(tints, id: \.0) { name, hex in
                            Circle()
                                .fill(hex.flatMap { Color(dockHex: $0) } ?? Color.secondary.opacity(0.25))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(dock.appearance.tintHex == hex ? Color.primary : .clear, lineWidth: 2))
                                .onTapGesture { controller.setTint(dockID, hex) }
                                .help(name)
                        }
                    }
                }

                Section("Motion") {
                    Picker("Hover", selection: Binding(
                        get: { dock.appearance.hoverEffect }, set: { controller.setHoverEffect(dockID, $0) })) {
                        Text("Grow").tag(Appearance.HoverEffect.grow)
                        Text("Lift").tag(Appearance.HoverEffect.lift)
                        Text("Glow").tag(Appearance.HoverEffect.glow)
                        Text("None").tag(Appearance.HoverEffect.none)
                    }
                    .pickerStyle(.segmented)
                    Picker("App Launch", selection: Binding(
                        get: { dock.appearance.launchEffect }, set: { controller.setLaunchEffect(dockID, $0) })) {
                        Text("Bounce").tag(Appearance.LaunchEffect.bounce)
                        Text("Pulse").tag(Appearance.LaunchEffect.pulse)
                        Text("None").tag(Appearance.LaunchEffect.none)
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading) {
                        LabeledContent("Speed", value: dock.appearance.motionSpeed < 0.9 ? "Relaxed" : dock.appearance.motionSpeed > 1.2 ? "Snappy" : "Normal")
                        Slider(value: Binding(get: { dock.appearance.motionSpeed }, set: { controller.setMotionSpeed(dockID, $0) }),
                               in: 0.5...2, step: 0.1)
                    }
                    Text("Animations are skipped when Reduce Motion is on in macOS Accessibility settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    List {
                        ForEach(Array(dock.items.enumerated()), id: \.offset) { index, item in
                            ItemRow(item: item) {
                                controller.removeItems(dockID, at: IndexSet(integer: index))
                            }
                        }
                        .onMove { from, to in controller.moveItems(dockID, from: from, to: to) }
                    }
                    .frame(minHeight: 120, idealHeight: CGFloat(dock.items.count) * 28 + 16, maxHeight: 240)
                    HStack {
                        Menu {
                            Button("App, File, or Folder…") { browseAndAddItems() }
                            Divider()
                            Button("Separator") { controller.appendItem(dockID, .separator) }
                            Button("Spacer") { controller.appendItem(dockID, .spacer(points: 24)) }
                            Divider()
                            Button("Running Apps") { controller.appendItem(dockID, .runningAppsZone) }
                                .disabled(dock.items.contains(.runningAppsZone))
                            Divider()
                            ForEach(WidgetKind.allCases, id: \.self) { kind in
                                Button(kind.displayName) { controller.appendItem(dockID, .widget(kind)) }
                                    .disabled(dock.items.contains(.widget(kind)))
                            }
                        } label: {
                            Label("Add Item", systemImage: "plus")
                        }
                        .fixedSize()
                        Spacer()
                    }
                } header: {
                    Text("Items")
                } footer: {
                    Text("Drag to reorder. You can also drag icons directly on the dock, drop files from Finder onto it, and right-click items there to add or remove separators.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Button("Duplicate Dock") {
                            if let id = controller.duplicateDock(dockID) { SettingsTabModel.shared.selection = .dock(id) }
                        }
                        Spacer()
                        Button("Delete Dock", role: .destructive) { controller.deleteDock(dockID) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(dock.name)
        }
    }

    /// Open-panel flow for "Add Item ▸ App, File, or Folder…". Apps become app
    /// items, other folders become folder stacks, files become file items —
    /// the same classification as dropping from Finder.
    private func browseAndAddItems() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps, files, or folders to add to this dock."
        panel.prompt = "Add to Dock"
        // treatsFilePackagesAsDirectories stays false so .app bundles select whole.
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            for url in panel.urls {
                controller.appendItem(dockID, DockItemOps.item(forDroppedPath: url.path))
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}

/// The spatial monitor/desktop picker (docs/09), embedded in Settings. The same
/// component the menu-bar popover uses, in `embedded` chrome: it commits each
/// change immediately, and hovering a monitor flashes the identify overlay on
/// the matching physical screen.
private struct PlacementPicker: NSViewRepresentable {
    @ObservedObject var controller: DockmanController
    let dockID: UUID

    final class Coordinator {
        let identify = IdentifyOverlay()
        /// Last binding we committed — used to tell our own updates apart from
        /// external ones (menu-bar picker, orphan re-pin), so reconfiguring
        /// doesn't fight the user mid-interaction.
        var lastCommitted: ConfigKit.Binding?
        deinit { identify.hideAll() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MonitorSpacePicker {
        let picker = MonitorSpacePicker(frame: .zero)
        picker.embedded = true
        picker.onCommit = { binding in
            context.coordinator.lastCommitted = binding
            controller.setBinding(dockID, binding)
        }
        picker.onHoverMonitor = { uuid in
            context.coordinator.identify.show(uuid: uuid, monitors: Monitors.current())
        }
        configure(picker, coordinator: context.coordinator)
        return picker
    }

    func updateNSView(_ picker: MonitorSpacePicker, context: Context) {
        guard let dock = controller.dock(dockID) else { return }
        // Reconfigure only when the binding changed somewhere *else*.
        if context.coordinator.lastCommitted != dock.binding {
            configure(picker, coordinator: context.coordinator)
        }
    }

    static func dismantleNSView(_ picker: MonitorSpacePicker, coordinator: Coordinator) {
        coordinator.identify.hideAll()
    }

    private func configure(_ picker: MonitorSpacePicker, coordinator: Coordinator) {
        guard let dock = controller.dock(dockID) else { return }
        let topology = controller.monitor.topology
        picker.configure(dockName: dock.name,
                         topology: topology,
                         monitors: Monitors.current(),
                         currentBinding: dock.binding,
                         activeSpaceID: topology.displays.first?.currentSpace?.id)
        coordinator.lastCommitted = dock.binding
    }
}

/// One row in the per-dock Items editor: icon, name, and a remove button.
private struct ItemRow: View {
    let item: DockItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 20, height: 20)
            Text(label)
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from dock")
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .app(let path, _), .file(let path, _), .folder(let path, _, _):
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        case .separator:
            Image(systemName: "poweron").foregroundStyle(.secondary)
        case .spacer:
            Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary)
        case .action(let action):
            Image(systemName: action.symbol ?? "bolt.circle.fill")
        case .runningAppsZone:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .widget(let kind):
            Image(systemName: kind.symbol)
        }
    }

    private var label: String {
        switch item {
        case .app(let path, let label), .file(let path, let label):
            return label ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        case .folder(let path, let label, _):
            return label ?? (path as NSString).lastPathComponent
        case .separator:
            return "Separator"
        case .spacer(let points):
            return "Spacer (\(Int(points)) pt)"
        case .action(let action):
            return action.label ?? action.value
        case .runningAppsZone:
            return "Running Apps"
        case .widget(let kind):
            return kind.displayName
        }
    }
}

/// Tiny fallback so we don't depend on macOS 14-only ContentUnavailableView.
private struct ContentUnavailableViewCompat: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Hosting window

final class SettingsWindowController {
    private var window: NSWindow?

    func show(controller: DockmanController) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsRootView(controller: controller))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Dockman Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 700, height: 540))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

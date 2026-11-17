import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ConfigKit

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var controller: DockmanController

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Start at Login", isOn: Binding(
                    get: { controller.isLoginItemEnabled },
                    set: { _ in controller.toggleLaunchAtLogin() }))
            }
            Section("System Dock") {
                Toggle("Hide the built-in macOS Dock", isOn: Binding(
                    get: { controller.config.global.hideSystemDock },
                    set: { controller.setHideSystemDock($0) }))
                Text("Restored automatically when turned off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Docks") {
                Button("Add Dock on Current Desktop") { controller.newDockHere() }
                Button("Add Copy of the macOS Dock") { controller.newSystemDockCopy() }
                    .help("A dock that mirrors your built-in Dock. Choose which screens it appears on in its settings.")
                HStack {
                    Button("Export Docks…") { exportDocks() }
                    Button("Import Docks…") { importDocks() }
                }
                Text("Import replaces your current docks with the ones in the file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: appVersion())
                LabeledContent("Scripting", value: "dockman://toggle?dock=Name")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    private func exportDocks() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Dockman Docks.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try controller.exportDocks(to: url) } catch { NSAlert(error: error).runModal() }
    }

    private func importDocks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.importDocks(from: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't import docks"
            alert.informativeText = "That file isn't a Dockman export. Your docks were not changed."
            alert.runModal()
        }
    }

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

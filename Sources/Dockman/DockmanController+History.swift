import AppKit
import ConfigKit
import DockKit

// Undo/redo of dock edits and saved profiles.
extension DockmanController {
    // MARK: - Undo / redo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func recordUndo() {
        undoStack.append(config.docks)
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
        publishUndo()
    }
    func undo() {
        guard let previous = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(config.docks)
        config.docks = previous
        publishUndo()
        persistAndReconcile()
    }
    func redo() {
        guard let next = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(config.docks)
        config.docks = next
        publishUndo()
        persistAndReconcile()
    }
    func publishUndo() {
        DockUndo.canUndo = canUndo
        DockUndo.canRedo = canRedo
        DockUndo.undo = { [weak self] in self?.undo() }
        DockUndo.redo = { [weak self] in self?.redo() }
    }

    // MARK: - Profiles

    func saveProfile(named name: String) {
        let name = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
        guard !name.isEmpty else { return }
        config.profiles.removeAll { $0.name == name }
        config.profiles.append(Profile(name: name, docks: config.docks))
        try? store.save(config)
        onStateChanged?()
    }
    func switchToProfile(_ name: String) {
        guard let profile = config.profiles.first(where: { $0.name == name }) else { return }
        recordUndo()                        // switching is undoable
        config.docks = profile.docks
        persistAndReconcile()
    }
    func deleteProfile(_ name: String) {
        config.profiles.removeAll { $0.name == name }
        try? store.save(config)
        onStateChanged?()
    }
}

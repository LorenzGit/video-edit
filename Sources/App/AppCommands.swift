import SwiftUI

/// Replaces the relevant default menus so every editing action has a familiar
/// keyboard shortcut (⌘O, ⌘E, ⌘Z, ⌘B, ⌫, space…).
struct AppCommands: Commands {
    @ObservedObject var vm: EditorViewModel

    var body: some Commands {
        // File
        CommandGroup(replacing: .newItem) {
            Button("Open Video…") { vm.openPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Import Video at End…") { vm.importPanel() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!vm.hasContent)
            Button(vm.isRecording ? "Stop Screen Recording" : "Record Screen Region…") {
                if vm.isRecording { vm.stopScreenRecording() }
                else { vm.beginScreenRecording() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(vm.isFinishingRecording || (!vm.isRecording && vm.recordingActionDisabled))
            Button("Stop Screen Recording") { vm.stopScreenRecording() }
                .keyboardShortcut(.escape, modifiers: .command)
                .disabled(!vm.isRecording || vm.isFinishingRecording)
            Divider()
            Button("Export as MP4…") { vm.export() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!vm.hasContent || vm.isRecording || vm.isFinishingRecording || vm.isExporting)
            Button("Copy Video to Clipboard") { vm.copyVideo() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!vm.hasContent || vm.isRecording || vm.isFinishingRecording || vm.isExporting)
        }

        // Edit
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { vm.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!vm.canUndo)
            Button("Redo") { vm.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!vm.canRedo)
        }

        // Editing actions
        CommandMenu("Clip") {
            Button("Play / Pause") { vm.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!vm.hasContent)
            Divider()
            Button("Split at Playhead") { vm.splitAtPlayhead() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!vm.hasContent)
            Button("Delete Before Playhead") { vm.deleteBeforePlayhead() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!vm.hasContent)
            Button("Delete After Playhead") { vm.deleteAfterPlayhead() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!vm.hasContent)
            Button("Delete Selected Clip") { vm.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(vm.selection.isEmpty)
            Divider()
            Button("Move Clip Earlier") { vm.moveSelected(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!vm.canMoveBackward)
            Button("Move Clip Later") { vm.moveSelected(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!vm.canMoveForward)
            Divider()
            Button(vm.muteAudio ? "Restore Audio" : "Remove Audio") { vm.muteAudio.toggle() }
                .keyboardShortcut("m", modifiers: .command)
                .disabled(!vm.hasContent || !vm.hasAudio)
        }
    }
}

import SwiftUI

/// The icon-only control bar under the transport slider. At narrower window
/// widths the actions wrap into two edge-aligned rows.
struct ControlBar: View {
    @EnvironmentObject var vm: EditorViewModel
    @State private var isConfirmingClearAll = false
    @State private var isAudioInspectorPresented = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout
                .frame(minWidth: 970, maxWidth: .infinity, alignment: .leading)
            stackedLayout
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .confirmationDialog(
            "Clear the entire timeline?",
            isPresented: $isConfirmingClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear Timeline", role: .destructive) {
                vm.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every clip and clears the edit history. It cannot be undone.")
        }
        .onChange(of: vm.hasAudioSelection) { _, isSelected in
            if !isSelected { isAudioInspectorPresented = false }
        }
    }

    private var wideLayout: some View {
        HStack(spacing: 8) {
            fileGroup

            divider

            editingGroup

            clipInfo

            Spacer(minLength: 8)

            viewGroup
        }
    }

    private var stackedLayout: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                fileGroup
                Spacer(minLength: 8)
                clipInfo
            }

            HStack(spacing: 8) {
                editingGroup
                Spacer(minLength: 8)
                viewGroup
            }
        }
    }

    // MARK: Editing tools

    private var editingGroup: some View {
        HStack(spacing: 8) {
            Button { vm.splitAtPlayhead() } label: {
                Image(systemName: "scissors")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!vm.hasContent)
            .help("Split the clip at the playhead (⌘B)")
            .hoverHighlight()
            .accessibilityLabel("Split")

            Button { vm.deleteBeforePlayhead() } label: {
                Image(systemName: "delete.left")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!vm.hasContent)
            .help("Delete everything before the playhead in this clip (⌘[)")
            .hoverHighlight()
            .accessibilityLabel("Delete before playhead")

            Button { vm.deleteAfterPlayhead() } label: {
                Image(systemName: "delete.right")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!vm.hasContent)
            .help("Delete everything after the playhead in this clip (⌘])")
            .hoverHighlight()
            .accessibilityLabel("Delete after playhead")

            Button { vm.deleteSelected() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(ToolButtonStyle(tint: Color(hex: 0xFF6B6B)))
            .disabled(!vm.hasAnySelection)
            .help("Delete the selected clip (⌫)")
            .hoverHighlight()
            .accessibilityLabel("Delete selected clip")

            Button { isConfirmingClearAll = true } label: {
                Image(systemName: "rectangle.stack.badge.minus")
            }
            .buttonStyle(ToolButtonStyle(tint: Color(hex: 0xFF6B6B)))
            .disabled(!vm.hasContent || vm.isRecording || vm.isFinishingRecording || vm.isExporting)
            .help("Clear the video and audio tracks")
            .hoverHighlight()
            .accessibilityLabel("Clear timeline")

            divider

            Button { vm.moveSelected(by: -1) } label: {
                Image(systemName: "arrow.left")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!vm.canMoveBackward)
            .help("Move clip earlier (⌥⌘←)")
            .hoverHighlight()
            .accessibilityLabel("Move clip earlier")

            Button { vm.moveSelected(by: 1) } label: {
                Image(systemName: "arrow.right")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!vm.canMoveForward)
            .help("Move clip later (⌥⌘→)")
            .hoverHighlight()
            .accessibilityLabel("Move clip later")

            divider

            SpeedControl().hoverHighlight()

            Button { vm.muteAudio.toggle() } label: {
                Image(systemName: vm.muteAudio ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(IconButtonStyle(tint: vm.muteAudio ? Color(hex: 0xFF6B6B) : Theme.textPrimary))
            .disabled(!vm.hasContent || !vm.hasAudio)
            .help(muteHelp)
            .hoverHighlight()
            .accessibilityLabel(vm.muteAudio ? "Restore video audio" : "Mute video audio")
        }
    }

    // MARK: File actions

    private var fileGroup: some View {
        HStack(spacing: 8) {
            Button {
                if vm.isRecording {
                    vm.stopScreenRecording()
                } else {
                    vm.beginScreenRecording()
                }
            } label: {
                Image(systemName: vm.isRecording ? "stop.fill" : "record.circle")
            }
            .buttonStyle(RecordButtonStyle(isRecording: vm.isRecording))
            .disabled(vm.isFinishingRecording || (!vm.isRecording && vm.recordingActionDisabled))
            .help(
                vm.isRecording
                    ? "Stop screen recording (⌘Esc or ⇧⌘R)"
                    : "Record a screen region (⇧⌘R)"
            )
            .accessibilityLabel(recordButtonTitle)

            Button { vm.openPanel() } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(GhostButtonStyle())
            .help("Open video (⌘O)")
            .hoverHighlight()
            .accessibilityLabel("Open video")

            Button { vm.importPanel() } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(!vm.hasContent)
            .help("Append another video to the end (⌘I)")
            .hoverHighlight()
            .accessibilityLabel("Append video")

            Button {
                if vm.hasAudioSelection {
                    isAudioInspectorPresented.toggle()
                } else {
                    vm.importAudioPanel()
                }
            } label: {
                Image(systemName: audioButtonIcon)
            }
            .buttonStyle(IconButtonStyle(active: vm.hasImportedAudioTrack))
            .disabled(!vm.hasContent)
            .help(audioButtonHelp)
            .hoverHighlight()
            .accessibilityLabel(audioButtonHelp)
            .popover(isPresented: $isAudioInspectorPresented, arrowEdge: .bottom) {
                AudioMixInspector(isPresented: $isAudioInspectorPresented)
                    .frame(width: 278)
                    .background(Theme.panel)
            }

            Button { vm.export() } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!vm.hasContent || vm.isRecording || vm.isFinishingRecording || vm.isExporting)
            .opacity(vm.hasContent ? 1 : 0.5)
            .help("Export as MP4 (⌘E)")
            .hoverHighlight()
            .accessibilityLabel("Export")

            Button { vm.copyVideo() } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(!vm.hasContent || vm.isRecording || vm.isFinishingRecording || vm.isExporting)
            .opacity(vm.hasContent ? 1 : 0.5)
            .help("Copy the edited video to the clipboard (⇧⌘C)")
            .hoverHighlight()
            .accessibilityLabel("Copy video")
        }
    }

    // MARK: Zoom + history

    private var viewGroup: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button { vm.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(IconButtonStyle())
                    .help("Zoom out (⌘-)")
                    .hoverHighlight()
                    .accessibilityLabel("Zoom out")
                Button { vm.zoomToFit() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(IconButtonStyle(active: vm.isFitZoom))
                .help("Fit timeline to window (⌘0)")
                .hoverHighlight()
                .accessibilityLabel("Fit timeline to window")
                Button { vm.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(IconButtonStyle())
                    .help("Zoom in (⌘+)")
                    .hoverHighlight()
                    .accessibilityLabel("Zoom in")
            }
            .disabled(!vm.hasContent)
            .opacity(vm.hasContent ? 1 : 0.4)

            divider

            Button { vm.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(IconButtonStyle())
                .disabled(!vm.canUndo)
                .help("Undo (⌘Z)")
                .hoverHighlight()
                .accessibilityLabel("Undo")
            Button { vm.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(IconButtonStyle())
                .disabled(!vm.canRedo)
                .help("Redo (⇧⌘Z)")
                .hoverHighlight()
                .accessibilityLabel("Redo")
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(width: 1, height: 22)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var clipInfo: some View {
        if let size = vm.selectedClipSizeText {
            HStack(spacing: 5) {
                Image(systemName: "aspectratio")
                Text(size)
                    .fontDesign(.monospaced)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(Theme.panel)
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            )
            .help("Selected video's source dimensions")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Selected video size \(size)")
        }
    }

    private var muteHelp: String {
        if !vm.hasAudio { return "These videos have no embedded audio" }
        return vm.muteAudio
            ? "Video audio muted — the separate audio track stays audible (⌘M)"
            : "Mute audio embedded in the videos; the separate audio track stays audible (⌘M)"
    }

    private var audioButtonIcon: String {
        if vm.hasAudioSelection { return "slider.horizontal.3" }
        return vm.hasImportedAudioTrack ? "waveform" : "waveform.badge.plus"
    }

    private var audioButtonHelp: String {
        if vm.hasAudioSelection { return "Audio volume and fades" }
        return vm.hasImportedAudioTrack ? "Replace audio track" : "Add audio track"
    }

    private var recordButtonTitle: String {
        if vm.isFinishingRecording { return "Finishing…" }
        if vm.isRecording {
            let seconds = max(0, Int(vm.recordingElapsed))
            return String(format: "Stop %02d:%02d", seconds / 60, seconds % 60)
        }
        if vm.isPreparingRecording { return "Preparing…" }
        return "Record"
    }
}

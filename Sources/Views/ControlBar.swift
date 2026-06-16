import SwiftUI

/// The single control bar under the transport slider. Holds the file actions
/// (filename / Open / Export), the editing tools, and the timeline meta
/// (clip count + zoom) — everything that used to live in the top header and the
/// timeline header, freeing vertical space for the video.
struct ControlBar: View {
    @EnvironmentObject var vm: EditorViewModel

    var body: some View {
        HStack(spacing: 8) {
            fileGroup

            divider

            // Editing tools
            Button { vm.splitAtPlayhead() } label: {
                Label("Split", systemImage: "scissors")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!vm.hasContent)
            .help("Split the clip at the playhead (⌘B)")
            .hoverHighlight()

            Button { vm.deleteBeforePlayhead() } label: {
                Image(systemName: "delete.left")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!vm.hasContent)
            .help("Delete everything before the playhead in this clip (⌘[)")
            .hoverHighlight()

            Button { vm.deleteAfterPlayhead() } label: {
                Image(systemName: "delete.right")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!vm.hasContent)
            .help("Delete everything after the playhead in this clip (⌘])")
            .hoverHighlight()

            Button { vm.deleteSelected() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(ToolButtonStyle(tint: Color(hex: 0xFF6B6B)))
            .disabled(vm.selection.isEmpty)
            .help("Delete the selected clip (⌫)")
            .hoverHighlight()

            divider

            // Reorder the selected clip
            Button { vm.moveSelected(by: -1) } label: {
                Image(systemName: "arrow.left")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!vm.canMoveBackward)
            .help("Move clip earlier (⌥⌘←)")
            .hoverHighlight()

            Button { vm.moveSelected(by: 1) } label: {
                Image(systemName: "arrow.right")
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(!vm.canMoveForward)
            .help("Move clip later (⌥⌘→)")
            .hoverHighlight()

            divider

            SpeedControl().hoverHighlight()

            Button { vm.muteAudio.toggle() } label: {
                Image(systemName: vm.muteAudio ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(IconButtonStyle(tint: vm.muteAudio ? Color(hex: 0xFF6B6B) : Theme.textPrimary))
            .disabled(!vm.hasContent || !vm.hasAudio)
            .help(muteHelp)
            .hoverHighlight()

            Spacer(minLength: 8)

            viewGroup
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
    }

    // MARK: File actions + name

    private var fileGroup: some View {
        HStack(spacing: 8) {
            Button { vm.openPanel() } label: {
                Label("Open", systemImage: "folder")
            }
            .buttonStyle(GhostButtonStyle())
            .hoverHighlight()

            Button { vm.importPanel() } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(!vm.hasContent)
            .help("Append another video to the end (⌘I)")
            .hoverHighlight()

            Button { vm.export() } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!vm.hasContent)
            .opacity(vm.hasContent ? 1 : 0.5)
            .hoverHighlight()

            if !vm.displayName.isEmpty {
                Text(vm.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170)
                    .layoutPriority(-1)
            }
        }
    }

    // MARK: Clip count + zoom + history

    private var viewGroup: some View {
        HStack(spacing: 8) {
            if vm.hasContent {
                Text("\(vm.chunks.count) clip\(vm.chunks.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }

            HStack(spacing: 2) {
                Button { vm.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(IconButtonStyle())
                    .help("Zoom out (⌘-)")
                    .hoverHighlight()
                Button { vm.zoomToFit() } label: {
                    Text("Fit")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(height: 30)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(vm.isFitZoom ? Theme.accent : Theme.textSecondary)
                .help("Fit timeline to window (⌘0)")
                .hoverHighlight()
                Button { vm.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(IconButtonStyle())
                    .help("Zoom in (⌘+)")
                    .hoverHighlight()
            }
            .disabled(!vm.hasContent)
            .opacity(vm.hasContent ? 1 : 0.4)

            divider

            Button { vm.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(IconButtonStyle())
                .disabled(!vm.canUndo)
                .help("Undo (⌘Z)")
                .hoverHighlight()
            Button { vm.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(IconButtonStyle())
                .disabled(!vm.canRedo)
                .help("Redo (⇧⌘Z)")
                .hoverHighlight()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(width: 1, height: 22)
            .padding(.horizontal, 2)
    }

    private var muteHelp: String {
        if !vm.hasAudio { return "This video has no audio track" }
        return vm.muteAudio ? "Audio removed — click to restore (⌘M)" : "Remove audio (⌘M)"
    }
}

import SwiftUI

struct EmptyStateView: View {
    @EnvironmentObject var vm: EditorViewModel

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.accentSoft)
                    .frame(width: 96, height: 96)
                Image(systemName: "film.stack")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Theme.accent)
            }

            VStack(spacing: 7) {
                Text("Drop a video to begin")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Load a MOV or MP4, then split, trim and re-time it.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 10) {
                Button {
                    vm.beginScreenRecording()
                } label: {
                    Label(
                        vm.isPreparingRecording ? "Preparing…" : "Record",
                        systemImage: "record.circle"
                    )
                }
                .buttonStyle(RecordButtonStyle())
                .disabled(vm.recordingActionDisabled)

                Button {
                    vm.openPanel()
                } label: {
                    Label("Open Video", systemImage: "folder")
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            if let message = vm.statusMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xFF6B6B))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var vm: EditorViewModel

    var body: some View {
        HStack(spacing: 14) {
            Button {
                vm.togglePlay()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.accent))
                    .shadow(color: Theme.accent.opacity(0.45), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(!vm.hasContent)
            .opacity(vm.hasContent ? 1 : 0.5)
            .hoverHighlight(scale: 1.06)

            Text(timecode(vm.currentTime, showCentis: true))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 70, alignment: .leading)

            Slider(
                value: Binding(
                    get: { vm.currentTime },
                    set: { vm.scrub(to: $0) }
                ),
                in: 0...max(0.01, vm.totalDuration),
                onEditingChanged: { editing in
                    if editing { vm.beginScrub() } else { vm.endScrub() }
                }
            )
            .tint(Theme.accent)
            .disabled(!vm.hasContent)

            Text(timecode(vm.totalDuration))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
    }
}

import SwiftUI

struct ExportOverlay: View {
    @EnvironmentObject var vm: EditorViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Theme.accent)

                Text("Exporting MP4")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                ProgressView(value: vm.exportProgress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .frame(width: 240)

                Text("\(Int(vm.exportProgress * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
    }
}

import SwiftUI

struct ExportOverlay: View {
    @EnvironmentObject var vm: EditorViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: vm.exportProgressIcon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Theme.accent)

                Text(vm.exportProgressTitle)
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

struct ExportSettingsSheet: View {
    @EnvironmentObject var vm: EditorViewModel
    let action: EditorViewModel.ExportAction
    @State private var resolution: EditorViewModel.ExportResolution
    @State private var compression: EditorViewModel.ExportCompression

    init(
        action: EditorViewModel.ExportAction,
        resolution: EditorViewModel.ExportResolution,
        compression: EditorViewModel.ExportCompression
    ) {
        self.action = action
        _resolution = State(initialValue: resolution)
        _compression = State(initialValue: compression)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: action.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Choose the MP4 size and compression.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Divider().overlay(Theme.stroke)

            VStack(spacing: 16) {
                settingRow(title: "Size") {
                    Picker("Size", selection: $resolution) {
                        ForEach(EditorViewModel.ExportResolution.allCases) { resolution in
                            Text(resolution.title).tag(resolution)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                HStack {
                    Text("Output dimensions")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(vm.exportDimensions(for: resolution))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                }

                Text("Percentage sizes scale from the source. Fixed sizes preserve aspect ratio and never upscale.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                settingRow(title: "Compression") {
                    Picker("Compression", selection: $compression) {
                        ForEach(EditorViewModel.ExportCompression.allCases) { compression in
                            Text(compression.title).tag(compression)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                Text(compression.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(Theme.surface(12))

            HStack {
                Button("Cancel") {
                    vm.cancelExportOptions()
                }
                .buttonStyle(GhostButtonStyle())
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action.buttonTitle) {
                    vm.confirmExportOptions(
                        for: action,
                        resolution: resolution,
                        compression: compression
                    )
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
        .background(Theme.panel)
    }

    private func settingRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            content()
        }
    }
}

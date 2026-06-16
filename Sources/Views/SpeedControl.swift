import SwiftUI

/// Speed picker: preset chips plus a free-form numeric field. Applies to the
/// current selection, or to all clips when nothing is selected.
struct SpeedControl: View {
    @EnvironmentObject var vm: EditorViewModel
    @State private var showPopover = false
    @State private var customText = ""

    private let presets: [Double] = [0.5, 1, 2, 5, 10, 20]
    private var applyToAll: Bool { vm.selection.isEmpty }

    var body: some View {
        Button {
            customText = vm.activeSpeed.map { trimmed($0) } ?? ""
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                Text(buttonTitle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.6)
            }
        }
        .buttonStyle(ToolButtonStyle(tint: Theme.speedTint))
        .disabled(!vm.hasContent)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            popoverBody
                .frame(width: 248)
                .background(Theme.panel)
        }
    }

    private var buttonTitle: String {
        if let speed = vm.activeSpeed { return "Speed " + speedLabel(speed) }
        return "Speed"
    }

    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Playback speed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(applyToAll ? "All clips" : "\(vm.selection.count) selected")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                ForEach(presets, id: \.self) { speed in
                    chip(for: speed)
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    TextField("Custom", text: $customText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 56)
                        .onSubmit { applyCustom() }
                    Text("×")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Theme.surface(8))

                Button("Apply") { applyCustom() }
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.small)
            }

            if !applyToAll {
                Button { applyCustom(all: true) } label: {
                    Text("Apply to all clips")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GhostButtonStyle())
            }

            Text("Type any speed — \(trimmed(EditorViewModel.minSpeed))× or faster")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(16)
    }

    private func chip(for speed: Double) -> some View {
        let isActive = vm.activeSpeed == speed
        return Button {
            vm.setSpeed(speed, all: applyToAll)
            showPopover = false
        } label: {
            Text(speedLabel(speed))
                .font(.system(size: 12.5, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive ? Theme.speedTint.opacity(0.22) : Theme.panelHi)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isActive ? Theme.speedTint : Theme.stroke, lineWidth: 1)
                        )
                )
                .foregroundStyle(isActive ? Theme.speedTint : Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }

    private func applyCustom(all: Bool = false) {
        let normalized = customText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else { return }
        vm.setSpeed(value, all: all || applyToAll)
        showPopover = false
    }

    /// Formats a speed without trailing zeros (1.0 -> "1", 1.5 -> "1.5").
    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }
}

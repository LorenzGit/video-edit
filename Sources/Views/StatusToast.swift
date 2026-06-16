import SwiftUI

/// Transient message shown at the bottom of the editor (export results, load
/// errors). Auto-dismissed by ContentView after a few seconds.
struct StatusToast: View {
    let message: String

    private var isError: Bool {
        let lower = message.lowercased()
        return lower.contains("fail") || lower.contains("couldn't")
            || lower.contains("error") || lower.contains("cancel")
            || lower.contains("nothing")
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color(hex: 0xFF6B6B) : Theme.speedTint)
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.panelHi)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
    }
}

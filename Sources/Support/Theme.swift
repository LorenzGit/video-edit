import SwiftUI

/// Centralised colours, typography and reusable button styles so the whole
/// app shares one consistent, modern dark aesthetic.
enum Theme {
    static let bg          = Color(hex: 0x0D0E12)
    static let panel       = Color(hex: 0x15171F)
    static let panelHi     = Color(hex: 0x1D2029)
    static let stroke      = Color.white.opacity(0.08)
    static let strokeHi    = Color.white.opacity(0.14)

    static let accent      = Color(hex: 0x6E8BFF)   // periwinkle — primary actions
    static let accentSoft  = Color(hex: 0x6E8BFF).opacity(0.18)

    static let clip        = Color(hex: 0x12423D)   // teal filmstrip base
    static let clipBorder  = Color(hex: 0x2C6E66)
    static let speedTint   = Color(hex: 0x37E1B5)   // mint — speed badges

    static let textPrimary   = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary  = Color.white.opacity(0.35)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Button styles

/// Filled accent button used for the primary call to action.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

/// Subtle bordered button for secondary actions.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.panelHi.opacity(configuration.isPressed ? 0.6 : 1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
    }
}

/// Compact icon + label tool used in the action bar (Split, Delete, …).
struct ToolButtonStyle: ButtonStyle {
    var tint: Color = Theme.textPrimary
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isEnabled ? tint : Theme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Theme.panelHi : Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.55)
    }
}

/// Square icon-only button, used for compact toolbar actions and toggles.
struct IconButtonStyle: ButtonStyle {
    var tint: Color = Theme.textPrimary
    var active: Bool = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: 30, height: 30)
            .foregroundStyle(isEnabled ? (active ? Theme.accent : tint) : Theme.textTertiary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Theme.accentSoft : (configuration.isPressed ? Theme.panelHi : Color.clear))
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
    }
}

// MARK: - Hover

private struct HoverHighlight: ViewModifier {
    var scale: CGFloat
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .brightness(hovering ? 0.06 : 0)
            .scaleEffect(hovering ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Subtle brighten (and optional grow) on pointer hover.
    func hoverHighlight(scale: CGFloat = 1.0) -> some View {
        modifier(HoverHighlight(scale: scale))
    }
}

// MARK: - Surfaces

extension Theme {
    /// Window background — a soft top-to-bottom gradient instead of flat black.
    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0x14161D), Color(hex: 0x0A0B0F)],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// Rounded panel fill + hairline border, reused across surfaces.
    static func surface(_ radius: CGFloat = 10) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

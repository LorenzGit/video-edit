import Foundation

/// Formats a number of seconds as a timecode.
/// `MM:SS` by default, `H:MM:SS` past an hour, with optional centiseconds.
func timecode(_ seconds: Double, showCentis: Bool = false) -> String {
    let t = (seconds.isFinite && seconds > 0) ? seconds : 0
    let total = Int(t)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    let base = h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%02d:%02d", m, s)
    if showCentis {
        let cs = Int((t - Double(total)) * 100)
        return base + String(format: ".%02d", cs)
    }
    return base
}

/// Formats a speed multiplier, e.g. 1.0 -> "1×", 0.5 -> "0.5×", 2.0 -> "2×".
func speedLabel(_ speed: Double) -> String {
    if speed == speed.rounded() {
        return "\(Int(speed))×"
    }
    return String(format: "%g×", speed)
}

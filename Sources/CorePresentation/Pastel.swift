#if os(macOS)
import AppKit
import SwiftUI

/// Adaptive color tokens. RGB values are chosen; contrast is not a measured claim.
public enum Pastel {
    private static func adaptive(
        dark: (CGFloat, CGFloat, CGFloat),
        light: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1.0)
        })
    }

    /// Luminous sky blue (#8FD4FF in Dark · #0969DA in Light)
    public static let sky = adaptive(dark: (0.56, 0.83, 1.00), light: (0.04, 0.41, 0.85))
    /// Luminous aqua (#85EBF5 in Dark · #087F8C in Light)
    public static let aqua = adaptive(dark: (0.52, 0.92, 0.96), light: (0.03, 0.50, 0.55))
    /// Luminous mint green (#85F0C7 in Dark · #087F5B in Light)
    public static let mint = adaptive(dark: (0.52, 0.94, 0.78), light: (0.03, 0.50, 0.36))
    /// Luminous sage (#A3F2AA in Dark · #2B8A3E in Light)
    public static let sage = adaptive(dark: (0.64, 0.95, 0.67), light: (0.17, 0.54, 0.24))
    /// Luminous lavender (#CCB8FF in Dark · #5F3DC4 in Light)
    public static let lavender = adaptive(dark: (0.80, 0.72, 1.00), light: (0.37, 0.24, 0.77))
    /// Luminous periwinkle (#ADC2FF in Dark · #3B5BDB in Light)
    public static let periwinkle = adaptive(dark: (0.68, 0.76, 1.00), light: (0.23, 0.36, 0.86))
    /// Luminous lilac (#EBB3FA in Dark · #9C36B5 in Light)
    public static let lilac = adaptive(dark: (0.92, 0.70, 0.98), light: (0.61, 0.21, 0.71))
    /// Luminous peach (#FFC78C in Dark · #C95B0C in Light)
    public static let peach = adaptive(dark: (1.00, 0.78, 0.55), light: (0.79, 0.36, 0.05))
    /// Luminous butter yellow (#FFE88F in Dark · #9C6500 in Light)
    public static let butter = adaptive(dark: (1.00, 0.91, 0.56), light: (0.61, 0.40, 0.00))
    /// Luminous coral rose (#FFA6B8 in Dark · #C2255C in Light)
    public static let rose = adaptive(dark: (1.00, 0.65, 0.72), light: (0.76, 0.15, 0.36))
    /// Neutral ice silver (#E2E8F0 in Dark · #334155 in Light)
    public static let ice = adaptive(dark: (0.88, 0.91, 0.95), light: (0.20, 0.25, 0.33))

    /// Maps standard SwiftUI saturated system colors to adaptive Pastel tokens.
    public static func resolve(_ color: Color?) -> Color? {
        guard let color else { return nil }
        switch color {
        case .blue: return Pastel.sky
        case .cyan: return Pastel.aqua
        case .teal: return Pastel.aqua
        case .mint: return Pastel.mint
        case .green: return Pastel.mint
        case .yellow: return Pastel.butter
        case .orange: return Pastel.peach
        case .red: return Pastel.rose
        case .pink: return Pastel.lilac
        case .purple: return Pastel.lavender
        case .indigo: return Pastel.periwinkle
        default: return color
        }
    }
}

#endif

import AppKit
import SwiftUI

/// Copyisto palette and type, from copyisto-ingestor/web/src/index.css.
/// Fonts are bundled by scripts/bundle.sh; `Font.custom` falls back to the system font when they are missing.
enum Theme {
    static let paper = Color(light: 0xF4F0E6, dark: 0x17130E)
    static let surface = Color(light: 0xFBF8F0, dark: 0x221C15)
    static let sunken = Color(light: 0xEDE7D8, dark: 0x1C1711)
    static let border = Color(light: 0xDDD5C4, dark: 0x3A3128)
    static let text = Color(light: 0x241D14, dark: 0xF0EADC)
    static let muted = Color(light: 0x5A5044, dark: 0xB3A893)
    static let accent = Color(light: 0x7C2D12, dark: 0xE07A45)
    static let onAccent = Color(light: 0xFBF8F0, dark: 0x1B1209)
    static let warningSoft = Color(light: 0xF3E6C8, dark: 0x372B14)
    static let warning = Color(light: 0x85560A, dark: 0xE8B95A)

    static func display(_ size: CGFloat) -> Font {
        .custom("Young Serif", size: size)
    }

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Archivo", size: size).weight(weight)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(rgb: isDark ? dark : light)
            })
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }
}

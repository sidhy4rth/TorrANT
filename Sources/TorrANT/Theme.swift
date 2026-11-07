import SwiftUI
import CoreText

/// Colours and type from the TorrANT mockups (dark ant colony).
enum Theme {
    static let soil = Color(hex: 0x14100C)
    static let deep = Color(hex: 0x0E0B08)
    static let surface = Color(hex: 0x1F1913)
    static let surface2 = Color(hex: 0x2A221A)
    static let line = Color(hex: 0x3A2F24)
    static let lineSoft = Color(hex: 0x5A4A38)
    static let text = Color(hex: 0xF5EDE1)
    static let muted = Color(hex: 0xCBBFAE)
    static let chalk = Color(hex: 0xEFE4D2)
    static let honey = Color(hex: 0xFFB627)

    static let swarm = Color(hex: 0xE8572A)
    static let swarmText = Color(hex: 0xFF8A5E)
    static let swarmTint = Color(hex: 0x3A1D14)
    static let crumb = Color(hex: 0x3FB8A8)
    static let crumbText = Color(hex: 0x6FD9C9)
    static let crumbTint = Color(hex: 0x123430)
    static let rest = Color(hex: 0x6B6157)
    static let safe = Color(hex: 0x8BD46E)
    static let poison = Color(hex: 0x9B6BE8)

    /// Fonts ship inside the app (Contents/Resources/Fonts). Info.plist's
    /// ATSApplicationFontsPath registers them too; this is a fallback.
    static func registerFonts() {
        for name in ["BricolageGrotesque", "Figtree", "Caveat"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    static func display(_ size: CGFloat) -> Font {
        .custom("Bricolage Grotesque", size: size).weight(.heavy)
    }

    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Figtree", size: size).weight(weight)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// The faint dot grid behind every screen. Drawn once, not animated.
struct SoilBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 22
            var y: CGFloat = 2
            while y < size.height {
                var x: CGFloat = 2
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)),
                             with: .color(Color(hex: 0x211A14)))
                    x += step
                }
                y += step
            }
        }
        .background(Theme.soil)
        .drawingGroup()
    }
}

struct Card<Content: View>: View {
    var radius: CGFloat = 18
    var fill: Color = Theme.surface
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
    }
}

struct Pill: View {
    let text: String
    let fg: Color
    let bg: Color
    var body: some View {
        Text(text)
            .font(Theme.body(12, .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(bg))
    }
}

struct HoneyButtonStyle: ButtonStyle {
    var big = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(big ? Theme.display(17) : Theme.body(14, .bold))
            .foregroundStyle(Theme.soil)
            .padding(.horizontal, big ? 24 : 16)
            .frame(height: big ? 46 : 36)
            .background(Capsule().fill(Theme.honey.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = Theme.text
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(14, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().strokeBorder(tint == Theme.text ? Theme.line : tint, lineWidth: tint == Theme.text ? 1 : 2))
            .background(Capsule().fill(Theme.surface.opacity(configuration.isPressed ? 1 : 0.001)))
            .contentShape(Capsule())
    }
}

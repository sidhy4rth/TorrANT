import SwiftUI
import CoreText

/// Colours and type: black & red, like an ant.
enum Theme {
    static let soil = Color(hex: 0x0A0A0A)
    static let deep = Color(hex: 0x050505)
    static let surface = Color(hex: 0x141414)
    static let surface2 = Color(hex: 0x1C1C1C)
    static let line = Color(hex: 0x262626)
    static let lineSoft = Color(hex: 0x3A3A3A)
    static let sidebar = Color(hex: 0x0D0D0D)
    static let text = Color(hex: 0xF4F1EE)
    static let muted = Color(hex: 0xA9A39E)
    static let chalk = Color(hex: 0xEFE4D2)
    /// Accent for text, icons and lines on black.
    static let red = Color(hex: 0xFF4D40)
    /// Fill behind white button text (passes contrast).
    static let redFill = Color(hex: 0xD7261F)

    static let swarm = Color(hex: 0xE5322D)
    static let swarmText = Color(hex: 0xFF4D40)
    static let swarmTint = Color(hex: 0x3A0E0C)
    static let crumb = Color(hex: 0xE8E0D4)
    static let crumbText = Color(hex: 0xE8E0D4)
    static let crumbTint = Color(hex: 0x2A2622)
    static let rest = Color(hex: 0x5A5551)
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
                             with: .color(Color(hex: 0x161616)))
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

struct RedButtonStyle: ButtonStyle {
    var big = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(big ? Theme.display(17) : Theme.body(14, .bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, big ? 24 : 16)
            .frame(height: big ? 46 : 36)
            .background(Capsule().fill(Theme.redFill.opacity(configuration.isPressed ? 0.8 : 1)))
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

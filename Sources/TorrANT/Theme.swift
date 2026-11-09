import SwiftUI
import CoreText

/// Colours and type: Honey. Amber on warm charcoal, like honey in a dark nest.
/// (Names are kept from the first black-and-red look so every screen follows the theme.)
enum Theme {
    static let soil = Color(hex: 0x15120E)
    static let deep = Color(hex: 0x100D0A)
    static let surface = Color(hex: 0x221D16)
    static let surface2 = Color(hex: 0x2E271E)
    static let line = Color(hex: 0x33291E)
    static let lineSoft = Color(hex: 0x4A3F31)
    static let sidebar = Color(hex: 0x1A1612)
    static let text = Color(hex: 0xF6EFE4)
    static let muted = Color(hex: 0xB5A894)
    static let chalk = Color(hex: 0xF6EFE4)
    /// Accent for text, icons and lines (amber).
    static let red = Color(hex: 0xF2A93B)
    /// Fill behind button text; the text on it is `onAccent`.
    static let redFill = Color(hex: 0xF2A93B)
    static let onAccent = Color(hex: 0x1A1307)
    static let soft = Color(hex: 0x33260F)
    static let softText = Color(hex: 0xF5B95A)

    static let swarm = Color(hex: 0xFF6B4A)
    static let swarmText = Color(hex: 0xFF8466)
    static let swarmTint = Color(hex: 0x3A1A12)
    static let crumb = Color(hex: 0xE8DCC8)
    static let crumbText = Color(hex: 0xE8DCC8)
    static let crumbTint = Color(hex: 0x2E271E)
    static let rest = Color(hex: 0x6B604F)
    static let safe = Color(hex: 0x8CCB6A)
    static let poison = Color(hex: 0xC5B3E6)

    /// The relay crew: one ant per leg of the trip.
    static let nightAnt = Color(hex: 0xC5B3E6)     // waits in the queue
    static let carrierAnt = Color(hex: 0xFF6B4A)   // downloading
    static let flyerAnt = Color(hex: 0xF2A93B)     // uploading to Drive
    static let librarianAnt = Color(hex: 0x8CCB6A) // shelving in the Library
    static let crumbFill = Color(hex: 0xFFF4DF)
    static let track = Color(hex: 0x33291E)
    static let stationDot = Color(hex: 0x4A3F31)

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

/// The plain, flat background behind every screen.
struct SoilBackground: View {
    var body: some View { Theme.soil }
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
            .foregroundStyle(Theme.onAccent)
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

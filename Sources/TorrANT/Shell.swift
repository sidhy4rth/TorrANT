import SwiftUI

/// Which part of TorrANT is showing. Everything lives in one window; the sidebar switches it.
@MainActor @Observable
final class Nav {
    static let shared = Nav()

    enum Section: String, CaseIterable, Identifiable {
        case downloads, library, drive, grabber, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .downloads: "Downloads"
            case .library: "Library"
            case .drive: "Google Drive"
            case .grabber: "Link Grabber"
            case .settings: "Settings"
            }
        }
        var icon: String {
            switch self {
            case .downloads: "arrow.down.circle.fill"
            case .library: "play.rectangle.on.rectangle.fill"
            case .drive: "icloud.fill"
            case .grabber: "link.badge.plus"
            case .settings: "gearshape.fill"
            }
        }
        var key: KeyEquivalent {
            switch self {
            case .downloads: "1"
            case .library: "2"
            case .drive: "3"
            case .grabber: "4"
            case .settings: ","
            }
        }
    }

    var section: Section = Section(rawValue: UserDefaults.standard.string(forKey: "section") ?? "") ?? .downloads {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: "section") }
    }
}

/// The one window: sidebar on the left, the chosen section on the right.
struct RootView: View {
    @State private var nav = Nav.shared
    var body: some View {
        HStack(spacing: 0) {
            Rail()
            ZStack {
                switch nav.section {
                case .downloads: ColonyView()
                case .library: LibraryView()
                case .drive: DriveView()
                case .grabber: GrabberView()
                case .settings: SettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.soil)
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct Rail: View {
    @State private var nav = Nav.shared
    @Bindable private var colony = Colony.shared
    @State private var night = NightShift.shared
    @State private var up = Uploader.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The window's traffic lights sit above this.
            HStack(spacing: 10) {
                AntGlyph(color: Theme.red).frame(width: 28)
                (Text("Torr") + Text("ANT").foregroundColor(Theme.red)).font(Theme.display(22))
            }
            .padding(.top, 50)
            .padding(.leading, 18)
            .padding(.bottom, 18)

            ForEach(Nav.Section.allCases.filter { $0 != .settings }) { s in
                RailItem(section: s, selected: nav.section == s, badge: badge(s)) {
                    withAnimation(.easeOut(duration: 0.12)) { nav.section = s }
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(colony.online ? Theme.safe : Theme.swarm).frame(width: 8, height: 8)
                    Text(colony.online ? "Colony online · \(colony.antsOut) ants out" : (colony.problem ?? "Waking the colony…"))
                        .font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                DriveModeSwitch()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            RailItem(section: .settings, selected: nav.section == .settings, badge: nil) {
                withAnimation(.easeOut(duration: 0.12)) { nav.section = .settings }
            }
            .padding(.bottom, 14)
        }
        .frame(width: 228)
        .frame(maxHeight: .infinity)
        .background(Theme.deep)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.surface2).frame(width: 1) }
    }

    /// Small live counts beside each section.
    private func badge(_ s: Nav.Section) -> (String, Color)? {
        switch s {
        case .downloads:
            let n = colony.trail.filter { $0.state == .active || $0.state == .waiting }.count
            return n > 0 ? ("\(n)", Theme.red) : nil
        case .drive:
            let n = up.jobs.count + colony.carrying.count + colony.unpacking.count
            return n > 0 ? ("\(n) ↑", Theme.red) : nil
        case .grabber:
            let n = night.waiting.count
            return n > 0 ? ("☾ \(n)", Theme.chalk) : nil
        case .library, .settings:
            return nil
        }
    }
}

/// Settings as a page in the window rather than a separate one.
private struct SettingsPage: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Settings").font(Theme.display(24))
                Spacer()
            }
            .padding(.horizontal, 22)
            .frame(height: 54)
            .background(Theme.deep)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.surface2).frame(height: 1) }
            ScrollView {
                SettingsView().frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .background(SoilBackground().ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Theme.text)
    }
}

private struct RailItem: View {
    let section: Nav.Section
    let selected: Bool
    let badge: (String, Color)?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: section.icon).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? Theme.red : Theme.muted)
                    .frame(width: 20)
                Text(section.title).font(Theme.body(15, selected ? .bold : .semibold))
                    .foregroundStyle(selected ? Theme.text : Theme.muted)
                Spacer()
                if let (text, color) = badge {
                    Text(text).font(Theme.body(11, .bold)).foregroundStyle(color)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.surface2))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Theme.surface2 : (hover ? Theme.surface : .clear)))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(Theme.red).frame(width: 3, height: 18).offset(x: -1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { hover = $0 }
        .help("\(section.title) (⌘\(String(section.key.character)))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

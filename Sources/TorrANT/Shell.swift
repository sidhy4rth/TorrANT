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
            case .downloads: "Lines"
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

/// The one window: tabs along the top, the chosen section below.
struct RootView: View {
    @State private var nav = Nav.shared
    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            ZStack {
                switch nav.section {
                case .downloads: ColonyView().transition(.pageSwap)
                case .library: LibraryView().transition(.pageSwap)
                case .drive: DriveView().transition(.pageSwap)
                case .grabber: GrabberView().transition(.pageSwap)
                case .settings: SettingsPage().transition(.pageSwap)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(Theme.soil)
        .tint(Theme.red)   // switches, checkboxes and pickers in amber, not system blue
        .ignoresSafeArea(.container, edges: .top)
    }
}

extension AnyTransition {
    /// The old page fades out; the new one fades in while sliding up a touch.
    static var pageSwap: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity)
    }
}

/// Logo, section tabs (an amber pill slides to the chosen one), the Drive switch and Settings.
private struct TopBar: View {
    @State private var nav = Nav.shared
    @Bindable private var colony = Colony.shared
    @State private var night = NightShift.shared
    @State private var up = Uploader.shared
    @Namespace private var pill

    private static let tabs: [Nav.Section] = [.downloads, .library, .drive, .grabber]

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                AntGlyph(color: Theme.red).frame(width: 26)
                (Text("Torr") + Text("ANT").foregroundColor(Theme.red)).font(Theme.display(21))
            }
            HStack(spacing: 2) {
                ForEach(Self.tabs) { s in
                    let on = nav.section == s
                    Button { go(s) } label: {
                        HStack(spacing: 7) {
                            Text(s.title).font(Theme.body(14, .bold))
                            if let (text, color) = badge(s) {
                                Text(text).font(Theme.body(11, .bold))
                                    .foregroundStyle(on ? Theme.onAccent : color)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(on ? Theme.onAccent.opacity(0.15) : Theme.surface2))
                            }
                        }
                        .foregroundStyle(on ? Theme.onAccent : Theme.muted)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background {
                            if on { Capsule().fill(Theme.red).matchedGeometryEffect(id: "pill", in: pill) }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(s.title) (⌘\(String(s.key.character)))")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Capsule().fill(Theme.surface))
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                Circle().fill(colony.online ? Theme.safe : Theme.swarm).frame(width: 7, height: 7)
                Text(colony.online ? "\(colony.antsOut) ants out" : (colony.problem ?? "Waking the colony…"))
                    .font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            DriveModeSwitch()
            Button { go(.settings) } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(nav.section == .settings ? Theme.onAccent : Theme.text)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(nav.section == .settings ? Theme.red : Theme.surface))
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.leading, 84)   // the window's traffic lights
        .padding(.trailing, 18)
        .frame(height: 58)
        .background(Theme.deep)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func go(_ s: Nav.Section) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { nav.section = s }
    }

    /// Small live counts beside each tab.
    private func badge(_ s: Nav.Section) -> (String, Color)? {
        switch s {
        case .downloads:
            let n = colony.trail.filter { $0.state == .active || $0.state == .waiting }.count
            return n > 0 ? ("\(n)", Theme.swarmText) : nil
        case .drive:
            let n = up.jobs.count + colony.carrying.count + colony.unpacking.count
            return n > 0 ? ("\(n) ↑", Theme.red) : nil
        case .grabber:
            let n = night.waiting.count
            return n > 0 ? ("☾ \(n)", Theme.nightAnt) : nil
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

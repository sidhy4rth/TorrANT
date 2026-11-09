import SwiftUI
import AppKit

@main
struct TorrANTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        Theme.registerFonts()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-icon"), i + 1 < args.count {
            MainActor.assumeIsolated { IconExporter.export(to: args[i + 1]) }
            exit(0)
        }
    }

    var body: some Scene {
        // One window for everything: Downloads, Library, Google Drive and the Link Grabber
        // are sections in its sidebar, not separate windows.
        Window("TorrANT", id: "colony") {
            RootView()
                .frame(minWidth: 1240, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1460, height: 880)
        .commands { ColonyCommands() }

        MenuBarExtra {
            AntCam()
        } label: {
            Image(nsImage: MenuIcon.image)
        }
        .menuBarExtraStyle(.window)


    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.setup()
        MainActor.assumeIsolated {
            NetWatch.shared.start()
            Colony.shared.boot()
            PhoneLink.shared.start()
            // Give macOS a moment to say whether this is a hotspot before preloading anything.
            // A plain main-queue timer: a Task started here never woke from its sleep (8 Nov).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    Streamer.shared.warmUp()   // stream server + preload ready before the first ▶
                    HomeShare.shared.start()   // only if you turned it on
                    Task { await LibraryStore.shared.refresh() }   // posters for anything new, without opening the Library
                }
            }
            NightShift.shared.begin()
            Speed.shared.begin()
        }
        Catcher.shared.start()
    }

    /// magnet: links and .torrent files opened from Finder / the browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            Colony.shared.boot()
            for _ in 0..<30 where !Colony.shared.online { try? await Task.sleep(for: .milliseconds(200)) }
            for u in urls {
                if u.isFileURL { await Colony.shared.openTorrent(u) } else { await Colony.shared.send(u.absoluteString) }
            }
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Catcher.shared.stop()
        MainActor.assumeIsolated {
            HomeShare.shared.stop()
            Uploader.shared.stop()
            Streamer.shared.stop()
            Colony.shared.shutdown()
        }
    }
}

struct ColonyCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    /// Switch the one window to a section (and bring it up if it was closed).
    private func show(_ s: Nav.Section) {
        Nav.shared.section = s
        openWindow(id: "colony")
        NSApp.activate()
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { show(.settings) }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("Send the Ants to the Clipboard Link") {
                if let s = NSPasteboard.general.string(forType: .string) { Task { await Colony.shared.send(s) } }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandMenu("Colony") {
            Button("Let All Ants Rest") { Task { await Colony.shared.restAll() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Wake All Ants") { Task { await Colony.shared.wakeAll() } }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            ForEach(Nav.Section.allCases.filter { $0 != .settings }) { s in
                Button(s == .grabber ? "Link Grabber & Night Shift" : s.title) { show(s) }
                    .keyboardShortcut(s.key, modifiers: .command)
            }
            Divider()
            Button("Google Drive Uploads") { show(.drive) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Library") { show(.library) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Link Grabber & Night Shift") { show(.grabber) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }
}

/// Screen 4: Ant Cam — the menu bar panel.
struct AntCam: View {
    @Environment(\.openWindow) private var openWindow
    @State private var input = ""
    private var colony: Colony { Colony.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                AntGlyph(color: Theme.red).frame(width: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ant Cam").font(Theme.display(19))
                    EveryFrame(active: colony.anythingMoving, fps: 15) { now in
                        Text("\(colony.trail.filter { $0.state == .active }.count) on the trail · \(Fmt.liveSpeed(colony.liveDown(now))) coming home")
                            .font(Theme.body(13)).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                }
                Spacer()
            }
            .padding(16)
            Rectangle().fill(Theme.surface2).frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    TextField("", text: $input, prompt: Text("Paste a link or magnet").foregroundColor(Theme.muted))
                        .textFieldStyle(.plain).font(Theme.body(14))
                        .onSubmit(send)
                    Button("Send", action: send).buttonStyle(RedButtonStyle())
                }
                .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 4)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().strokeBorder(Theme.lineSoft, style: StrokeStyle(lineWidth: 2, dash: [6, 5])))

                if let s = colony.spotted {
                    HStack(spacing: 10) {
                        AntSketch(pose: .alert, animated: false).frame(width: 64)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Crumb spotted!").font(Theme.body(14, .bold))
                            Text(s).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Grab") { Task { await colony.grabSpotted() } }.buttonStyle(RedButtonStyle())
                    }
                }

                if colony.trail.isEmpty {
                    Text("No crumbs on the trail.").font(Theme.body(14)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                }
                ForEach(colony.trail.prefix(4)) { c in
                    EveryFrame(active: c.isMoving, fps: 15) { now in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(c.name).font(Theme.body(14, .semibold)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(c.state == .paused ? "zzz" : Fmt.clock(c.liveEta(now))).font(Theme.body(14, .bold)).monospacedDigit()
                            }
                            Capsule().fill(Theme.deep).frame(height: 10)
                                .overlay(alignment: .leading) {
                                    GeometryReader { g in
                                        Capsule().fill(c.state == .paused ? Theme.rest : (c.kind == .swarm ? Theme.swarm : Theme.crumb))
                                            .frame(width: g.size.width * c.liveProgress(now))
                                    }
                                }
                            HStack {
                                Text(c.kind == .swarm ? "SWARM" : "CRUMB").font(Theme.body(12, .bold))
                                    .foregroundStyle(c.kind == .swarm ? Theme.swarmText : Theme.crumbText)
                                Spacer()
                                Text("\(c.connections) ants · \(Fmt.liveSpeed(c.liveDown(now)))").font(Theme.body(12)).monospacedDigit()
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }

                if let h = colony.lastHome, Date().timeIntervalSince(h.date) < 600 {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(Theme.soil).frame(width: 32, height: 32).background(Circle().fill(Theme.safe))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(h.name) is home!").font(Theme.body(14, .bold)).lineLimit(1)
                            Text("Taste-tested, safe to open.").font(Theme.body(13)).foregroundStyle(Color(hex: 0xD6E8CF))
                        }
                        Spacer()
                        Button("Open") { Colony.shared.open(h) }.buttonStyle(.plain).foregroundStyle(Theme.safe).font(Theme.body(14, .bold))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x1F3A1C)))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0x3F6B37)))
                }

                HStack(spacing: 8) {
                    Button("Rest all ants") { Task { await colony.restAll() } }
                        .buttonStyle(GhostButtonStyle()).frame(maxWidth: .infinity)
                    Button("Open the colony") {
                        openWindow(id: "colony")
                        NSApp.activate()
                    }
                    .buttonStyle(RedButtonStyle()).frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .frame(width: 370)
        .background(Theme.soil)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
    }

    private func send() {
        let t = input
        input = ""
        Task { await colony.send(t) }
    }
}

struct SettingsView: View {
    @Bindable private var colony = Colony.shared
    @State private var magnetNote = ""
    @State private var keepAwake = Awake.shared.enabled

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 18) {
                SettingsCard("Downloads", icon: "arrow.down.circle.fill", color: Theme.carrierAnt) { downloads }
                SettingsCard("Speed", icon: "gauge.with.dots.needle.67percent", color: Theme.flyerAnt) { SpeedSettings() }
                SettingsCard("Phone", icon: "iphone", color: Theme.nightAnt) { PhoneSettings() }
            }
            VStack(spacing: 18) {
                SettingsCard("Google Drive", icon: "icloud.fill", color: Theme.librarianAnt) { drive }
                SettingsCard("Network and privacy", icon: "lock.shield.fill", color: Theme.nightAnt) { privacy }
                SettingsCard("Brave", icon: "globe", color: Theme.carrierAnt) { brave }
            }
        }
        .padding(22)
        .frame(maxWidth: 1180, alignment: .topLeading)
        .background(Theme.soil)
        .foregroundStyle(Theme.text)
    }

    private func note(_ t: String, indent: Bool = false) -> some View {
        Text(t).font(Theme.body(12)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, indent ? 20 : 0)
    }

    private var downloads: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Where the ants store things").font(Theme.body(14, .semibold))
                HStack {
                    Text(colony.downloadDir.path).font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        p.directoryURL = colony.downloadDir
                        if p.runModal() == .OK, let u = p.url { colony.downloadDir = u }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Where downloads go").font(Theme.body(14, .semibold))
                Picker("", selection: Binding(get: { Uploader.shared.straightToDrive },
                                              set: { Uploader.shared.straightToDrive = $0 })) {
                    Text("This Mac").tag(false)
                    Text("Straight to Google Drive").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                note("Straight to Google Drive: links go directly into Drive and never touch this Mac. Torrents and Brave downloads land here first, then are unpacked, uploaded and deleted on their own.")
            }
            Toggle("Watch the clipboard for crumbs (download links and magnets)", isOn: Binding(
                get: { colony.watchClipboard }, set: { colony.watchClipboard = $0 }))
                .toggleStyle(.checkbox)
                .font(Theme.body(14))
            VStack(alignment: .leading, spacing: 6) {
                Button("Open magnet links with TorrANT") {
                    Task {
                        do {
                            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "magnet")
                            magnetNote = "Done. Magnet links now go to your ants."
                        } catch {
                            magnetNote = "macOS said no: \(error.localizedDescription)"
                        }
                    }
                }
                if !magnetNote.isEmpty { Text(magnetNote).font(Theme.body(13)).foregroundStyle(Theme.muted) }
            }
        }
    }

    private var drive: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Google Drive folder").font(Theme.body(14, .semibold))
                HStack {
                    Text(colony.driveDir?.path ?? "Google Drive isn't installed yet")
                        .font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if colony.driveDirPath != nil {
                        Button("Auto") { colony.driveDirPath = nil }
                            .help("Use the TorrANT folder in Google Drive")
                    }
                    Button("Change…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        p.canCreateDirectories = true
                        p.directoryURL = colony.driveDir ?? Colony.findDrive()
                        if p.runModal() == .OK, let u = p.url { colony.driveDirPath = u.path }
                    }
                }
                note("Hover a finished download and press the cloud to move it there, or use the Google Drive page.")
            }
            HomeShareSettings()
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Encrypted torrent connections only", isOn: Binding(
                    get: { colony.requireCrypto }, set: { colony.requireCrypto = $0 }))
                    .toggleStyle(.checkbox)
                    .font(Theme.body(14))
                note("Turn on if your internet provider slows down torrents. Fewer people can connect, so leave it off otherwise.", indent: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Keep the Mac awake while the ants work", isOn: Binding(
                    get: { keepAwake }, set: { keepAwake = $0; Awake.shared.enabled = $0 }))
                    .toggleStyle(.checkbox)
                    .font(Theme.body(14))
                note("Covers downloads and Google Drive uploads. The screen can still turn off. Closing a MacBook's lid still pauses everything unless it's plugged into a monitor.", indent: true)
            }
        }
    }

    private var brave: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Catch every Brave download").font(Theme.body(14, .semibold))
            note("In Brave, open brave://extensions, turn on Developer mode, click Load unpacked and pick the TorrANT Catcher folder.")
            Button("Show the extension folder") { Catcher.revealExtension() }
        }
    }
}

/// One group of settings: an icon in its ant colour, a title, then the controls.
struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: Content
    @State private var shown = false

    init(_ title: String, icon: String, color: Color, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.color = color; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.14)))
                Text(title).font(Theme.display(19))
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 12)
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { shown = true } }
    }
}

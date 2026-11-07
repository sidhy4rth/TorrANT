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
        Window("TorrANT", id: "colony") {
            ColonyView()
                .frame(minWidth: 1080, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands { ColonyCommands() }

        MenuBarExtra {
            AntCam()
        } label: {
            Image(nsImage: MenuIcon.image)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.setup()
        MainActor.assumeIsolated { Colony.shared.boot() }
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
        MainActor.assumeIsolated { Colony.shared.shutdown() }
    }
}

struct ColonyCommands: Commands {
    var body: some Commands {
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
                AntGlyph(color: Theme.honey).frame(width: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ant Cam").font(Theme.display(19))
                    Text("\(colony.trail.filter { $0.state == .active }.count) on the trail · \(Fmt.speed(colony.down)) coming home")
                        .font(Theme.body(13)).foregroundStyle(Theme.muted)
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
                    Button("Send", action: send).buttonStyle(HoneyButtonStyle())
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
                        Button("Grab") { Task { await colony.grabSpotted() } }.buttonStyle(HoneyButtonStyle())
                    }
                }

                if colony.trail.isEmpty {
                    Text("No crumbs on the trail.").font(Theme.body(14)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                }
                ForEach(colony.trail.prefix(4)) { c in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(c.name).font(Theme.body(14, .semibold)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(c.state == .paused ? "zzz" : Fmt.eta(c.eta)).font(Theme.body(14, .bold))
                        }
                        Capsule().fill(Theme.deep).frame(height: 10)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in
                                    Capsule().fill(c.state == .paused ? Theme.rest : (c.kind == .swarm ? Theme.swarm : Theme.crumb))
                                        .frame(width: g.size.width * c.progress)
                                }
                            }
                        HStack {
                            Text(c.kind == .swarm ? "SWARM" : "CRUMB").font(Theme.body(12, .bold))
                                .foregroundStyle(c.kind == .swarm ? Theme.swarmText : Theme.crumbText)
                            Spacer()
                            Text("\(c.connections) ants · \(Fmt.speed(c.down))").font(Theme.body(12)).foregroundStyle(Theme.muted)
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
                    .buttonStyle(HoneyButtonStyle()).frame(maxWidth: .infinity)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Colony settings").font(Theme.display(22))
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
            Spacer()
        }
        .padding(24)
        .frame(width: 520, height: 300)
        .background(Theme.soil)
        .foregroundStyle(Theme.text)
    }
}

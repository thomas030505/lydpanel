import SwiftUI
import AppKit

@main
struct LydpanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AudioModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
                .onAppear { delegate.model = model }
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if model.masterMuted || model.masterVolume < 0.001 { return "speaker.slash.fill" }
        if model.masterVolume < 0.34 { return "speaker.wave.1.fill" }
        if model.masterVolume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AudioModel?
    private var snapshotWindow: NSWindow?

    /// `Lydpanel --snapshot <fil.png> [--dark] [--hide <navn>]` tegner panelet til en PNG og avslutter.
    /// Brukes til skjermbildene i README. Rører aldri lyden og lagrer ingenting.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        let dark = args.contains("--dark")
        // `--hide <navn>` (kan gjentas) skjuler apper du ikke vil vise på bildet.
        let hidden = args.indices.filter { args[$0] == "--hide" && $0 + 1 < args.count }.map { args[$0 + 1] }
        let snapModel = AudioModel(
            preview: true,
            previewSettings: [
                "com.spotify.client": AppSetting(volume: 0.6, muted: false),
                "com.apple.mail": AppSetting(volume: 1, muted: true),
            ],
            previewDeviceName: "AirPods Pro",
            previewHidden: hidden
        )
        let panel = PanelView()
            .environmentObject(snapModel)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1)))
            .padding(36)
        let host = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        snapshotWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            print("apper:", snapModel.apps.map { "\($0.name)\($0.isPlaying ? " (spiller)" : "")" })
            exit(0)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Slipp alle taps så appene får tilbake vanlig lyd.
        model?.shutdown()
    }
}

// MARK: - Panel

struct PanelView: View {
    @EnvironmentObject var model: AudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            master
            appsSection
            if let err = model.tapError { errorBanner(err) }
            Divider().padding(.horizontal, 4)
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Lyd").font(.system(size: 13, weight: .semibold))
            Spacer()
            Menu {
                ForEach(model.devices) { dev in
                    Button {
                        model.selectDevice(dev)
                    } label: {
                        if dev.id == model.currentDevice {
                            Label(dev.name, systemImage: "checkmark")
                        } else {
                            Text(dev.name)
                        }
                    }
                }
            } label: {
                Label(model.currentDeviceName, systemImage: deviceSymbol)
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var deviceSymbol: String {
        let n = model.currentDeviceName.lowercased()
        if n.contains("airpods") { return "airpods" }
        if n.contains("headphone") || n.contains("hodetelefon") { return "headphones" }
        if n.contains("display") || n.contains("hdmi") || n.contains("skjerm") { return "display" }
        return "hifispeaker"
    }

    private var master: some View {
        Card {
            HStack(spacing: 10) {
                MuteButton(muted: model.masterMuted, level: model.masterVolume) {
                    model.setMasterMuted(!model.masterMuted)
                }
                .disabled(!model.canMute)
                Slider(value: Binding(
                    get: { Double(model.masterMuted ? 0 : model.masterVolume) },
                    set: { model.setMasterVolume(Float($0)) }
                ), in: 0...1)
                .controlSize(.small)
                .disabled(!model.canSetVolume)
                Percent(value: model.masterMuted ? 0 : model.masterVolume)
            }
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apper")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            if model.apps.isEmpty {
                Card {
                    Text("Ingen apper bruker lyd akkurat nå.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            } else {
                Card(padding: 4) {
                    let rows = VStack(spacing: 0) {
                        ForEach(model.apps) { app in
                            AppRow(app: app)
                        }
                    }
                    // Menylinje-vinduet gir en ScrollView null høyde, så den får fast høyde
                    // bare når listen er for lang; ellers vises radene rett.
                    if model.apps.count <= 7 {
                        rows
                    } else {
                        ScrollView { rows }
                            .frame(height: 7.5 * 43)
                    }
                }
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                Button("Åpne innstillinger for lydopptak") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            Spacer(minLength: 0)
            Button { model.tapError = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Toggle("Start ved innlogging", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            Spacer()
            Button("Lydinnstillinger …") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            Button("Avslutt") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Rader og byggeklosser

struct AppRow: View {
    @EnvironmentObject var model: AudioModel
    let app: AppEntry
    @State private var hovering = false

    var body: some View {
        let s = model.setting(for: app.id)
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 24, height: 24)
                .opacity(s.muted ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if app.isPlaying && !s.muted {
                        Circle().fill(.green).frame(width: 5, height: 5)
                            .help("Spiller lyd nå")
                    }
                    Spacer(minLength: 0)
                    if !s.isDefault && hovering {
                        Button("Nullstill") { model.reset(app.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(s.muted ? 0 : s.volume) },
                        set: { model.setVolume(Float($0), for: app.id) }
                    ), in: 0...1)
                    .controlSize(.mini)
                    Percent(value: s.muted ? 0 : s.volume)
                }
            }

            MuteButton(muted: s.muted, level: s.volume, size: 24) {
                model.toggleMute(for: app.id)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
    }
}

struct MuteButton: View {
    let muted: Bool
    let level: Float
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(muted ? Color.white : Color.primary.opacity(0.75))
                .frame(width: size, height: size)
                .background(muted ? Color.red.opacity(0.85) : Color.primary.opacity(0.08), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(muted ? "Slå på lyd" : "Demp")
    }

    private var symbol: String {
        if muted || level < 0.001 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

struct Percent: View {
    let value: Float
    var body: some View {
        Text("\(Int((value * 100).rounded())) %")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 38, alignment: .trailing)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(padding)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06)))
    }
}

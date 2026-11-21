import AppKit
import CoreAudio
import Combine
import ServiceManagement

struct AppSetting: Codable, Equatable {
    var volume: Float = 1
    var muted = false
    var isDefault: Bool { volume >= 0.999 && !muted }
    /// Slideren er lineær, øret er ikke: kvadrer for en jevnere kurve.
    var gain: Float { muted ? 0 : volume * volume }
}

struct AppEntry: Identifiable {
    let id: String          // bundle-ID (eller pid hvis appen mangler)
    let name: String
    let icon: NSImage
    let processIDs: [AudioObjectID]
    let isPlaying: Bool
}

final class AudioModel: ObservableObject {
    // Hovedvolum
    @Published private(set) var masterVolume: Float = 0
    @Published private(set) var masterMuted = false
    @Published private(set) var canSetVolume = true
    @Published private(set) var canMute = true

    // Enheter
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var currentDevice = AudioObjectID(kAudioObjectUnknown)

    // Apper
    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var settings: [String: AppSetting] = [:]
    @Published var tapError: String?

    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var taps: [String: AppTap] = [:]
    private var watchedDevice = AudioObjectID(kAudioObjectUnknown)
    private var timer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private lazy var deviceVolumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.readMasterVolume()
    }
    private lazy var defaultDeviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.defaultDeviceChanged()
    }
    private lazy var deviceListListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.devices = listOutputDevices()
    }

    /// Forhåndsvisning (skjermbilder): rører aldri lyden og lagrer ingenting.
    private let preview: Bool
    private let previewDeviceName: String?
    /// Apper som ikke skal vises på skjermbilder (treff på navn).
    private let previewHidden: [String]

    init(preview: Bool = false, previewSettings: [String: AppSetting] = [:], previewDeviceName: String? = nil, previewHidden: [String] = []) {
        self.preview = preview
        self.previewDeviceName = previewDeviceName
        self.previewHidden = previewHidden
        if preview {
            settings = previewSettings
        } else if let data = UserDefaults.standard.data(forKey: "appSettings"),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) {
            settings = saved
        }

        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(systemObject, &a, .main, defaultDeviceListener)
        var d = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObject, &d, .main, deviceListListener)

        devices = listOutputDevices()
        defaultDeviceChanged()

        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshApps()
        }
    }

    // MARK: Hovedvolum og enhet

    var currentDeviceName: String {
        previewDeviceName ?? devices.first { $0.id == currentDevice }?.name ?? "Utgang"
    }

    func setMasterVolume(_ v: Float) {
        masterVolume = v
        setValue(currentDevice, volumeAddress, Float32(v))
        if masterMuted && v > 0 { setMasterMuted(false) }
    }

    func setMasterMuted(_ m: Bool) {
        masterMuted = m
        setValue(currentDevice, muteAddress, UInt32(m ? 1 : 0))
    }

    func selectDevice(_ dev: OutputDevice) {
        setDefaultOutputDevice(dev.id)
    }

    private func defaultDeviceChanged() {
        let dev = defaultOutputDevice()
        if watchedDevice != kAudioObjectUnknown {
            var v = volumeAddress, m = muteAddress
            AudioObjectRemovePropertyListenerBlock(watchedDevice, &v, .main, deviceVolumeListener)
            AudioObjectRemovePropertyListenerBlock(watchedDevice, &m, .main, deviceVolumeListener)
        }
        watchedDevice = dev
        currentDevice = dev
        var v = volumeAddress, m = muteAddress
        AudioObjectAddPropertyListenerBlock(dev, &v, .main, deviceVolumeListener)
        AudioObjectAddPropertyListenerBlock(dev, &m, .main, deviceVolumeListener)
        readMasterVolume()

        // Lyden skal følge den nye utgangen: bygg alle app-taps på nytt.
        taps.removeAll()
        refreshApps()
    }

    private func readMasterVolume() {
        let dev = currentDevice
        canSetVolume = hasProperty(dev, volumeAddress) && isSettable(dev, volumeAddress)
        canMute = hasProperty(dev, muteAddress) && isSettable(dev, muteAddress)
        masterVolume = getValue(dev, volumeAddress, default: Float32(1))
        masterMuted = getValue(dev, muteAddress, default: UInt32(0)) != 0
    }

    // MARK: Apper

    func setting(for id: String) -> AppSetting { settings[id] ?? AppSetting() }

    func setVolume(_ v: Float, for id: String) {
        var s = setting(for: id)
        s.volume = v
        if v > 0.001 { s.muted = false }
        update(s, for: id)
    }

    func toggleMute(for id: String) {
        var s = setting(for: id)
        s.muted.toggle()
        if !s.muted && s.volume < 0.01 { s.volume = 1 }
        update(s, for: id)
    }

    func reset(_ id: String) { update(AppSetting(), for: id) }

    private func update(_ s: AppSetting, for id: String) {
        settings[id] = s.isDefault ? nil : s
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "appSettings")
        }
        if let app = apps.first(where: { $0.id == id }) { applyTap(for: app) }
    }

    func refreshApps() {
        var groups: [String: (app: NSRunningApplication?, name: String, ids: [AudioObjectID], playing: Bool)] = [:]

        for p in listAudioProcesses() where p.pid > 0 && p.pid != ownPID {
            guard let app = owningApp(of: p), app.processIdentifier != ownPID else { continue }
            if preview, let name = app.localizedName,
               previewHidden.contains(where: { name.localizedCaseInsensitiveContains($0) }) { continue }
            let key = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
            var g = groups[key] ?? (app, app.localizedName ?? key, [], false)
            g.ids.append(p.objectID)
            g.playing = g.playing || p.isPlaying
            groups[key] = g
        }

        let entries = groups.map { key, g in
            AppEntry(id: key,
                     name: g.name,
                     icon: g.app?.icon ?? NSWorkspace.shared.icon(for: .application),
                     processIDs: g.ids.sorted(),
                     isPlaying: g.playing)
        }
        .sorted { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        apps = entries
        for app in entries { applyTap(for: app) }
        // Rydd bort taps for apper som ikke finnes lenger.
        let live = Set(entries.map(\.id))
        for key in taps.keys where !live.contains(key) { taps[key] = nil }
    }

    private func owningApp(of p: AudioProcess) -> NSRunningApplication? {
        func regular(_ pid: pid_t) -> NSRunningApplication? {
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return nil }
            return app
        }
        if let app = regular(p.pid) { return app }
        if let r = responsiblePID(for: p.pid), r != p.pid, let app = regular(r) { return app }
        if let b = p.bundleID {
            return NSWorkspace.shared.runningApplications.first { app in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
                return b.hasPrefix(id + ".")
            }
        }
        return nil
    }

    private func applyTap(for app: AppEntry) {
        guard !preview else { return }
        let s = setting(for: app.id)
        guard !s.isDefault else { taps[app.id] = nil; return }

        guard let uid = getString(currentDevice, address(kAudioDevicePropertyDeviceUID)) else { return }
        if let tap = taps[app.id], tap.processIDs == app.processIDs, tap.outputUID == uid {
            tap.setGain(s.gain)
            return
        }
        taps[app.id] = nil
        do {
            taps[app.id] = try AppTap(processIDs: app.processIDs, outputUID: uid, gain: s.gain)
            tapError = nil
        } catch {
            tapError = "\(app.name): \(error.localizedDescription)"
        }
    }

    func shutdown() {
        timer?.invalidate()
        taps.removeAll()
    }

    // MARK: Oppstart ved innlogging

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            tapError = "Start ved innlogging: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

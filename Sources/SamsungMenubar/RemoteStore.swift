import SwiftUI
import AppKit

struct RemoteEvent: Identifiable, Codable { let id: UUID; let date: Date; let title: String; let detail: String
    init(title: String, detail: String) { id = UUID(); date = Date(); self.title = title; self.detail = detail }
}

/// Turns touchpad drags into arrow presses: one step per `threshold` points along the dominant axis.
struct SwipeTracker {
    var threshold: CGFloat = 38
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    mutating func add(dx: CGFloat, dy: CGFloat) -> [String] {
        x += dx; y += dy
        var keys: [String] = []
        while keys.count < 6 && (abs(x) >= threshold || abs(y) >= threshold) {
            if abs(x) >= abs(y) { keys.append(x > 0 ? "KEY_RIGHT" : "KEY_LEFT"); x -= x > 0 ? threshold : -threshold; y = 0 }
            else { keys.append(y > 0 ? "KEY_DOWN" : "KEY_UP"); y -= y > 0 ? threshold : -threshold; x = 0 }
        }
        if keys.count == 6 { reset() }
        return keys
    }
    mutating func reset() { x = 0; y = 0 }
}

/// Live TV, HDMI inputs and the Home screen report no visible app.
let otherSourceID = "tv.other"

@MainActor final class RemoteStore: ObservableObject {
    @Published var host = TVConfiguration().host
    @Published var name = TVConfiguration().name
    @Published var model = TVConfiguration().model
    @Published var mac = TVConfiguration().mac
    @Published var connected = false
    @Published var connecting = false
    @Published var pairing = false
    @Published var discovering = false
    @Published var devices: [TVDevice] = []
    @Published var apps: [TVApp] = []
    @Published var icons: [String: NSImage] = [:]
    @Published var iconColors: [String: Color] = [:]
    @Published var volume: Double = 0
    @Published var hasVolume = false
    @Published var muted = false
    @Published var powerOn = false
    @Published var foregroundID = ""
    @Published var foregroundName = ""
    @Published var error: String?
    @Published var notice: String?
    @Published var events: [RemoteEvent] = []
    @Published var tvOS = ""
    @Published var resolution = ""
    @Published var usageRevision = 0
    @Published var mediaFile: URL?
    @Published var mediaBusy = false
    @Published var casting = false
    @Published var mediaStatus = "Choose a video, a song, or a photo."
    @Published var preferredPanelHeight: CGFloat = 740
    @Published var favorites = Set(UserDefaults.standard.stringArray(forKey: "tv.favorites") ?? [])
    private(set) var connection: SamsungConnection?
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var autoReconnect = false
    private var reconnectDelay: UInt64 = 5
    @Published var waking = false
    private var wakeTask: Task<Void, Never>?
    private var renderingControl: URL?
    private let dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("br.local.SamsungRemote")
    private lazy var journal = UsageJournal(url: dataDirectory.appendingPathComponent("usage.json"))
    private var observers: [NSObjectProtocol] = []
    private var fileServer: MediaFileServer?
    private var transportURL: URL?
    private var swipe = SwipeTracker()
    init() {
        events = (try? JSONDecoder().decode([RemoteEvent].self, from: Data(contentsOf: dataDirectory.appendingPathComponent("events.json")))) ?? []
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseUsage() }
        })
    }

    var pinnedApps: [TVApp] { shortcuts.filter { favorites.contains($0.id) } }
    func log(_ title: String, _ detail: String) {
        events.insert(RemoteEvent(title: title, detail: detail), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
        if title != "Read" {
            let persisted = events.filter { $0.title != "Read" }
            do { try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true); try JSONEncoder().encode(persisted).write(to: dataDirectory.appendingPathComponent("events.json"), options: .atomic) }
            catch { notice = "Could not save the local event history." }
        }
    }

    var status: String { pairing ? "Allow the connection on your TV" : connecting ? "Connecting…" : connected ? (powerOn ? "Connected" : "Connected · standby") : "Disconnected" }
    var currentApp: String { foregroundName.isEmpty ? (connected ? "TV is on" : "Your TV, on your Mac.") : foregroundName }
    var currentAppIcon: NSImage? { icons[foregroundID] }
    var shortcuts: [TVApp] {
        let preferred = ["netflix", "youtube", "prime", "disney", "globoplay", "spotify", "hbo", "apple"]
        return apps.sorted { a, b in
            if favorites.contains(a.id) != favorites.contains(b.id) { return favorites.contains(a.id) }
            let ai = preferred.firstIndex { a.title.localizedCaseInsensitiveContains($0) } ?? 100
            let bi = preferred.firstIndex { b.title.localizedCaseInsensitiveContains($0) } ?? 100
            return ai != bi ? ai < bi : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
    func connect(allowFirstUseTrust: Bool = true) {
        guard !connecting else { return }
        guard SamsungConnection.localHost(host) else { error = "Enter the TV's local IPv4 address or discover a TV on your network."; return }
        autoReconnect = true; error = nil; connecting = true; pairing = false
        pauseUsage()
        connection?.close(); refreshTask?.cancel(); reconnectTask?.cancel()
        let client = SamsungConnection(host: host); connection = client
        client.onCertificateTrust = { host, fingerprint in
            await ConnectionTrustPrompt.confirm(host: host, fingerprint: fingerprint)
        }
        client.onPairing = { [weak self] in self?.pairing = true }
        client.onEvent = { [weak self] title, detail in self?.log(title, detail) }
        client.onDisconnect = { [weak self, weak client] failure in
            guard let self, self.connection === client else { return }
            self.connected = false; self.hasVolume = false; self.powerOn = false; self.refreshTask?.cancel()
            self.pauseUsage()
            self.log("Connection lost", RemoteError.describe(failure))
            if !self.connecting {
                self.notice = "Connection lost. Reconnecting…"
                self.scheduleReconnect()
            }
        }
        connectTask = Task {
            do {
                try await client.connect(allowFirstUseTrust: allowFirstUseTrust)
                guard connection === client else { return }
                connected = true; connecting = false; pairing = false; notice = nil; reconnectDelay = 5
                log("Connected", "\(name) · \(host)")
                UserDefaults.standard.set(host, forKey: "tv.host")
                UserDefaults.standard.set(name, forKey: "tv.name")
                if let info = try? await client.deviceInfo() { apply(info) } else { powerOn = true }
                UserDefaults.standard.set(mac, forKey: "tv.mac")
                UserDefaults.standard.set(model, forKey: "tv.model")
                await refresh()
                refreshTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        if Task.isCancelled { break }
                        await refreshState()
                    }
                }
            } catch {
                guard connection === client else { return }
                client.close(); connected = false; connecting = false; pairing = false
                let reason = RemoteError.describe(error)
                if reason != error.localizedDescription { self.error = reason }
                else if allowFirstUseTrust {
                    self.error = "\(reason) Make sure the TV is on and on the same Wi-Fi network."
                    autoReconnect = false
                } else { notice = waking ? "Waking the TV… this takes about 15 seconds." : "TV unreachable. Retrying in \(reconnectDelay) s." }
                log("Connection failed", reason)
                scheduleReconnect()
            }
        }
    }
    private func apply(_ info: [String: Any]) {
        if let modelName = info["modelName"] as? String, !modelName.isEmpty { model = modelName }
        if mac.isEmpty, let wifi = info["wifiMac"] as? String, TVDiscovery.validMAC(wifi) { mac = wifi.uppercased() }
        tvOS = info["OS"] as? String ?? ""
        resolution = info["resolution"] as? String ?? ""
        powerOn = (info["PowerState"] as? String ?? "on").lowercased() == "on"
        if powerOn { finishWaking() }
    }
    /// Retries with backoff so a TV switched on with its own remote reconnects by itself.
    private func scheduleReconnect() {
        guard autoReconnect else { return }
        reconnectTask?.cancel()
        // While a wake is in progress, poll quickly so the remote is ready as soon as the TV is.
        let delay = waking ? 3 : reconnectDelay
        if !waking { reconnectDelay = min(30, reconnectDelay * 2) }
        reconnectTask = Task { try? await Task.sleep(nanoseconds: delay * 1_000_000_000); if !Task.isCancelled { connect(allowFirstUseTrust: false) } }
    }
    func disconnect() {
        pauseUsage()
        fileServer?.stop(); fileServer = nil; casting = false; transportURL = nil
        autoReconnect = false; connectTask?.cancel(); reconnectTask?.cancel(); refreshTask?.cancel(); volumeTask?.cancel()
        connection?.close(); connection = nil; connected = false; connecting = false; pairing = false; hasVolume = false; powerOn = false
        foregroundID = ""; foregroundName = ""; renderingControl = nil
    }
    func discover() {
        guard !discovering else { return }; discovering = true; error = nil
        Task { devices = await TVDiscovery.search(); discovering = false; if devices.isEmpty { notice = "No TV found. Turn on your TV or enter its IP address below." } }
    }
    func select(_ tv: TVDevice) {
        disconnect(); host = tv.host; name = tv.name; model = tv.model; mac = tv.mac ?? ""
        connect()
    }
    func refresh() async {
        guard let client = connection, connected else { return }
        do {
            apps = try await client.installedApps()
            if UserDefaults.standard.stringArray(forKey: "tv.favorites") == nil {
                let defaults = ["netflix", "youtube", "prime video", "disney"]
                favorites = Set(apps.filter { app in defaults.contains { app.title.localizedCaseInsensitiveContains($0) } }.map(\.id))
                UserDefaults.standard.set(Array(favorites), forKey: "tv.favorites")
            }
        } catch { self.error = "Could not list apps: \(error.localizedDescription)" }
        if renderingControl == nil { renderingControl = try? await DLNATransport.discover(host: host).renderingControl }
        await refreshState()
        await loadIcons(client)
    }
    private func loadIcons(_ client: SamsungConnection) async {
        let folder = dataDirectory.appendingPathComponent("icons")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for app in apps where icons[app.id] == nil && SamsungProtocol.validAppID(app.id) {
            let file = folder.appendingPathComponent(app.id + ".img")
            var data = try? Data(contentsOf: file)
            if data == nil, !app.iconPath.isEmpty, connection === client, connected {
                data = try? await client.icon(path: app.iconPath)
                if let data, NSImage(data: data) != nil { try? data.write(to: file, options: .atomic) }
            }
            guard let data, let image = NSImage(data: data) else { continue }
            icons[app.id] = image
            iconColors[app.id] = BrandTheme.dominantColor(data)
        }
    }
    func refreshState() async {
        guard let client = connection, connected else { return }
        do { try await client.ping() } catch { client.dropped(error); return }
        if let info = try? await client.deviceInfo() { apply(info) }
        guard powerOn else { foregroundID = ""; foregroundName = "Standby"; pauseUsage(); return }
        await refreshVolume()
        await refreshForeground(client)
    }
    private func refreshVolume() async {
        guard let control = renderingControl, let answer = try? await DLNATransport.volume(control) else { return }
        volume = Double(answer.volume); muted = answer.muted; hasVolume = true
    }
    private func refreshForeground(_ client: SamsungConnection) async {
        var visible = ""
        if let current = apps.first(where: { $0.id == foregroundID }), (try? await client.appVisible(current.id)) == true {
            visible = current.id
        } else {
            let candidates = apps.map(\.id).filter { $0 != foregroundID }
            visible = await withTaskGroup(of: String?.self) { group in
                for id in candidates.prefix(40) { group.addTask { (try? await client.appVisible(id)) == true ? id : nil } }
                var found = ""
                for await id in group { if let id, found.isEmpty { found = id } }
                return found
            }
        }
        guard connection === client, connected else { return }
        let previous = foregroundID
        foregroundID = visible.isEmpty ? otherSourceID : visible
        foregroundName = apps.first(where: { $0.id == visible })?.title ?? "Live TV or input"
        if previous != foregroundID { log("Reported app", foregroundName) }
        journal.observe(host: host, appID: foregroundID, title: foregroundName); saveUsage()
    }
    func perform(_ action: @escaping (SamsungConnection) async throws -> Void) {
        guard connected, let client = connection else { return }
        error = nil
        Task { do { try await action(client) } catch { self.error = error.localizedDescription; self.log("Command failed", error.localizedDescription) } }
    }
    func press(_ key: String) {
        log("Remote", key)
        perform { client in
            try await client.key(key)
            if ["KEY_RETURN", "KEY_HOME", "KEY_EXIT", "KEY_ENTER", "KEY_SOURCE", "KEY_TV", "KEY_HDMI"].contains(key) {
                try? await Task.sleep(nanoseconds: 1_200_000_000); await self.refreshForeground(client)
            }
        }
    }
    func swipe(dx: CGFloat, dy: CGFloat) { for key in swipe.add(dx: dx, dy: dy) { press(key) } }
    func endSwipe() { swipe.reset() }
    /// Arrow keys, Return and Delete drive the TV while the panel has focus and no field is editing.
    func keyboard(_ keyCode: UInt16) -> Bool {
        let keys: [UInt16: String] = [123: "KEY_LEFT", 124: "KEY_RIGHT", 125: "KEY_DOWN", 126: "KEY_UP", 36: "KEY_ENTER", 76: "KEY_ENTER", 51: "KEY_RETURN"]
        guard connected, let key = keys[keyCode] else { return false }
        press(key); return true
    }
    func launch(_ app: TVApp) {
        log("Launch app", app.title)
        perform { client in try await client.launch(app); try? await Task.sleep(nanoseconds: 1_500_000_000); await self.refreshForeground(client) }
    }
    func changeVolume(_ value: Double) {
        volume = min(100, max(0, value)); volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let control = renderingControl, connected else { return }
            do { try await DLNATransport.setVolume(control, Int(volume)); await refreshVolume() }
            catch { self.error = error.localizedDescription }
        }
    }
    func volumeStep(_ up: Bool) {
        perform { client in try await client.key(up ? "KEY_VOLUP" : "KEY_VOLDOWN"); try? await Task.sleep(nanoseconds: 300_000_000); await self.refreshVolume() }
    }
    func toggleMute() {
        if let control = renderingControl {
            let target = !muted
            perform { _ in try await DLNATransport.setMute(control, target); await self.refreshVolume() }
        } else { press("KEY_MUTE") }
    }
    func sendText(_ text: String) { guard !text.isEmpty else { return }; perform { try await $0.text(text) } }
    /// Sends the Mac clipboard to the field open on the TV; surrounding whitespace and newlines are dropped.
    func sendClipboard() {
        let text = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { notice = "The clipboard has no text."; return }
        guard text.count <= 2000 else { error = "The clipboard text is too long for the TV (over 2,000 characters)."; return }
        log("Remote", "Paste clipboard (\(text.count) characters)")
        sendText(text)
        notice = "Sent \(text.count) characters to the TV."
    }
    func toggleFavorite(_ app: TVApp) {
        if favorites.contains(app.id) { favorites.remove(app.id) } else { favorites.insert(app.id) }
        UserDefaults.standard.set(Array(favorites), forKey: "tv.favorites")
    }
    private func saveUsage() {
        do { try journal.save() } catch { notice = "Could not save usage history." }
        usageRevision += 1
    }
    private func pauseUsage() { journal.pause(); saveUsage() }
    func usage(days: Int) -> [UsageTotal] {
        let since = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(max(0, days - 1)) * 86400)
        return journal.totals(host: host, since: since)
    }
    var mostUsedApps: [TVApp] { usage(days: 7).compactMap { total in apps.first { $0.id == total.id } } }
    func chooseMedia() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.movie, .audio, .image]; picker.prompt = "Select"; picker.title = "Send media to your Samsung TV"
        if picker.runModal() == .OK { mediaFile = picker.url; mediaStatus = "Ready to send. This will open the file on your TV." }
    }
    func castMedia() {
        guard !mediaBusy, connected, let file = mediaFile else { return }
        mediaBusy = true; error = nil
        let targetHost = host
        Task {
            defer { mediaBusy = false }
            var newServer: MediaFileServer?
            do {
                guard let control = try await DLNATransport.discover(host: targetHost).avTransport else { throw RemoteError.message("This TV does not accept media files.") }
                let server = MediaFileServer(file: file, allowedHost: targetHost); newServer = server
                let url = try await server.start()
                _ = try await DLNATransport.command(control, action: "SetAVTransportURI", parameters: [("CurrentURI", url.absoluteString), ("CurrentURIMetaData", DLNATransport.metadata(url: url, title: file.lastPathComponent, mime: server.mime))])
                _ = try await DLNATransport.command(control, action: "Play", parameters: [("Speed", "1")])
                fileServer?.stop(); fileServer = server; transportURL = control; casting = true
                mediaStatus = "Sent to TV · \(file.lastPathComponent)"; log("Send media", file.lastPathComponent)
            } catch { newServer?.stop(); self.error = error.localizedDescription; mediaStatus = "Could not play this file." }
        }
    }
    func controlCast(_ action: String) {
        guard casting, !mediaBusy, let control = transportURL, ["Play", "Pause", "Stop"].contains(action) else { return }
        mediaBusy = true
        Task {
            defer { mediaBusy = false }
            do {
                _ = try await DLNATransport.command(control, action: action, parameters: action == "Play" ? [("Speed", "1")] : [])
                if action == "Stop" { fileServer?.stop(); fileServer = nil; casting = false; mediaStatus = "Casting stopped." }
                else { mediaStatus = action == "Pause" ? "Media paused on TV." : "Playing on TV." }
            } catch { self.error = error.localizedDescription }
        }
    }
    func power() {
        if connected && powerOn {
            log("Remote", "KEY_POWER · turn off")
            perform { client in try await client.key("KEY_POWER"); self.disconnect(); self.notice = "TV turned off." }
        } else if connected {
            // A TV in standby may keep its socket open; send the power key and a wake signal.
            log("Remote", "KEY_POWER · turn on")
            perform { client in try await client.key("KEY_POWER") }
            if TVDiscovery.validMAC(mac) { sendWake(powerKeySent: true) }
        } else {
            guard TVDiscovery.validMAC(mac) else { error = "Add the TV's Wi-Fi MAC address in Settings to wake it."; return }
            sendWake()
            autoReconnect = true; scheduleReconnect()
        }
    }
    /// Wake-on-LAN packets are unacknowledged UDP, so send a short burst and watch for the TV.
    /// Wake-on-LAN packets are unacknowledged UDP, and a TV that has just turned off ignores them
    /// while it shuts down. Keep sending until the TV reports it is on; if it reaches network standby
    /// first, the socket accepts the power key, which is sent at most twice, 15 s apart, so a slow
    /// state report cannot toggle the TV back off.
    private func sendWake(powerKeySent: Bool = false) {
        let targetMAC = mac, targetHost = host
        do { try TVDiscovery.wake(mac: targetMAC, host: targetHost) } catch { self.error = error.localizedDescription; return }
        log("Wake", "Wake-on-LAN sent to \(([targetHost] + TVDiscovery.broadcastAddresses(toward: targetHost)).joined(separator: ", "))")
        waking = true; error = nil; notice = "Waking the TV… this can take up to a minute after turning it off."
        wakeTask?.cancel()
        wakeTask = Task {
            var keyTimes: [Date] = powerKeySent ? [Date()] : []
            let deadline = Date().addingTimeInterval(90)
            while !Task.isCancelled && Date() < deadline {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                if connected, let client = connection {
                    if let info = try? await client.deviceInfo() { apply(info) }
                    if powerOn { return }
                    if keyTimes.count < 2, keyTimes.last.map({ Date().timeIntervalSince($0) > 15 }) ?? true {
                        keyTimes.append(Date()); log("Remote", "KEY_POWER · wake from standby")
                        try? await client.key("KEY_POWER")
                        continue
                    }
                }
                try? TVDiscovery.wake(mac: targetMAC, host: targetHost)
            }
            guard !Task.isCancelled, waking else { return }
            waking = false
            if !powerOn {
                error = "The TV did not wake up. Check Settings › General › Network › Expert Settings › Power On with Mobile on the TV, then try again."
            }
        }
    }
    private func finishWaking() { if waking { waking = false; wakeTask?.cancel(); notice = nil; log("Wake", "TV is on") } }
    func forgetPairing() {
        guard !host.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Forget this TV's pairing?"
        alert.informativeText = "The saved token and certificate for this TV will be removed from this Mac. You can connect and pair again."
        alert.addButton(withTitle: "Forget pairing"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pairingHost = host
        disconnect()
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try PairingKey.delete(pairingHost) }.value
                notice = "Saved pairing removed. Connect to pair this TV again."
            } catch {
                self.error = "Could not remove saved pairing: \(error.localizedDescription)"
            }
        }
    }
}

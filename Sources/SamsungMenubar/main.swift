import AppKit
import SwiftUI
import Combine

final class RemotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PanelArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - 11, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX - 3, y: rect.minY + 2), control: CGPoint(x: rect.midX - 6, y: rect.maxY - 6))
        path.addQuadCurve(to: CGPoint(x: rect.midX + 3, y: rect.minY + 2), control: CGPoint(x: rect.midX, y: rect.minY - 2))
        path.addQuadCurve(to: CGPoint(x: rect.midX + 11, y: rect.maxY), control: CGPoint(x: rect.midX + 6, y: rect.maxY - 6))
        path.closeSubpath()
        return path
    }
}

private struct PanelShell: View {
    @ObservedObject var store: RemoteStore
    let height: CGFloat
    let arrowX: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            PanelArrow().fill(Color(red: 0.085, green: 0.095, blue: 0.10))
                .frame(width: 24, height: 11).frame(width: 360, alignment: .leading).offset(x: arrowX - 12)
            RemoteView(store: store).frame(width: 360, height: height - 11)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.13), lineWidth: 0.7))
        }.frame(width: 360, height: height).preferredColorScheme(.dark)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = RemoteStore()
    var statusItem: NSStatusItem!
    let panel = RemotePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var host: NSHostingController<PanelShell>?
    var clickMonitor: Any?
    var keyMonitor: Any?
    private var sizeSubscription: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        // A menu bar app shows no menus, but text fields still need an Edit menu for ⌘X/⌘C/⌘V/⌘A/⌘Z.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(); editItem.submenu = edit
        let mainMenu = NSMenu(); mainMenu.addItem(editItem)
        NSApplication.shared.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tv", accessibilityDescription: "Samsung-menubar")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self; statusItem.button?.action = #selector(toggle)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        sizeSubscription = store.$preferredPanelHeight.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { if self?.panel.isVisible == true { self?.show() } }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.panel.orderOut(nil) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, event.window === self.panel else { return event }
            if event.keyCode == 53 { self.panel.orderOut(nil); return nil }
            // Leave keys to a focused text field; otherwise arrows, Return and Delete drive the TV.
            if self.panel.firstResponder is NSText || !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
            return self.store.keyboard(event.keyCode) ? nil : event
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !CommandLine.arguments.contains("--background") { self.show() }
            if !self.store.host.isEmpty { self.store.connect(allowFirstUseTrust: false) }
        }
    }
    @objc func toggle() { if panel.isVisible { panel.orderOut(nil) } else { show() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func show() {
        guard let button = statusItem.button, let anchorWindow = button.window else { return }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = anchorWindow.screen ?? NSScreen.main!
        let visible = screen.visibleFrame
        let top = min(anchor.minY - 3, visible.maxY - 3)
        let height = min(store.preferredPanelHeight, max(300, top - visible.minY - 12))
        let x = min(max(anchor.midX - 180, visible.minX + 8), visible.maxX - 368)
        let root = PanelShell(store: store, height: height, arrowX: min(342, max(18, anchor.midX - x)))
        if let host { host.rootView = root }
        else { let controller = NSHostingController(rootView: root); host = controller; panel.contentViewController = controller }
        // Use screen coordinates explicitly so AppKit cannot flip the panel above the menu bar.
        panel.setFrame(NSRect(x: x, y: top - height, width: 360, height: height), display: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        store.disconnect()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--help") {
    print("""
    Samsung-menubar — a macOS menu bar remote for Samsung Tizen TVs

    Run the app normally to discover or configure your TV in Settings.
    --background   Start without showing the panel.
    --self-check   Run offline checks without accessing a TV or saved pairing.
    --diagnose --host <tv-ip> [--report <file>] [--trust-new-tv]
                   Run read-only TV diagnostics. A new TV needs explicit certificate
                   approval with --trust-new-tv and Allow on the TV.
                   Diagnostic reports contain local device information.
    """)
} else if CommandLine.arguments.contains("--self-check") {
    Task { do { try await FeatureChecks.run(); exit(0) } catch { print("FAIL: \(error)"); exit(1) } }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--diagnose") {
    Task { @MainActor in
        let reportPath = CommandLine.arguments.firstIndex(of: "--report").flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil }
        var lines: [String] = []
        func say(_ line: String) {
            print(line); fflush(stdout); lines.append(line)
            if let reportPath { try? (lines.joined(separator: "\n") + "\n").write(toFile: reportPath + ".log", atomically: true, encoding: .utf8) }
        }
        guard let hostIndex = CommandLine.arguments.firstIndex(of: "--host"), CommandLine.arguments.count > hostIndex + 1,
              SamsungConnection.localHost(CommandLine.arguments[hostIndex + 1]) else {
            say("ERROR: use --diagnose --host <tv-ip> with the TV's local IPv4 address."); exit(2)
        }
        let host = CommandLine.arguments[hostIndex + 1]
        let client = SamsungConnection(host: host)
        client.onPairing = { say("PAIRING: choose Allow for Samsung-menubar on your TV.") }
        client.onCertificateTrust = { host, fingerprint in await ConnectionTrustPrompt.confirm(host: host, fingerprint: fingerprint) }
        do {
            try await client.connect(allowFirstUseTrust: CommandLine.arguments.contains("--trust-new-tv"))
            say("PAIRED: connection authorized; token stored in Keychain.")
            let device = try await client.deviceInfo()
            let apps = try await client.installedApps()
            var visible: [String] = []
            for app in apps where (try? await client.appVisible(app.id)) == true { visible.append(app.title) }
            var iconBytes = 0
            if let first = apps.first(where: { !$0.iconPath.isEmpty }) { iconBytes = (try? await client.icon(path: first.iconPath))?.count ?? 0 }
            let dlna = try? await DLNATransport.discover(host: host)
            let volume = try? await DLNATransport.volume(dlna?.renderingControl ?? URL(fileURLWithPath: "/"))
            try await client.ping()
            let report: [String: Any] = [
                "model": device["modelName"] ?? "", "os": device["OS"] ?? "", "power": device["PowerState"] ?? "",
                "apps": apps.map { ["id": $0.id, "title": $0.title, "type": $0.type] }, "visible": visible,
                "iconBytes": iconBytes, "avTransport": dlna?.avTransport != nil, "renderingControl": dlna?.renderingControl != nil,
                "volume": volume?.volume ?? -1, "muted": volume?.muted ?? false]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            if let reportPath { try data.write(to: URL(fileURLWithPath: reportPath)) }
            say("DIAGNOSIS: \(apps.count) apps, on screen: \(visible.first ?? "none"), volume \(volume.map { String($0.volume) } ?? "unavailable").")
            client.close(); exit(0)
        } catch { say("ERROR: \(error.localizedDescription)"); client.close(); exit(1) }
    }
    RunLoop.main.run()
} else {
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}

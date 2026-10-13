import SwiftUI
import AppKit

private let mutedInk = Color.white.opacity(0.49)

private enum RemoteTab: String, CaseIterable, Identifiable {
    case home = "Your TV", remote = "Remote", apps = "Apps", media = "Cast", usage = "Activity"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: return "tv"
        case .remote: return "dpad"
        case .apps: return "square.grid.2x2"
        case .media: return "airplay.video"
        case .usage: return "chart.bar.xaxis"
        }
    }
}

private struct PanelButton: ButtonStyle {
    var accent: Color
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? accent : Color.white.opacity(0.79))
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? accent.opacity(0.19) : Color.white.opacity(configuration.isPressed ? 0.13 : 0.065)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct PanelCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.068)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.085), lineWidth: 0.7))
    }
}

struct AppMark: View {
    let image: NSImage?
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                ZStack { RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)); Image(systemName: "app").foregroundStyle(mutedInk) }
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
    }
}

private struct TVMark: View {
    var size: CGFloat = 31
    var accent: Color
    var body: some View {
        Image(systemName: "tv.fill").font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(LinearGradient(colors: [accent, accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .accessibilityHidden(true)
    }
}

private struct HeroImage: View {
    var body: some View {
        Group {
            if let url = AppResources.bundle.url(forResource: "tv-hero", withExtension: "png", subdirectory: "AppAssets"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            }
        }.frame(width: 312, height: 178).accessibilityHidden(true)
    }
}

struct RemoteView: View {
    @ObservedObject var store: RemoteStore
    @State private var tab: RemoteTab = .home
    @State private var settings = false
    @State private var search = ""
    @State private var text = ""
    @State private var draftHost = ""
    @State private var draftName = ""
    @State private var draftMAC = ""
    @State private var usageDays = 1
    @State private var showEvents = false
    @State private var swipeTranslation = CGSize.zero
    private var theme: BrandTheme { BrandTheme.forApp(store.currentApp, iconColor: store.iconColors[store.foregroundID]) }
    private var accent: Color { store.connected ? theme.color : BrandTheme.samsungBlue }
    var body: some View {
        VStack(spacing: 0) {
            header.padding(.top, 16).padding(.bottom, 16)
            tabs.padding(.bottom, 14)
            contentScroll
            footer.padding(.top, 10).padding(.bottom, 12)
        }.padding(.horizontal, 13).frame(width: 360)
            .background(LinearGradient(colors: [Color(red: 0.065, green: 0.070, blue: 0.080), Color(white: 0.042)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .foregroundStyle(Color.white.opacity(0.86)).preferredColorScheme(.dark)
            .font(.system(size: 12))
            .tint(accent)
            .animation(.easeOut(duration: 0.22), value: store.foregroundID)
            .onChange(of: tab) { _, value in store.preferredPanelHeight = preferredHeight(value) }
            .onChange(of: settings) { _, value in store.preferredPanelHeight = value ? 650 : preferredHeight(tab) }
            .onAppear { if store.host.isEmpty { showConnectionSettings() } }
    }
    private func preferredHeight(_ tab: RemoteTab) -> CGFloat { tab == .home || tab == .remote ? 740 : tab == .media ? 590 : tab == .usage ? 580 : 660 }
    private var contentScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if settings { settingsPanel }
                else {
                    if tab != .home { sectionTitle(tab.rawValue.uppercased()) }
                    if !store.connected { connectionPanel }
                    tabContent
                }
                feedback
            }.padding(.bottom, 12)
        }.scrollIndicators(.hidden)
    }
    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .home: homePanel
        case .remote: remotePanel
        case .apps: appsPanel
        case .media: mediaPanel
        case .usage: usagePanel
        }
    }
    @ViewBuilder private var feedback: some View {
        if let error = store.error {
            PanelCard {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { store.error = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).help("Dismiss message")
                }
            }
        } else if let notice = store.notice {
            Text(notice).font(.system(size: 11)).foregroundStyle(mutedInk).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var header: some View {
        HStack(spacing: 9) {
            TVMark(accent: accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.name).font(.system(size: 17, weight: .semibold)).tracking(-0.3).lineLimit(1)
                Text(store.tvOS.isEmpty ? "Samsung" : "Samsung · \(store.tvOS)").font(.system(size: 10, weight: .medium)).foregroundStyle(mutedInk)
            }
            Spacer()
            Menu {
                Button("Refresh TV data") { Task { await store.refresh() } }
                Button(store.connected ? "Disconnect" : "Connect") {
                    if store.connected { store.disconnect() }
                    else if store.host.isEmpty { showConnectionSettings() }
                    else { store.connect() }
                }
                Divider()
                Button("Quit Samsung-menubar") { NSApplication.shared.terminate(nil) }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 30).foregroundStyle(mutedInk) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Menu {
                if store.waking { Button("Waking the TV…") {}.disabled(true) }
                else if store.connected && store.powerOn { Button("Turn TV off") { store.power() } }
                else if store.connected { Button("Turn TV on") { store.power() } }
                else { Button("Wake TV over Wi-Fi") { store.power() }.disabled(store.mac.isEmpty) }
            } label: {
                Image(systemName: "power").font(.system(size: 17)).foregroundStyle(store.connected && store.powerOn ? .white : mutedInk)
                    .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(0.06)))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("TV power")
        }
    }
    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(RemoteTab.allCases) { item in
                Button { tab = item; settings = false } label: {
                    Image(systemName: item.symbol).font(.system(size: 16, weight: .medium))
                        .foregroundStyle(tab == item && !settings ? accent : mutedInk)
                        .frame(maxWidth: .infinity).frame(height: 35)
                        .background(RoundedRectangle(cornerRadius: 9).fill(tab == item && !settings ? accent.opacity(0.2) : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(item.rawValue).accessibilityLabel(item.rawValue)
            }
        }.padding(4).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.066)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.7))
    }
    private func sectionTitle(_ title: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(mutedInk)
            Spacer()
            if store.connecting { ProgressView().controlSize(.mini) }
        }.padding(.horizontal, 1)
    }
    private var homePanel: some View {
        VStack(spacing: 12) {
            nowPlayingCard
            audioCard
            if !store.pinnedApps.isEmpty {
                PanelCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Favorites", systemImage: "star").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button { tab = .apps } label: { Text("See all").font(.system(size: 10)).foregroundStyle(mutedInk) }.buttonStyle(.plain)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 13) {
                            ForEach(store.pinnedApps) { app in
                                Button { store.launch(app) } label: {
                                    VStack(spacing: 8) { AppMark(image: store.icons[app.id], size: 34); Text(app.title).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.white.opacity(0.7)).lineLimit(1) }
                                        .frame(maxWidth: .infinity).padding(.vertical, 4).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!store.connected).help("Open \(app.title) on TV")
                            }
                        }
                    }
                }
            }
            sourcesCard
            if !store.mostUsedApps.isEmpty {
                HStack(spacing: 8) {
                    Text("Most used").font(.system(size: 10)).foregroundStyle(mutedInk)
                    Spacer()
                    ForEach(Array(store.mostUsedApps.prefix(4))) { app in
                        Button { store.launch(app) } label: { AppMark(image: store.icons[app.id], size: 25) }.buttonStyle(.plain).help("Open \(app.title)").disabled(!store.connected)
                    }
                    Button { tab = .usage } label: { Image(systemName: "chevron.right").foregroundStyle(mutedInk) }.buttonStyle(.plain).help("View activity")
                }.padding(.horizontal, 4)
            }
        }
    }
    private var sourcesCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Sources", systemImage: "cable.connector").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 7) {
                    keyTile("rectangle.on.rectangle", "Source", "KEY_SOURCE")
                    keyTile("cable.connector.horizontal", "HDMI", "KEY_HDMI")
                    keyTile("antenna.radiowaves.left.and.right", "Live TV", "KEY_TV")
                    keyTile("house", "Home", "KEY_HOME")
                }
            }.disabled(!store.connected)
        }
    }
    private func keyTile(_ symbol: String, _ title: String, _ key: String) -> some View {
        Button { store.press(key) } label: {
            VStack(spacing: 6) { Image(systemName: symbol).font(.system(size: 14)); Text(title).font(.system(size: 9, weight: .medium)) }
                .frame(maxWidth: .infinity).frame(height: 50)
        }.buttonStyle(PanelButton(accent: accent)).help(title).accessibilityLabel(title)
    }
    private var nowPlayingCard: some View {
        VStack(spacing: 0) {
            ZStack {
                Ellipse().fill(accent.opacity(store.connected ? 0.28 : 0.08)).frame(width: 230, height: 110).blur(radius: 38).offset(y: 9)
                HeroImage()
                VStack(spacing: 9) {
                    if store.connected, let icon = store.currentAppIcon { AppMark(image: icon, size: 43) }
                    else { TVMark(size: 43, accent: accent) }
                    Text(store.connected ? store.currentApp : "Samsung TV").font(.system(size: 15, weight: .semibold)).tracking(-0.3).lineLimit(1)
                }.offset(y: -6).shadow(color: accent.opacity(0.5), radius: 16)
            }.frame(height: 174)
            HStack(spacing: 5) {
                Circle().fill(store.connected ? accent : mutedInk).frame(width: 4, height: 4)
                Text(store.connected ? (store.powerOn ? "ON SCREEN NOW" : "TV IN STANDBY") : "YOUR TV, ON YOUR MAC").font(.system(size: 8, weight: .bold)).tracking(1.1).foregroundStyle(mutedInk)
                Spacer()
                if !store.resolution.isEmpty && store.connected { Text(store.resolution).font(.system(size: 9, weight: .medium)).foregroundStyle(accent) }
            }.padding(.horizontal, 10).padding(.top, 7)
            Text(theme.tagline).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.65)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 7)
        }.padding(.top, 2)
    }
    private var audioCard: some View {
        PanelCard {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(mutedInk)
                    Text("TV audio").fontWeight(.semibold)
                    Spacer()
                    Text(store.hasVolume ? "\(Int(store.volume))" : "—").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                }
                HStack(spacing: 9) {
                    Button { store.toggleMute() } label: { Image(systemName: store.muted ? "speaker.slash.fill" : "speaker.fill").foregroundStyle(store.muted ? accent : mutedInk).frame(width: 20) }.buttonStyle(.plain).help(store.muted ? "Unmute" : "Mute")
                    Slider(value: Binding(get: { store.volume }, set: store.changeVolume), in: 0...100).tint(accent).accessibilityLabel("TV volume").disabled(!store.hasVolume)
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(mutedInk)
                }
                HStack {
                    Text(store.muted ? "Muted" : store.hasVolume ? "TV speakers" : "Volume keys").font(.system(size: 10)).foregroundStyle(mutedInk)
                    Spacer()
                    Button { store.volumeStep(false) } label: { Image(systemName: "minus").frame(width: 25, height: 22) }.buttonStyle(PanelButton(accent: accent)).help("Lower volume")
                    Button { store.volumeStep(true) } label: { Image(systemName: "plus").frame(width: 25, height: 22) }.buttonStyle(PanelButton(accent: accent)).help("Raise volume")
                }
            }.disabled(!store.connected)
        }
    }
    private var remotePanel: some View {
        VStack(spacing: 12) {
            PanelCard {
                VStack(spacing: 16) {
                    HStack {
                        Text(store.currentApp).lineLimit(1).fontWeight(.semibold)
                        Spacer()
                        Circle().fill(store.connected ? Color.green : Color.orange).frame(width: 5, height: 5)
                        Text(store.connected ? "Remote ready" : "Not connected").font(.system(size: 9)).foregroundStyle(mutedInk)
                    }
                    HStack(spacing: 15) {
                        VStack(spacing: 12) { remoteButton("house", "Home", "KEY_HOME"); remoteButton("arrow.uturn.backward", "Back", "KEY_RETURN") }
                        ZStack {
                            Circle().fill(Color.white.opacity(0.055)).overlay(Circle().strokeBorder(Color.white.opacity(0.07)))
                            VStack { remoteDirection("chevron.up", "Up", "KEY_UP"); Spacer(); remoteDirection("chevron.down", "Down", "KEY_DOWN") }.padding(6)
                            HStack { remoteDirection("chevron.left", "Left", "KEY_LEFT"); Spacer(); remoteDirection("chevron.right", "Right", "KEY_RIGHT") }.padding(6)
                            Button { store.press("KEY_ENTER") } label: { Text("OK").font(.system(size: 12, weight: .semibold)).frame(width: 46, height: 46).background(Circle().fill(accent.opacity(0.2))).foregroundStyle(accent) }.buttonStyle(.plain).help("Confirm")
                        }.frame(width: 138, height: 138)
                        VStack(spacing: 12) { remoteButton("gearshape", "TV settings", "KEY_MENU"); remoteButton("xmark", "Exit", "KEY_EXIT") }
                    }.frame(maxWidth: .infinity)
                    HStack(spacing: 7) {
                        mediaButton("backward.fill", "Rewind", "KEY_REWIND")
                        mediaButton("play.fill", "Play", "KEY_PLAY")
                        mediaButton("pause.fill", "Pause", "KEY_PAUSE")
                        mediaButton("stop.fill", "Stop", "KEY_STOP")
                        mediaButton("forward.fill", "Fast forward", "KEY_FF")
                    }
                }.disabled(!store.connected)
            }
            PanelCard {
                VStack(spacing: 9) {
                    HStack { Label("Swipe pad", systemImage: "hand.draw").fontWeight(.semibold); Spacer(); Text("Swipe to move · tap for OK").font(.system(size: 9)).foregroundStyle(mutedInk) }
                    RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.065)).overlay(Image(systemName: "hand.draw").font(.system(size: 25, weight: .light)).foregroundStyle(accent.opacity(0.7)))
                        .frame(height: 85).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                            let delta = CGSize(width: value.translation.width - swipeTranslation.width, height: value.translation.height - swipeTranslation.height)
                            swipeTranslation = value.translation
                            store.swipe(dx: delta.width, dy: delta.height)
                        }.onEnded { _ in swipeTranslation = .zero; store.endSwipe() })
                        .simultaneousGesture(TapGesture().onEnded { store.press("KEY_ENTER") })
                        .accessibilityLabel("Swipe pad")
                }.disabled(!store.connected)
            }
            audioCard
            HStack(spacing: 8) {
                Button { store.press("KEY_CHDOWN") } label: { Label("Channel −", systemImage: "chevron.down").frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(PanelButton(accent: accent))
                Button { store.press("KEY_CHUP") } label: { Label("Channel +", systemImage: "chevron.up").frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(PanelButton(accent: accent))
            }.disabled(!store.connected)
            PanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Numbers", systemImage: "number").fontWeight(.semibold)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                        ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"], id: \.self) { digit in
                            Button { store.press("KEY_" + digit) } label: { Text(digit).font(.system(size: 13, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity).frame(height: 30) }
                                .buttonStyle(PanelButton(accent: accent)).help("Number \(digit)").accessibilityLabel("Number \(digit)")
                        }
                    }
                    Text("For channels and codes such as Developer Mode (Apps › 1 2 3 4 5).").font(.system(size: 10)).foregroundStyle(mutedInk)
                }.disabled(!store.connected)
            }
            PanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Keyboard", systemImage: "keyboard").fontWeight(.semibold)
                    TextField("Type into the open field on your TV", text: $text).textFieldStyle(.roundedBorder).onSubmit(sendText)
                    HStack {
                        Button { store.sendClipboard() } label: { Label("Paste to TV", systemImage: "doc.on.clipboard") }.help("Send the Mac clipboard to the TV")
                        Spacer()
                        Button("Send", action: sendText).disabled(text.isEmpty)
                        Button { store.press("KEY_ENTER") } label: { Image(systemName: "return") }.help("Confirm on TV")
                    }
                    Text("Select a text field on your TV first. ⌘V pastes into the box above; Paste to TV sends the clipboard directly.").font(.system(size: 10)).foregroundStyle(mutedInk).fixedSize(horizontal: false, vertical: true)
                }.disabled(!store.connected)
            }
            sourcesCard
            Text("Arrow keys, Return and Delete control the TV while this panel is open. Playback keys depend on the open app.").font(.system(size: 10)).foregroundStyle(mutedInk)
        }
    }
    private func sendText() { store.sendText(text); text = "" }
    private func remoteDirection(_ symbol: String, _ title: String, _ key: String) -> some View {
        Button { store.press(key) } label: { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 29, height: 29).contentShape(Rectangle()) }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    private func remoteButton(_ symbol: String, _ title: String, _ key: String) -> some View {
        Button { store.press(key) } label: { Image(systemName: symbol).font(.system(size: 15)).frame(width: 43, height: 42) }.buttonStyle(PanelButton(accent: accent)).help(title).accessibilityLabel(title)
    }
    private func mediaButton(_ symbol: String, _ title: String, _ key: String) -> some View {
        Button { store.press(key) } label: { Image(systemName: symbol).font(.system(size: 11)).frame(maxWidth: .infinity).frame(height: 30) }.buttonStyle(PanelButton(accent: accent)).help(title).accessibilityLabel(title)
    }
    private var appsPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(mutedInk)
                TextField("Search \(store.apps.count) apps", text: $search).textFieldStyle(.plain)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(mutedInk) }.buttonStyle(.plain) }
            }.padding(11).background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.06)))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                ForEach(store.shortcuts.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { app in
                    let color = BrandTheme.forApp(app.title, iconColor: store.iconColors[app.id]).color
                    VStack(spacing: 8) {
                        HStack {
                            Spacer()
                            Button { store.toggleFavorite(app) } label: {
                                Image(systemName: store.favorites.contains(app.id) ? "star.fill" : "star").font(.system(size: 9)).foregroundStyle(store.favorites.contains(app.id) ? color : mutedInk)
                            }.buttonStyle(.plain).help("Favorite \(app.title)").accessibilityLabel("Favorite \(app.title)")
                        }
                        Button { store.launch(app) } label: {
                            VStack(spacing: 10) {
                                AppMark(image: store.icons[app.id], size: 43).shadow(color: color.opacity(0.18), radius: 9)
                                Text(app.title).font(.system(size: 10, weight: .medium)).lineLimit(2).frame(height: 26)
                            }.frame(maxWidth: .infinity).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!store.connected).help("Open \(app.title) on TV")
                        if store.foregroundID == app.id { Text("ACTIVE").font(.system(size: 7, weight: .bold)).tracking(0.7).foregroundStyle(color) }
                        else { Color.clear.frame(height: 9) }
                    }.padding(10).background(RoundedRectangle(cornerRadius: 13).fill(LinearGradient(colors: [color.opacity(0.17), Color.white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(color.opacity(store.foregroundID == app.id ? 0.6 : 0.13)))
                }
            }
            if store.apps.isEmpty { Text("Apps appear after connecting.").foregroundStyle(mutedInk).padding(.vertical, 15) }
            Text("Click an app to open it on TV. Use the star to add favorites.").font(.system(size: 10)).foregroundStyle(mutedInk)
        }
    }
    private var usagePanel: some View {
        let totals = store.usage(days: usageDays)
        let total = totals.reduce(0) { $0 + $1.seconds }
        return VStack(alignment: .leading, spacing: 14) {
            Picker("Period", selection: $usageDays) { Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30) }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 7) {
                Text("SCREEN TIME").font(.system(size: 8, weight: .bold)).tracking(1.2).foregroundStyle(mutedInk)
                Text(duration(total)).font(.system(size: 38, weight: .medium, design: .rounded)).tracking(-1).foregroundStyle(accent)
                Text("Apps observed by your Mac").font(.system(size: 10)).foregroundStyle(mutedInk)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.08)))
            PanelCard {
                VStack(spacing: 17) {
                    ForEach(totals) { item in
                        let color = BrandTheme.forApp(item.title, iconColor: store.iconColors[item.id]).color
                        VStack(spacing: 8) {
                            HStack(spacing: 9) {
                                if let icon = store.icons[item.id] { AppMark(image: icon, size: 26) }
                                else { Image(systemName: "tv").foregroundStyle(color).frame(width: 26) }
                                Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Spacer(); Text(duration(item.seconds)).font(.system(size: 10)).foregroundStyle(mutedInk).monospacedDigit()
                            }
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) { Capsule().fill(Color.white.opacity(0.04)); Capsule().fill(color).frame(width: geometry.size.width * CGFloat(item.seconds / max(total, 1))) }
                            }.frame(height: 4)
                        }
                    }
                    if totals.isEmpty { VStack(spacing: 9) { Image(systemName: "chart.bar.xaxis").font(.system(size: 26)).foregroundStyle(accent); Text("Your history starts here").fontWeight(.medium); Text("The first record appears after another TV reading.").font(.system(size: 10)).foregroundStyle(mutedInk) }.frame(maxWidth: .infinity).padding(.vertical, 25) }
                }
            }
            Text("Local history starts now. Tracks the app on screen while your Mac is awake and connected; sleep, standby and offline periods are excluded.").font(.system(size: 10)).foregroundStyle(mutedInk)
        }
    }
    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes == 0 { return "\(Int(seconds)) s" }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
    private var mediaPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "airplay.video").font(.system(size: 26, weight: .light)).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 3) { Text("Your Mac, on the big screen").font(.system(size: 14, weight: .semibold)); Text("Screen mirroring with AirPlay").font(.system(size: 10)).foregroundStyle(mutedInk) }
                    }
                    Text("In Control Center on your Mac, open Screen Mirroring and choose your TV. You can also use the TV as a second display in Displays settings.").font(.system(size: 11)).foregroundStyle(mutedInk).fixedSize(horizontal: false, vertical: true)
                    Button { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!) } label: { Label("Open Displays settings", systemImage: "arrow.up.right") }.buttonStyle(.plain).foregroundStyle(accent)
                }
            }
            PanelCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Send a file", systemImage: "play.tv").font(.system(size: 14, weight: .semibold))
                    if let file = store.mediaFile {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.richtext").font(.system(size: 23)).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 4) { Text(file.lastPathComponent).fontWeight(.medium).lineLimit(2); Text(file.pathExtension.uppercased()).font(.system(size: 9)).foregroundStyle(mutedInk) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.08)))
                    }
                    Text(store.mediaStatus).font(.system(size: 10)).foregroundStyle(mutedInk).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Choose file") { store.chooseMedia() }.disabled(store.mediaBusy)
                        Spacer()
                        Button(store.mediaBusy ? "Sending…" : "Play on TV") { store.castMedia() }.disabled(!store.connected || store.mediaFile == nil || store.mediaBusy)
                    }.font(.system(size: 10))
                    if store.casting {
                        HStack(spacing: 8) {
                            ForEach([("play.fill", "Play", "Play"), ("pause.fill", "Pause", "Pause"), ("stop.fill", "Stop", "Stop casting")], id: \.1) { symbol, action, title in
                                Button { store.controlCast(action) } label: { Image(systemName: symbol).frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(PanelButton(accent: accent)).help(title).accessibilityLabel(title)
                            }
                        }.disabled(store.mediaBusy)
                    }
                }
            }
            Text("The file opens on TV when you click Play. Compatibility depends on the format and codec; try H.264 MP4, MP3, or JPEG first. Keep your Mac awake while casting.").font(.system(size: 10)).foregroundStyle(mutedInk)
        }
    }
    private var logsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Samsung-menubar connections and actions saved on this Mac.").font(.system(size: 11)).foregroundStyle(mutedInk)
            PanelCard {
                LazyVStack(alignment: .leading, spacing: 13) {
                    ForEach(store.events.filter { $0.title != "Read" }) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(event.title).fontWeight(.semibold); Spacer(); Text(event.date, style: .time).foregroundStyle(mutedInk).monospacedDigit() }
                            Text(event.detail).font(.system(size: 10)).foregroundStyle(mutedInk).lineLimit(3).textSelection(.enabled)
                        }.font(.system(size: 11))
                    }
                    if store.events.isEmpty { Text("No events yet.").foregroundStyle(mutedInk).padding(.vertical, 12) }
                }
            }
        }
    }
    private var connectionPanel: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(store.status, systemImage: store.pairing ? "checkmark.shield" : "wifi").fontWeight(.semibold)
                Text(store.pairing ? "Choose Allow for “Samsung-menubar” on your TV." : "Your Mac and TV must be on the same network.").font(.system(size: 11)).foregroundStyle(mutedInk)
                Button(store.connecting ? "Cancel" : "Connect to TV") {
                    if store.connecting { store.disconnect() }
                    else if store.host.isEmpty { showConnectionSettings() }
                    else { store.connect() }
                }
            }
        }
    }
    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelCard {
                HStack(spacing: 13) {
                    TVMark(size: 38, accent: accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.model.isEmpty ? "Samsung TV" : "Samsung \(store.model)").font(.system(size: 14, weight: .semibold))
                        Text([store.tvOS, store.resolution].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(mutedInk)
                    }
                    Spacer()
                }
            }
            sectionTitle("CONNECTION")
            PanelCard {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Your TV").fontWeight(.semibold)
                    TextField("Name", text: $draftName).textFieldStyle(.roundedBorder)
                    TextField("TV IP address", text: $draftHost).textFieldStyle(.roundedBorder)
                    TextField("Wi-Fi MAC address for wake", text: $draftMAC).textFieldStyle(.roundedBorder)
                    Text("Optional: the MAC address is filled in from the TV once connected and is only used to wake it.").font(.system(size: 10)).foregroundStyle(mutedInk)
                    Button("Save and connect") {
                        store.disconnect(); store.model = ""; store.tvOS = ""; store.resolution = ""
                        store.host = draftHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Samsung TV" : draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.mac = draftMAC.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(); store.connect(); settings = false
                    }.disabled(!SamsungConnection.localHost(draftHost.trimmingCharacters(in: .whitespacesAndNewlines)) || store.connecting)
                    if !store.host.isEmpty {
                        Button("Forget pairing") { store.forgetPairing() }.disabled(store.connecting)
                    }
                }
            }
            PanelCard {
                VStack(alignment: .leading, spacing: 11) {
                    Button(store.discovering ? "Searching for TVs…" : "Find TVs on your network") { store.discover() }.disabled(store.discovering)
                    ForEach(store.devices) { device in
                        Button { store.select(device); settings = false } label: { HStack { Text(device.name); Spacer(); Text(device.host).foregroundStyle(mutedInk) } }.buttonStyle(.plain)
                    }
                    Text("To wake your TV from your Mac, turn on Power On with Mobile in the TV's network settings.").font(.system(size: 11)).foregroundStyle(mutedInk)
                }
            }
            DisclosureGroup("Event history", isExpanded: $showEvents) { logsPanel.padding(.top, 10) }.font(.system(size: 11))
        }
    }
    private func showConnectionSettings() {
        draftHost = store.host; draftName = store.name; draftMAC = store.mac
        settings = true
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(store.connected ? .green : store.connecting ? .orange : mutedInk).frame(width: 5, height: 5)
            Text(store.status).font(.system(size: 10)).foregroundStyle(mutedInk)
            Spacer()
            Text("\(store.model)").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(Color.white.opacity(0.27))
            Button {
                if !settings { draftHost = store.host; draftName = store.name; draftMAC = store.mac }
                settings.toggle()
            } label: { Image(systemName: settings ? "xmark" : "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(mutedInk).frame(width: 24, height: 22) }.buttonStyle(.plain).help("App settings")
        }
    }
}

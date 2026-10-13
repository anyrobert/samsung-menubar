import Foundation
import AppKit

enum FeatureChecks {
    static func equal<T: Equatable>(_ a: T, _ b: T) throws { guard a == b else { throw RemoteError.message("Check failed: \(a) != \(b)") } }
    static func truth(_ value: Bool) throws { guard value else { throw RemoteError.message("Check failed") } }
    static func rejects(_ operation: () throws -> Void) throws { do { try operation() } catch { return }; throw RemoteError.message("Expected rejection") }
    static func run() async throws {
        try testPackagedResourcesLoad()
        try testUsageSurvivesRestartAndClipsMidnightWithoutCountingSleep()
        try testHTTPRangeSupportsSeekSuffixAndRejectsInvalidRanges()
        try await testMediaServerStreamsOnlySelectedFileAndSupportsHeadAndRange()
        try testSOAPMetadataEscapesUserFilenameAndURL()
        try testSOAPValuesAndRenderingControlEnvelope()
        try testConnectionAcceptsOnlyLocalIPv4Addresses()
        try testCertificateTrustRequiresApprovalAndRejectsChangedPins()
        try testFreshConfigurationHasNoDeviceIdentityAndLoadsCustomParameters()
        try testChannelURLEncodesNameAndToken()
        try testRemoteMessagesMatchSamsungProtocol()
        try testInstalledAppsParseAndRejectUnsafeIDs()
        try testSwipeEmitsOneArrowPerStepAlongDominantAxis()
        try testMACValidation()
        try testWakeTargetsSubnetBroadcast()
        print("PASS: packaged image; usage persistence, midnight clipping, sleep exclusion; HTTP GET/HEAD/Range/404/416; XML escaping; RenderingControl values; local IPv4 boundaries, certificate trust, fresh configuration and custom parameters; channel URL, key, text and launch messages; installed-app parsing and app ID safety; swipe-to-arrow mapping; MAC validation; subnet broadcast for wake.")
    }

    static func testPackagedResourcesLoad() throws {
        guard let url = AppResources.bundle.url(forResource: "tv-hero", withExtension: "png", subdirectory: "AppAssets"),
              let image = NSImage(contentsOf: url), image.isValid else {
            throw RemoteError.message("The packaged TV image is missing or invalid")
        }
    }

    static func testConnectionAcceptsOnlyLocalIPv4Addresses() throws {
        let allowed = [[10, 0, 0, 0], [10, 255, 255, 255], [172, 16, 0, 0], [172, 31, 255, 255], [192, 168, 0, 0], [192, 168, 255, 255], [169, 254, 1, 1], [169, 254, 254, 254]]
        for octets in allowed {
            try truth(SamsungConnection.localHost(octets.map(String.init).joined(separator: ".")))
        }
        for host in ["9.255.255.255", "11.0.0.0", "172.15.255.255", "172.32.0.0", "192.167.255.255", "192.169.0.0", "169.253.255.255", "169.255.0.0", "127.0.0.1", "0.0.0.0", "8.8.8.8", "255.255.255.255", "192.168.1.256", "192.168.1", "localhost", "", "::1"] {
            try truth(!SamsungConnection.localHost(host))
        }
    }
    static func testCertificateTrustRequiresApprovalAndRejectsChangedPins() throws {
        try equal(TVCertificatePolicy.decide(expected: "saved-pin", received: "saved-pin", canApprove: false), .matched)
        try equal(TVCertificatePolicy.decide(expected: "saved-pin", received: "saved-pin", canApprove: true), .matched)
        try equal(TVCertificatePolicy.decide(expected: "saved-pin", received: "changed-pin", canApprove: true), .rejected)
        try equal(TVCertificatePolicy.decide(expected: nil, received: "new-pin", canApprove: false), .rejected)
        try equal(TVCertificatePolicy.decide(expected: nil, received: "new-pin", canApprove: true), .approvalRequired)
    }
    static func testFreshConfigurationHasNoDeviceIdentityAndLoadsCustomParameters() throws {
        let suite = "SamsungMenubar.FeatureChecks." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw RemoteError.message("Could not create isolated test preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = TVConfiguration(defaults: defaults)
        try equal(fresh.host, "")
        try equal(fresh.name, "Samsung TV")
        try equal(fresh.model, "")
        try equal(fresh.mac, "")
        let address = "203.0.113.10"
        let mac = ["00", "11", "22", "33", "44", "55"].joined(separator: ":")
        defaults.set(address, forKey: "tv.host")
        defaults.set("Test TV", forKey: "tv.name")
        defaults.set("Test model", forKey: "tv.model")
        defaults.set(mac, forKey: "tv.mac")
        let configured = TVConfiguration(defaults: defaults)
        try equal(configured.host, address)
        try equal(configured.name, "Test TV")
        try equal(configured.model, "Test model")
        try equal(configured.mac, mac)
    }

    static func testUsageSurvivesRestartAndClipsMidnightWithoutCountingSleep() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage.json")
        let midnight = Date(timeIntervalSince1970: 86400 * 20000)
        let journal = UsageJournal(url: file)
        journal.observe(host: "tv", appID: "netflix", title: "Netflix", at: midnight.addingTimeInterval(-10))
        journal.observe(host: "tv", appID: "youtube", title: "YouTube", at: midnight.addingTimeInterval(10))
        journal.observe(host: "tv", appID: "youtube", title: "YouTube", at: midnight.addingTimeInterval(30))
        // An hour offline must contribute zero seconds, even for the same app.
        journal.observe(host: "tv", appID: "youtube", title: "YouTube", at: midnight.addingTimeInterval(3630))
        journal.pause(at: midnight.addingTimeInterval(3640))
        try journal.save()
        let restored = UsageJournal(url: file)
        let totals = restored.totals(host: "tv", since: midnight, until: midnight.addingTimeInterval(4000))
        try equal(totals.first?.id, "youtube")
        try equal(totals.first?.seconds, 30)
        try equal(totals.last?.seconds, 10)
        try truth(restored.totals(host: "other", since: midnight).isEmpty)
    }
    static func testHTTPRangeSupportsSeekSuffixAndRejectsInvalidRanges() throws {
        let seek = try MediaHTTP.range("bytes=5-12", size: 10)
        try equal(seek.start, 5); try equal(seek.end, 9); try truth(seek.partial)
        try equal(try MediaHTTP.range("bytes=-3", size: 10).start, 7)
        try equal(try MediaHTTP.range("bytes=3-", size: 10).end, 9)
        try rejects { _ = try MediaHTTP.range("bytes=10-", size: 10) }
        try rejects { _ = try MediaHTTP.range("bytes=6-2", size: 10) }
        try rejects { _ = try MediaHTTP.range("bytes=0-1,4-5", size: 10) }
    }
    static func testMediaServerStreamsOnlySelectedFileAndSupportsHeadAndRange() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("0123456789".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = MediaFileServer(file: file, allowedHost: "127.0.0.1")
        let url = try await server.start()
        defer { server.stop() }
        var request = URLRequest(url: url); request.setValue("bytes=3-6", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        try equal((response as? HTTPURLResponse)?.statusCode, 206)
        try equal(String(decoding: data, as: UTF8.self), "3456")
        request.httpMethod = "HEAD"
        let (empty, head) = try await URLSession.shared.data(for: request)
        try truth(empty.isEmpty)
        try equal((head as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "4")
        request.httpMethod = "GET"; request.setValue("bytes=99-", forHTTPHeaderField: "Range")
        let (_, invalid) = try await URLSession.shared.data(for: request)
        try equal((invalid as? HTTPURLResponse)?.statusCode, 416)
        let (_, absent) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("secret"))
        try equal((absent as? HTTPURLResponse)?.statusCode, 404)
    }
    static func testSOAPMetadataEscapesUserFilenameAndURL() throws {
        let metadata = DLNATransport.metadata(url: URL(string: "http://127.0.0.1/a?x=1&y=2")!, title: "A < B & C", mime: "video/mp4")
        let envelope = DLNATransport.envelope(action: "SetAVTransportURI", parameters: [("CurrentURIMetaData", metadata)])
        try truth(XMLParser(data: Data(envelope.utf8)).parse())
        try truth(metadata.contains("A &lt; B &amp; C"))
        try truth(envelope.contains("&lt;DIDL-Lite"))
    }
    static func testSOAPValuesAndRenderingControlEnvelope() throws {
        try equal(DLNATransport.value("CurrentVolume", in: "<u:GetVolumeResponse><CurrentVolume>12</CurrentVolume></u:GetVolumeResponse>"), 12)
        try equal(DLNATransport.value("CurrentMute", in: "<CurrentMute> 1 </CurrentMute>"), 1)
        try equal(DLNATransport.value("CurrentVolume", in: "<Fault/>"), nil)
        let envelope = DLNATransport.envelope(action: "SetVolume", service: DLNATransport.renderingURN, parameters: [("Channel", "Master"), ("DesiredVolume", "30")])
        try truth(XMLParser(data: Data(envelope.utf8)).parse())
        try truth(envelope.contains("xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\""))
        try truth(envelope.contains("<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>30</DesiredVolume>"))
    }
    static func testChannelURLEncodesNameAndToken() throws {
        let fresh = SamsungProtocol.channelURL(host: "203.0.113.20", token: nil)
        try equal(fresh?.absoluteString, "wss://203.0.113.20:8002/api/v2/channels/samsung.remote.control?name=U2Ftc3VuZy1tZW51YmFy")
        let paired = SamsungProtocol.channelURL(host: "203.0.113.20", token: "12 34&x=y")
        try truth(paired?.absoluteString.hasSuffix("&token=12%2034%26x%3Dy") == true)
        try equal(SamsungProtocol.channelURL(host: "tv.local", token: nil), nil)
    }
    static func testRemoteMessagesMatchSamsungProtocol() throws {
        let key = SamsungProtocol.key("KEY_VOLUP")
        try equal(key["method"] as? String, "ms.remote.control")
        let params = key["params"] as? [String: String] ?? [:]
        try equal(params, ["Cmd": "Click", "DataOfCmd": "KEY_VOLUP", "Option": "false", "TypeOfRemote": "SendRemoteKey"])
        let text = SamsungProtocol.text("Olá")["params"] as? [String: String] ?? [:]
        try equal(text["Cmd"], Data("Olá".utf8).base64EncodedString())
        try equal(text["TypeOfRemote"], "SendInputString")
        let web = SamsungProtocol.launch(TVApp(id: "111299001912", title: "YouTube", type: 2, iconPath: ""))
        let native = SamsungProtocol.launch(TVApp(id: "3201807016597", title: "Apple TV", type: 1, iconPath: ""))
        func action(_ message: [String: Any]) -> String? { ((message["params"] as? [String: Any])?["data"] as? [String: Any])?["action_type"] as? String }
        try equal(action(web), "DEEP_LINK"); try equal(action(native), "NATIVE_LAUNCH")
        try equal((web["params"] as? [String: Any])?["event"] as? String, "ed.apps.launch")
        try truth(JSONSerialization.isValidJSONObject(web) && JSONSerialization.isValidJSONObject(key))
    }
    static func testInstalledAppsParseAndRejectUnsafeIDs() throws {
        let payload: [String: Any] = ["event": "ed.installedApp.get", "data": ["data": [
            ["appId": "111299001912", "name": "YouTube", "app_type": 2, "icon": "/opt/a.png"],
            ["appId": "111299001912", "name": "Duplicate", "app_type": 2],
            ["appId": "org.tizen.browser", "name": "Internet", "app_type": "4"],
            ["name": "No ID"]]]]
        let apps = SamsungProtocol.apps(from: payload)
        try equal(apps.map(\.id), ["111299001912", "org.tizen.browser"])
        try equal(apps.map(\.type), [2, 4])
        try equal(apps.first?.iconPath, "/opt/a.png")
        try truth(SamsungProtocol.validAppID("org.tizen.browser"))
        for unsafe in ["", "../etc", "a/b", "a?b", "a b", String(repeating: "1", count: 129)] { try truth(!SamsungProtocol.validAppID(unsafe)) }
    }
    static func testSwipeEmitsOneArrowPerStepAlongDominantAxis() throws {
        var swipe = SwipeTracker()
        try equal(swipe.add(dx: 20, dy: 3), [])
        try equal(swipe.add(dx: 20, dy: 3), ["KEY_RIGHT"])
        try equal(swipe.add(dx: 0, dy: -80), ["KEY_UP", "KEY_UP"])
        swipe.reset()
        try equal(swipe.add(dx: -39, dy: 10), ["KEY_LEFT"])
        try equal(swipe.add(dx: 0, dy: 1000).count, 6)
        try equal(swipe.add(dx: 0, dy: 1), [])
    }
    static func testMACValidation() throws {
        try truth(TVDiscovery.validMAC(["00", "1a", "2B", "33", "44", "55"].joined(separator: ":")))
        for bad in ["", "00:11:22:33:44", "00:11:22:33:44:5", "00:11:22:33:44:GG", "00-11-22-33-44-55", "00:11:22:33:44:55:66"] { try truth(!TVDiscovery.validMAC(bad)) }
    }
    static func testWakeTargetsSubnetBroadcast() throws {
        try equal(TVDiscovery.directedBroadcast(address: "203.0.113.5", netmask: "255.255.255.0"), "203.0.113.255")
        try equal(TVDiscovery.directedBroadcast(address: "203.0.113.5", netmask: "255.255.254.0"), "203.0.113.255")
        try equal(TVDiscovery.directedBroadcast(address: "203.0.113.130", netmask: "255.255.255.128"), "203.0.113.255")
        try equal(TVDiscovery.directedBroadcast(address: "203.0.113.5", netmask: "255.255.255.252"), "203.0.113.7")
        try equal(TVDiscovery.directedBroadcast(address: "203.0.113.5", netmask: "not-a-mask"), nil)
    }
}

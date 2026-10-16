import Foundation
import Security
import CryptoKit

enum TVCertificateDecision: Equatable { case matched, approvalRequired, rejected }
enum TVCertificatePolicy {
    static func decide(expected: String?, received: String, canApprove: Bool) -> TVCertificateDecision {
        if let expected { return expected == received ? .matched : .rejected }
        return canApprove ? .approvalRequired : .rejected
    }
}

// Samsung TVs serve a self-signed certificate on 8002. Explicit first-time approval pins
// the leaf for this host; an existing pin must always match, for the socket and REST calls.
final class TVCertificateTrust: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    private let lock = NSLock()
    private var fingerprint: String?
    private var approval: (@Sendable (String, String) async -> Bool)?
    private var trustError: Error?
    private var opening: [Int: CheckedContinuation<Void, Error>] = [:]
    init(host: String, port: Int) { self.host = host; self.port = port }
    func configure(fingerprint: String?, approval: (@Sendable (String, String) async -> Bool)?) {
        lock.lock()
        self.fingerprint = fingerprint
        self.approval = approval
        trustError = nil
        lock.unlock()
    }
    func approvedFingerprint() -> String? {
        lock.lock(); defer { lock.unlock() }
        return fingerprint
    }
    private func reject(_ message: String, _ completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        lock.lock(); trustError = RemoteError.message(message); lock.unlock()
        completion(.cancelAuthenticationChallenge, nil)
    }
    private func approve(_ digest: String) {
        lock.lock(); fingerprint = digest; lock.unlock()
    }
    func open(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); opening[task.taskIdentifier] = continuation; lock.unlock()
            task.resume()
        }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock(); let continuation = opening.removeValue(forKey: webSocketTask.taskIdentifier); lock.unlock()
        continuation?.resume()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = opening.removeValue(forKey: task.taskIdentifier); let failure = trustError; lock.unlock()
        continuation?.resume(throwing: failure ?? error ?? RemoteError.message("The TV connection closed before it opened."))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        guard challenge.protectionSpace.host == host, challenge.protectionSpace.port == port,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first else {
            reject("The TV did not provide a certificate for the selected local address.", completionHandler)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        lock.lock(); let expected = fingerprint; let requestApproval = approval; lock.unlock()
        switch TVCertificatePolicy.decide(expected: expected, received: digest, canApprove: requestApproval != nil) {
        case .matched:
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        case .rejected:
            reject(expected == nil
                ? "This TV has no trusted certificate yet. Click Connect to confirm first-time pairing."
                : "The TV certificate has changed. Verify the device and pair it again in Settings.", completionHandler)
            return
        case .approvalRequired: break
        }
        guard let requestApproval else {
            reject("This TV has no trusted certificate yet. Click Connect to confirm first-time pairing.", completionHandler)
            return
        }
        Task {
            guard await requestApproval(host, digest) else {
                reject("The TV certificate was not approved.", completionHandler)
                return
            }
            approve(digest)
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}

enum RemoteError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    /// macOS reports a Local Network privacy block as "offline" or an aborted socket, which misleads.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        let blocked = (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorNotConnectedToInternet)
            || (ns.domain == NSPOSIXErrorDomain && [Int(ENETDOWN), Int(ECONNABORTED)].contains(ns.code))
        return blocked
            ? "macOS is blocking local network access. Allow Samsung-menubar in System Settings › Privacy & Security › Local Network, then quit and reopen the app."
            : error.localizedDescription
    }
}

struct TVApp: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let type: Int
    let iconPath: String
}

/// Pure message builders and parsers for the Samsung remote channel, kept separate for offline checks.
enum SamsungProtocol {
    static let clientName = "Samsung-menubar"
    static let securePort = 8002
    static func channelURL(host: String, token: String?) -> URL? {
        guard SamsungConnection.validHost(host),
              let name = Data(clientName.utf8).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        var query = "name=" + name
        if let token, !token.isEmpty {
            guard let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
            query += "&token=" + encoded
        }
        return URL(string: "wss://\(host):\(securePort)/api/v2/channels/samsung.remote.control?" + query)
    }
    static func key(_ code: String, command: String = "Click") -> [String: Any] {
        ["method": "ms.remote.control",
         "params": ["Cmd": command, "DataOfCmd": code, "Option": "false", "TypeOfRemote": "SendRemoteKey"]]
    }
    static func text(_ value: String) -> [String: Any] {
        ["method": "ms.remote.control",
         "params": ["Cmd": Data(value.utf8).base64EncodedString(), "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"]]
    }
    static let textEnd: [String: Any] = ["method": "ms.remote.control", "params": ["TypeOfRemote": "SendInputEnd"]]
    static func emit(_ event: String, data: Any? = nil) -> [String: Any] {
        var params: [String: Any] = ["event": event, "to": "host"]
        if let data { params["data"] = data }
        return ["method": "ms.channel.emit", "params": params]
    }
    static func launch(_ app: TVApp, metaTag: String = "", action: String? = nil) -> [String: Any] {
        // Web apps (type 2) open as deep links; native and system apps use a native launch.
        // The app decides what metaTag means, such as a URL for the browser or a video ID for YouTube.
        emit("ed.apps.launch", data: ["appId": app.id, "action_type": action ?? (app.type == 2 ? "DEEP_LINK" : "NATIVE_LAUNCH"), "metaTag": metaTag])
    }
    static func apps(from payload: [String: Any]) -> [TVApp] {
        let list = (payload["data"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return list.compactMap {
            guard let id = $0["appId"] as? String, !id.isEmpty, let title = $0["name"] as? String,
                  seen.insert(id).inserted else { return nil }
            let type = ($0["app_type"] as? NSNumber)?.intValue ?? Int($0["app_type"] as? String ?? "") ?? 2
            return TVApp(id: id, title: title, type: type, iconPath: $0["icon"] as? String ?? "")
        }
    }
    static func validAppID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    }
}

/// The community Kick TV app (github.com/corekill/kick-tv-tizen). A build that reads launch data
/// opens the kick.com channel URL passed as metaTag; other builds open their home screen.
enum KickTV {
    static let appID = "CrKckTV001.KickTV"
    /// Accepts a channel name, @name or kick.com link and returns the channel URL.
    static func channelURL(_ input: String) -> String? {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "www.", "kick.com/", "@"] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        name = String(name.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !name.isEmpty, name.count <= 64, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return "https://kick.com/" + name
    }
}

private final class PingResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ error: Error?) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}

@MainActor final class SamsungConnection {
    let host: String
    private let session: URLSession
    private let trust: TVCertificateTrust
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var waiters: [String: CheckedContinuation<[String: Any], Error>] = [:]
    var onPairing: (() -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var onEvent: ((String, String) -> Void)?
    var onCertificateTrust: (@MainActor (String, String) async -> Bool)?
    init(host: String) {
        self.host = host
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        trust = TVCertificateTrust(host: host, port: SamsungProtocol.securePort)
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    func connect(allowFirstUseTrust: Bool = false) async throws {
        guard Self.localHost(host) else { throw RemoteError.message("Enter the TV's local IPv4 address.") }
        let pairingHost = host
        let saved = await Task.detached(priority: .userInitiated) {
            (PairingKey.read(pairingHost), TVCertificatePin.read(pairingHost))
        }.value
        let storedToken = saved.0, storedPin = saved.1
        let confirmation = onCertificateTrust
        guard storedPin != nil || (allowFirstUseTrust && confirmation != nil) else {
            throw RemoteError.message("This TV has no trusted certificate yet. Click Connect to confirm first-time pairing.")
        }
        let approval: (@Sendable (String, String) async -> Bool)?
        if allowFirstUseTrust {
            approval = { host, fingerprint in await confirmation?(host, fingerprint) ?? false }
        } else { approval = nil }
        trust.configure(fingerprint: storedPin, approval: approval)
        guard let url = SamsungProtocol.channelURL(host: host, token: storedToken) else { throw RemoteError.message("Invalid TV address.") }
        try Task.checkCancellation()
        let ws = session.webSocketTask(with: url); socket = ws
        try await trust.open(ws)
        if storedToken == nil { onPairing?() }
        // The TV answers the upgrade at once but sends its verdict only after the on-screen prompt.
        let watchdog = Task { try? await Task.sleep(nanoseconds: 60_000_000_000); if !Task.isCancelled { ws.cancel(with: .goingAway, reason: nil) } }
        defer { watchdog.cancel() }
        let first: [String: Any]
        do { first = try Self.decode(await ws.receive()) }
        catch { throw RemoteError.message("The TV closed the connection before allowing it. Allow “\(SamsungProtocol.clientName)” on the TV and try again.") }
        try Task.checkCancellation()
        switch first["event"] as? String ?? "" {
        case "ms.channel.connect": break
        case "ms.channel.unauthorized": throw RemoteError.message("The TV denied this Mac. Allow “\(SamsungProtocol.clientName)” in the TV's Device Connection Manager and try again.")
        case "ms.channel.timeOut": throw RemoteError.message("Pairing timed out. Allow the connection on the TV and try again.")
        default: throw RemoteError.message("The TV did not accept the remote connection.")
        }
        if let token = (first["data"] as? [String: Any])?["token"] as? String, !token.isEmpty, token != storedToken {
            try await Task.detached(priority: .userInitiated) { try PairingKey.save(token, host: pairingHost) }.value
        }
        // First-use trust is durable only after the TV has authorized the remote.
        if storedPin == nil, let fingerprint = trust.approvedFingerprint() {
            try await Task.detached(priority: .userInitiated) { try TVCertificatePin.save(fingerprint, host: pairingHost) }.value
        }
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let object = try await Self.decode(ws.receive())
                    self?.handle(object)
                }
            } catch { if !Task.isCancelled { self?.failed(error) } }
        }
    }
    nonisolated private static func decode(_ frame: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data: Data
        switch frame { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: return [:] }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    nonisolated static func validHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0).map { (0...255).contains($0) } == true }
    }
    nonisolated static func localHost(_ host: String) -> Bool {
        guard validHost(host) else { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
    }
    private func handle(_ object: [String: Any]) {
        let event = object["event"] as? String ?? ""
        if event == "ms.error" {
            let message = (object["data"] as? [String: Any])?["message"] as? String ?? "The TV rejected the command."
            onEvent?("Error", message); return
        }
        if event == "ed.apps.icon", let path = (object["data"] as? [String: Any])?["iconPath"] as? String {
            waiters.removeValue(forKey: event + "|" + path)?.resume(returning: object); return
        }
        waiters.removeValue(forKey: event)?.resume(returning: object)
    }
    private func failed(_ error: Error) {
        let pending = waiters; waiters.removeAll(); pending.values.forEach { $0.resume(throwing: error) }
        onDisconnect?(error)
    }
    func close() {
        receiver?.cancel(); receiver = nil; socket?.cancel(with: .goingAway, reason: nil)
        socket = nil; session.invalidateAndCancel()
        let pending = waiters; waiters.removeAll(); pending.values.forEach { $0.resume(throwing: CancellationError()) }
    }
    private func send(_ object: [String: Any]) async throws {
        guard let ws = socket else { throw RemoteError.message("Connect to the TV first.") }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await ws.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func ask(_ object: [String: Any], reply: String, timeout: UInt64 = 8) async throws -> [String: Any] {
        guard waiters[reply] == nil else { throw RemoteError.message("The TV is still answering a previous request.") }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[reply] = continuation
            Task { [weak self] in
                do { try await self?.send(object) }
                catch { self?.waiters.removeValue(forKey: reply)?.resume(throwing: error) }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                self?.waiters.removeValue(forKey: reply)?.resume(throwing: RemoteError.message("The TV took too long to respond."))
            }
        }
    }
    /// A TV that drops off Wi-Fi often leaves the socket open; a ping proves it is still there.
    func ping() async throws {
        guard let ws = socket else { throw RemoteError.message("Connect to the TV first.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result = PingResult(continuation)
            ws.sendPing { error in result.finish(error) }
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                result.finish(RemoteError.message("The TV stopped responding."))
            }
        }
    }
    func dropped(_ error: Error) { receiver?.cancel(); receiver = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil; failed(error) }
    // Record the key name only; never record typed text or tokens.
    func key(_ code: String) async throws { onEvent?("Command", code); try await send(SamsungProtocol.key(code)) }
    func text(_ value: String) async throws {
        onEvent?("Command", "Text input"); try await send(SamsungProtocol.text(value)); try await send(SamsungProtocol.textEnd)
    }
    func installedApps() async throws -> [TVApp] {
        onEvent?("Read", "ed.installedApp.get")
        return SamsungProtocol.apps(from: try await ask(SamsungProtocol.emit("ed.installedApp.get"), reply: "ed.installedApp.get"))
    }
    func icon(path: String) async throws -> Data {
        guard path.hasPrefix("/"), !path.contains("..") else { throw RemoteError.message("Invalid icon path.") }
        let answer = try await ask(SamsungProtocol.emit("ed.apps.icon", data: ["iconPath": path]), reply: "ed.apps.icon|" + path)
        guard let encoded = (answer["data"] as? [String: Any])?["imageBase64"] as? String,
              let data = Data(base64Encoded: encoded), data.count <= 2_000_000 else { throw RemoteError.message("The TV sent no icon.") }
        return data
    }
    func launch(_ app: TVApp, metaTag: String = "", action: String? = nil) async throws {
        onEvent?("Command", "ed.apps.launch")
        try await send(SamsungProtocol.launch(app, metaTag: metaTag, action: action))
    }
    private func rest(_ path: String, method: String = "GET") async throws -> [String: Any] {
        guard let url = URL(string: "https://\(host):\(SamsungProtocol.securePort)/api/v2/\(path)") else { throw RemoteError.message("Invalid TV address.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status), data.count <= 1_048_576 else {
            throw RemoteError.message("The TV did not answer \(path).")
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    func deviceInfo() async throws -> [String: Any] { try await rest("")["device"] as? [String: Any] ?? [:] }
    /// The TV reports `visible` for the app currently on screen.
    func appVisible(_ id: String) async throws -> Bool {
        guard SamsungProtocol.validAppID(id) else { return false }
        return try await rest("applications/" + id)["visible"] as? Bool ?? false
    }
}

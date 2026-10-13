import Foundation
import Network
import UniformTypeIdentifiers
import Darwin

enum MediaHTTP {
    static func range(_ value: String?, size: UInt64) throws -> (start: UInt64, end: UInt64, partial: Bool) {
        guard size > 0 else { throw RemoteError.message("The file is empty.") }
        guard let value else { return (0, size - 1, false) }
        guard value.hasPrefix("bytes="), !value.contains(",") else { throw RemoteError.message("Invalid byte range.") }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw RemoteError.message("Invalid byte range.") }
        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { throw RemoteError.message("Invalid byte range.") }
            return (size - min(size, suffix), size - 1, true)
        }
        guard let start = UInt64(parts[0]), start < size else { throw RemoteError.message("Invalid byte range.") }
        let end: UInt64
        if parts[1].isEmpty { end = size - 1 }
        else { guard let parsed = UInt64(parts[1]), parsed >= start else { throw RemoteError.message("Invalid byte range.") }; end = min(parsed, size - 1) }
        return (start, end, true)
    }
    static func localAddress(for host: String) throws -> String {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw RemoteError.message("Wi-Fi is unavailable.") }
        defer { Darwin.close(fd) }
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET); target.sin_port = UInt16(DLNATransport.port).bigEndian
        guard inet_pton(AF_INET, host, &target.sin_addr) == 1 else { throw RemoteError.message("Invalid IP address.") }
        let result = withUnsafePointer(to: &target) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw RemoteError.message("There is no network route to the TV.") }
        var local = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { throw RemoteError.message("Could not find this Mac's IP address.") }
        return String(cString: buffer)
    }
}

/// A bounded, single-file server. No directory or filename is exposed; only the paired TV may connect.
final class MediaFileServer: @unchecked Sendable {
    private final class CompletionFlag: @unchecked Sendable { var completed = false }
    let file: URL
    let mime: String
    let token = "/" + UUID().uuidString + "/media"
    private let allowedHost: String
    private let queue = DispatchQueue(label: "br.local.SamsungRemote.media")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    init(file: URL, allowedHost: String) {
        self.file = file; self.allowedHost = allowedHost
        mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
    func start() async throws -> URL {
        let address = try MediaHTTP.localAddress(for: allowedHost)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let flag = CompletionFlag()
            listener.stateUpdateHandler = { state in
                guard !flag.completed else { return }
                switch state {
                case .ready:
                    flag.completed = true
                    guard let port = listener.port, let url = URL(string: "http://\(address):\(port.rawValue)\(self.token)") else { continuation.resume(throwing: RemoteError.message("Could not start the media server.")); return }
                    continuation.resume(returning: url)
                case .failed(let error): flag.completed = true; continuation.resume(throwing: error)
                case .cancelled: flag.completed = true; continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        queue.async { [self] in listener?.cancel(); listener = nil; for c in connections.values { c.cancel() }; connections.removeAll() }
    }
    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint,
              String(describing: host) == allowedHost || String(describing: host) == "127.0.0.1",
              connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: id) }
            if case .failed = state { self?.connections.removeValue(forKey: id) }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            // Header readers are removed from this set when a valid request starts streaming.
            if self?.waitingHeaders.contains(id) == true { connection.cancel(); self?.waitingHeaders.remove(id) }
        }
        waitingHeaders.insert(id)
        readHeader(connection, id: id, buffer: Data())
    }
    private var waitingHeaders = Set<UUID>()
    private func readHeader(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer; if let data { buffer.append(data) }
            if buffer.count > 16384 || error != nil { connection.cancel(); waitingHeaders.remove(id); return }
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                waitingHeaders.remove(id); respond(connection, header: text)
            } else if complete { connection.cancel(); waitingHeaders.remove(id) }
            else { readHeader(connection, id: id, buffer: buffer) }
        }
    }
    private func fail(_ connection: NWConnection, status: String, extra: String = "") {
        let data = Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\(extra)\r\n".utf8)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
    private func respond(_ connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3, String(request[1]) == token else { fail(connection, status: "404 Not Found"); return }
        let method = String(request[0])
        guard method == "GET" || method == "HEAD" else { fail(connection, status: "405 Method Not Allowed", extra: "Allow: GET, HEAD\r\n"); return }
        guard let handle = try? FileHandle(forReadingFrom: file), let size = try? handle.seekToEnd(), size > 0 else { fail(connection, status: "404 Not Found"); return }
        let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        guard let range = try? MediaHTTP.range(rangeHeader, size: size) else { try? handle.close(); fail(connection, status: "416 Range Not Satisfiable", extra: "Content-Range: bytes */\(size)\r\n"); return }
        let count = range.end - range.start + 1
        let status = range.partial ? "206 Partial Content" : "200 OK"
        var response = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\ntransferMode.dlna.org: Streaming\r\n"
        if range.partial { response += "Content-Range: bytes \(range.start)-\(range.end)/\(size)\r\n" }
        response += "\r\n"
        try? handle.seek(toOffset: range.start)
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            if method == "HEAD" || error != nil { try? handle.close(); connection.cancel() }
            else { self?.stream(connection, handle: handle, remaining: count) }
        })
    }
    private func stream(_ connection: NWConnection, handle: FileHandle, remaining: UInt64) {
        guard remaining > 0, let data = try? handle.read(upToCount: Int(min(remaining, 65536))), !data.isEmpty else { try? handle.close(); connection.cancel(); return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { try? handle.close(); connection.cancel() }
            else { self?.stream(connection, handle: handle, remaining: remaining - UInt64(data.count)) }
        })
    }
}

private final class TransportXML: NSObject, XMLParserDelegate {
    var controls: [String: String] = [:]
    private var inside = false
    private var element = ""
    private var values: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "service" { inside = true; values = [:] }; element = name
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inside { values[element, default: ""] += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "service", let type = values["serviceType"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let control = values["controlURL"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            controls[type] = control; inside = false
        }
        element = ""
    }
}

struct DLNADevice {
    let avTransport: URL?
    let renderingControl: URL?
}

enum DLNATransport {
    static let port = 9197
    static let urn = "urn:schemas-upnp-org:service:AVTransport:1"
    static let renderingURN = "urn:schemas-upnp-org:service:RenderingControl:1"
    static func discover(host: String) async throws -> DLNADevice {
        guard SamsungConnection.validHost(host), let url = URL(string: "http://\(host):\(port)/dmr") else { throw RemoteError.message("Invalid IP address.") }
        var request = URLRequest(url: url); request.timeoutInterval = 6
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_048_576 else { throw RemoteError.message("The TV's media service did not respond.") }
        let parser = XMLParser(data: data), delegate = TransportXML(); parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw RemoteError.message("No compatible media service was found on this TV.") }
        func control(_ type: String) -> URL? {
            guard let path = delegate.controls[type], let control = URL(string: path, relativeTo: url)?.absoluteURL,
                  control.host == host, control.scheme == "http", control.port == port else { return nil }
            return control
        }
        let device = DLNADevice(avTransport: control(urn), renderingControl: control(renderingURN))
        guard device.avTransport != nil || device.renderingControl != nil else { throw RemoteError.message("No compatible media service was found on this TV.") }
        return device
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    static func metadata(url: URL, title: String, mime: String) -> String {
        let type = mime.hasPrefix("image/") ? "imageItem.photo" : mime.hasPrefix("audio/") ? "audioItem.musicTrack" : "videoItem"
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"0\" parentID=\"-1\" restricted=\"1\"><dc:title>\(escape(title))</dc:title><upnp:class>object.item.\(type)</upnp:class><res protocolInfo=\"http-get:*:\(escape(mime)):*\">\(escape(url.absoluteString))</res></item></DIDL-Lite>"
    }
    static func envelope(action: String, service: String = urn, parameters: [(String, String)]) -> String {
        let arguments = ([("InstanceID", "0")] + parameters).map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(service)\">\(arguments)</u:\(action)></s:Body></s:Envelope>"
    }
    static func command(_ url: URL, action: String, service: String = urn, parameters: [(String, String)] = []) async throws -> String {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(envelope(action: action, service: service, parameters: parameters).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !text.contains("Fault>") else {
            throw RemoteError.message(service == urn ? "The TV rejected \(action). Check the file format and connection." : "The TV rejected \(action).")
        }
        return text
    }
    /// Reads one numeric element from a SOAP answer, such as CurrentVolume.
    static func value(_ element: String, in text: String) -> Int? {
        guard let open = text.range(of: "<\(element)>"), let close = text.range(of: "</\(element)>", range: open.upperBound..<text.endIndex) else { return nil }
        return Int(text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces))
    }
    static func volume(_ control: URL) async throws -> (volume: Int, muted: Bool) {
        let level = try await command(control, action: "GetVolume", service: renderingURN, parameters: [("Channel", "Master")])
        let mute = try await command(control, action: "GetMute", service: renderingURN, parameters: [("Channel", "Master")])
        guard let volume = value("CurrentVolume", in: level) else { throw RemoteError.message("The TV did not report its volume.") }
        return (volume, value("CurrentMute", in: mute) == 1)
    }
    static func setVolume(_ control: URL, _ volume: Int) async throws {
        _ = try await command(control, action: "SetVolume", service: renderingURN, parameters: [("Channel", "Master"), ("DesiredVolume", String(min(100, max(0, volume))))])
    }
    static func setMute(_ control: URL, _ muted: Bool) async throws {
        _ = try await command(control, action: "SetMute", service: renderingURN, parameters: [("Channel", "Master"), ("DesiredMute", muted ? "1" : "0")])
    }
}

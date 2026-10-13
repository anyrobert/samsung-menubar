import Foundation
import Darwin

struct TVDevice: Identifiable, Equatable {
    var id: String { host }
    let host: String
    let name: String
    let model: String
    let mac: String?
}
private final class LocalDescriptionSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // An SSDP announcement must not send the Mac to an unrelated web server.
        completionHandler(nil)
    }
}
enum TVDiscovery {
    /// Samsung TVs answer DIAL and MediaRenderer searches; each responder is then asked for its
    /// unauthenticated device description on 8001, which names Tizen TVs and their Wi-Fi MAC.
    static func search() async -> [TVDevice] {
        await Task.detached(priority: .utility) {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return [] }
            defer { Darwin.close(fd) }
            var timeout = timeval(tv_sec: 0, tv_usec: 400_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(1900).bigEndian; inet_pton(AF_INET, "239.255.255.250", &address.sin_addr)
            for target in ["urn:dial-multiscreen-org:service:dial:1", "urn:schemas-upnp-org:device:MediaRenderer:1"] {
                let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n"
                message.withCString { bytes in
                    withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(fd, bytes, strlen(bytes), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                }
            }
            var hosts = Set<String>(); let end = Date().addingTimeInterval(4)
            while Date() < end {
                var buffer = [UInt8](repeating: 0, count: 16384)
                var sender = sockaddr_in()
                var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &sender) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLength)
                    }
                }
                if count > 0 {
                    var source = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    guard inet_ntop(AF_INET, &sender.sin_addr, &source, socklen_t(source.count)) != nil else { continue }
                    let sourceHost = String(cString: source)
                    if SamsungConnection.localHost(sourceHost) { hosts.insert(sourceHost) }
                }
            }
            var devices: [TVDevice] = []
            let session = URLSession(configuration: .ephemeral, delegate: LocalDescriptionSession(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            for host in hosts {
                guard let device = await describe(host: host, session: session) else { continue }
                devices.append(device)
            }
            return devices.sorted { $0.name < $1.name }
        }.value
    }
    static func describe(host: String, session: URLSession) async -> TVDevice? {
        guard SamsungConnection.localHost(host), let url = URL(string: "http://\(host):8001/api/v2/") else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 3
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = object["device"] as? [String: Any],
              (device["type"] as? String ?? "").localizedCaseInsensitiveContains("Samsung") else { return nil }
        let mac = (device["wifiMac"] as? String).flatMap { validMAC($0) ? $0.uppercased() : nil }
        return TVDevice(host: host, name: device["name"] as? String ?? "Samsung TV", model: device["modelName"] as? String ?? "", mac: mac)
    }
    static func validMAC(_ mac: String) -> Bool {
        let parts = mac.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
    }
    /// The broadcast address of a subnet, such as 203.0.113.255 for 203.0.113.5/24.
    static func directedBroadcast(address: String, netmask: String) -> String? {
        var a = in_addr(), m = in_addr()
        guard inet_pton(AF_INET, address, &a) == 1, inet_pton(AF_INET, netmask, &m) == 1 else { return nil }
        var b = in_addr(s_addr: a.s_addr | ~m.s_addr)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &b, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }
    /// Broadcast addresses of the Mac's interfaces on the TV's subnet. A sleeping TV answers no ARP,
    /// so unicast never leaves the Mac, and 255.255.255.255 can leave through a VPN interface instead.
    static func broadcastAddresses(toward host: String) -> [String] {
        var target = in_addr()
        guard inet_pton(AF_INET, host, &target) == 1 else { return [] }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_BROADCAST) != 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET), let mask = entry.ifa_netmask else { continue }
            let a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard a.s_addr & m.s_addr == target.s_addr & m.s_addr else { continue }
            var b = in_addr(s_addr: a.s_addr | ~m.s_addr)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &b, &buffer, socklen_t(buffer.count)) != nil { result.append(String(cString: buffer)) }
        }
        return result
    }
    static func wake(mac: String, host: String) throws {
        guard SamsungConnection.localHost(host) else { throw RemoteError.message("Enter the TV's local IPv4 address.") }
        guard validMAC(mac) else { throw RemoteError.message("Invalid MAC address.") }
        let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP); guard fd >= 0 else { throw RemoteError.message("Could not send the wake signal.") }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        let packet = [UInt8](repeating: 255, count: 6) + Array(repeating: bytes, count: 16).flatMap { $0 }
        var delivered = 0
        for target in broadcastAddresses(toward: host) + ["255.255.255.255", host] {
            for port in [UInt16(9), 7] {
                var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
                inet_pton(AF_INET, target, &address.sin_addr)
                let sent = packet.withUnsafeBytes { buffer in withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buffer.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
                if sent == packet.count { delivered += 1 }
            }
        }
        // Unicast to a sleeping TV may fail locally; only a total failure is an error.
        if delivered == 0 { throw RemoteError.message("Could not send Wake-on-LAN. Check that the Mac is on the TV's network.") }
    }
}

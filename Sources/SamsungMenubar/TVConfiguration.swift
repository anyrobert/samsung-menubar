import Foundation

/// Only the current Mac's preferences supply device details; no TV ships preconfigured.
struct TVConfiguration: Equatable {
    let host: String
    let name: String
    let model: String
    let mac: String
    init(defaults: UserDefaults = .standard) {
        host = defaults.string(forKey: "tv.host") ?? ""
        name = defaults.string(forKey: "tv.name") ?? "Samsung TV"
        model = defaults.string(forKey: "tv.model") ?? ""
        mac = defaults.string(forKey: "tv.mac") ?? ""
    }
}

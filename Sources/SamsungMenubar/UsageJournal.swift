import Foundation

struct UsageSlice: Codable {
    let host: String
    let appID: String
    let title: String
    let start: Date
    let end: Date
}
struct UsageTotal: Identifiable {
    let id: String
    let title: String
    let seconds: TimeInterval
}

/// Records only intervals bracketed by live observations. A sleep/reconnect gap never counts.
final class UsageJournal {
    private(set) var slices: [UsageSlice]
    private let url: URL
    private var current: (host: String, id: String, title: String, time: Date)?
    init(url: URL) {
        self.url = url
        slices = (try? JSONDecoder().decode([UsageSlice].self, from: Data(contentsOf: url))) ?? []
    }
    func observe(host: String, appID: String, title: String, at now: Date = Date()) {
        checkpoint(at: now)
        current = appID.isEmpty ? nil : (host, appID, title, now)
    }
    func pause(at now: Date = Date()) { checkpoint(at: now); current = nil }
    private func checkpoint(at now: Date) {
        if let c = current {
            let duration = now.timeIntervalSince(c.time)
            if duration > 0 && duration <= 35 {
                if let last = slices.last, last.host == c.host, last.appID == c.id, last.title == c.title, last.end == c.time {
                    slices[slices.count - 1] = UsageSlice(host: c.host, appID: c.id, title: c.title, start: last.start, end: now)
                } else {
                    slices.append(UsageSlice(host: c.host, appID: c.id, title: c.title, start: c.time, end: now))
                }
            }
        }
        slices.removeAll { $0.end < now.addingTimeInterval(-90 * 86400) }
    }
    func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(slices).write(to: url, options: .atomic)
    }
    func totals(host: String, since: Date, until: Date = Date()) -> [UsageTotal] {
        var values: [String: (String, TimeInterval)] = [:]
        for s in slices where s.host == host {
            let seconds = min(until, s.end).timeIntervalSince(max(since, s.start))
            guard seconds > 0 else { continue }
            let previous = values[s.appID]?.1 ?? 0
            values[s.appID] = (s.title, previous + seconds)
        }
        return values.map { UsageTotal(id: $0.key, title: $0.value.0, seconds: $0.value.1) }.sorted { $0.seconds > $1.seconds }
    }
}

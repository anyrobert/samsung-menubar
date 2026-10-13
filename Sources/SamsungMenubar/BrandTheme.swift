import SwiftUI
import AppKit

struct BrandTheme {
    let color: Color
    let label: String
    let tagline: String
    static let samsungBlue = Color(red: 0.13, green: 0.42, blue: 1)
    /// The dominant saturated hue of an icon, used to tint an app's card.
    static func dominantColor(_ imageData: Data) -> Color? {
        guard let bitmap = NSBitmapImageRep(data: imageData) else { return nil }
        var buckets: [Int: (count: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]
        for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 24)) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 24)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.6,
                      color.saturationComponent > 0.25, color.brightnessComponent > 0.25 else { continue }
                let bucket = Int(color.hueComponent * 20)
                let previous = buckets[bucket] ?? (0, 0, 0, 0)
                buckets[bucket] = (previous.count + 1, previous.r + color.redComponent, previous.g + color.greenComponent, previous.b + color.blueComponent)
            }
        }
        guard let best = buckets.values.max(by: { $0.count < $1.count }) else { return nil }
        let n = CGFloat(best.count)
        return Color(red: Double(best.r / n), green: Double(best.g / n), blue: Double(best.b / n))
    }
    static func forApp(_ title: String, iconColor: Color? = nil) -> BrandTheme {
        let key = title.lowercased()
        if key.contains("netflix") { return .init(color: Color(red: 0.94, green: 0.08, blue: 0.13), label: "Netflix", tagline: "A great story is waiting for you.") }
        if key.contains("youtube") { return .init(color: Color(red: 1, green: 0.18, blue: 0.23), label: "YouTube", tagline: "Everything you love, on the big screen.") }
        if key.contains("prime") { return .init(color: Color(red: 0.08, green: 0.64, blue: 1), label: "Prime Video", tagline: "Time for popcorn.") }
        if key.contains("disney") { return .init(color: Color(red: 0.20, green: 0.38, blue: 1), label: "Disney+", tagline: "A universe of stories.") }
        if key.contains("spotify") { return .init(color: Color(red: 0.12, green: 0.84, blue: 0.43), label: "Spotify", tagline: "Set the mood. Press play.") }
        if key.contains("twitch") { return .init(color: Color(red: 0.61, green: 0.35, blue: 1), label: "Twitch", tagline: "Your community, live.") }
        if key.contains("crunchyroll") { return .init(color: Color(red: 1, green: 0.47, blue: 0.13), label: title, tagline: "Your next episode is ready.") }
        if key.contains("hbo") || key.contains("max") { return .init(color: Color(red: 0.60, green: 0.34, blue: 1), label: title, tagline: "Great stories. Unforgettable moments.") }
        if key.contains("globo") { return .init(color: Color(red: 1, green: 0.33, blue: 0.23), label: title, tagline: "Your entertainment, your way.") }
        if key.contains("apple") { return .init(color: Color(white: 0.9), label: title, tagline: "Cinema in your living room.") }
        return .init(color: iconColor ?? samsungBlue, label: title, tagline: "Your Samsung. Your room. Your remote.")
    }
}

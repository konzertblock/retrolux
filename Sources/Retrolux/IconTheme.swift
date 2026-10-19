import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Icon themes: a folder `Themes/<name>/` in Application Support holding `theme.json` ({"name", "icons": {key: {"file"}}, "cork"}) and PNGs.
/// Keys not present in a theme fall back to the built-in drawn icons.
final class IconTheme: ObservableObject {
    static let shared = IconTheme()
    @Published var current: String { didSet { UserDefaults.standard.set(current, forKey: "iconTheme"); cache = [:]; corkImage = nil } }
    private var cache: [String: NSImage] = [:]
    private var corkImage: NSImage?
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Retrolux/Themes") }

    init() {
        let saved = UserDefaults.standard.string(forKey: "iconTheme")
        let have = IconTheme.available()
        current = saved ?? ""
    }
    static func available() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("theme.json").path) }.map { $0.lastPathComponent }.sorted()
    }
    private var dir: URL { Self.root.appendingPathComponent(current) }
    private func manifest() -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("theme.json")))) as? [String: Any] }

    func image(_ key: String) -> NSImage? {
        guard !current.isEmpty else { return nil }
        if let i = cache[key] { return i }
        guard let icons = manifest()?["icons"] as? [String: [String: Any]], let f = icons[key]?["file"] as? String,
              let img = NSImage(contentsOf: dir.appendingPathComponent(f)) else { return nil }
        if let rep = img.representations.first { img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh) }   // 1 pixel = 1 point
        cache[key] = img; return img
    }
    func cork() -> NSImage? {
        guard !current.isEmpty else { return nil }
        if let c = corkImage { return c }
        guard let f = manifest()?["cork"] as? String, let i = NSImage(contentsOf: dir.appendingPathComponent(f)) else { return nil }
        if let rep = i.representations.first { i.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        corkImage = i; return i
    }

    /// Faces polaroid frame (transparent photo area) with hole/label rectangles in image pixels, or nil.
    func polaroid() -> (image: NSImage, hole: CGRect, label: CGRect)? {
        guard !current.isEmpty, let p = manifest()?["polaroid"] as? [String: Any], let f = p["file"] as? String,
              let img = NSImage(contentsOf: dir.appendingPathComponent(f)), let h = p["hole"] as? [Double], let l = p["label"] as? [Double], h.count == 4, l.count == 4 else { return nil }
        if let rep = img.representations.first { img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        return (img, CGRect(x: h[0], y: h[1], width: h[2], height: h[3]), CGRect(x: l[0], y: l[1], width: l[2], height: l[3]))
    }

    /// Copies a user-chosen theme folder into Themes/ (must contain theme.json).
    func install(folder: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("theme.json").path) else { throw NSError(domain: "Theme", code: 1, userInfo: [NSLocalizedDescriptionKey: "theme.json fehlt / missing"]) }
        let name = folder.lastPathComponent, dest = Self.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest); try FileManager.default.copyItem(at: folder, to: dest)
        return name
    }
}

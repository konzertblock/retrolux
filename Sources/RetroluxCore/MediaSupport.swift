import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

public enum MediaProbe {
    public struct Info: Sendable { public var size: CGSize; public var duration: Double; public var date: Date? }
    public static func probe(_ url: URL) -> Info? {
        let a = AVURLAsset(url: url)
        let dur = CMTimeGetSeconds(a.duration)
        guard dur.isFinite else { return nil }
        var size = CGSize.zero
        if let t = a.tracks(withMediaType: .video).first { let s = t.naturalSize.applying(t.preferredTransform); size = CGSize(width: abs(s.width), height: abs(s.height)) }
        let date = a.creationDate?.dateValue
        return Info(size: size, duration: dur, date: date)
    }
    /// Poster frame (or first frame) as an image; `time` in seconds.
    public static func poster(_ url: URL, time: Double = 0, maxPixel: Int = 800) -> CGImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try? g.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
    }
}

/// Trim points and poster frame of a video version (stored in Version.meta, original clip untouched –).
public extension Version {
    var videoIn: Double { Double(meta["video.in"] ?? "") ?? 0 }
    var videoOut: Double? { Double(meta["video.out"] ?? "") }
    var posterTime: Double { Double(meta["video.poster"] ?? "") ?? 0 }
    var audioAttachment: String? { meta["audio.attachment"] }
}

public extension LibraryStore {
    var attachmentsDir: URL { root.appendingPathComponent("Attachments", isDirectory: true) }
    func attachmentURL(_ v: Version) -> URL? { v.audioAttachment.map { attachmentsDir.appendingPathComponent($0) } }

    /// Copies an audio file next to the library and links it to the version ("Attach Audio File…").
    @discardableResult func attachAudio(_ file: URL, to id: ID) throws -> String {
        let dir = attachmentsDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
        let dst = dir.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: dst)
        let rel = id + "/" + file.lastPathComponent
        try update([id]) { $0.meta["audio.attachment"] = rel }
        return rel
    }
    func removeAudio(from id: ID) throws {
        if let v = versions[id], let u = attachmentURL(v) { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) }
        try update([id]) { $0.meta["audio.attachment"] = nil }
    }
    func setVideoTrim(_ id: ID, inPoint: Double?, outPoint: Double?, poster: Double? = nil) throws {
        try update([id]) { v in
            if let i = inPoint { v.meta["video.in"] = i > 0 ? String(i) : nil }
            if let o = outPoint { v.meta["video.out"] = String(o) }
            if let p = poster { v.meta["video.poster"] = String(p) }
        }
    }
}

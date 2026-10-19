import AppKit
import ImageIO
import CryptoKit
import RetroluxCore

/// Thumbnails: embedded/decoded preview for untouched versions, rendered pipeline for edited ones. Memory + disk cache.
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()
    private let mem = NSCache<NSString, NSImage>()
    private let queue = OperationQueue()
    init() { mem.countLimit = 3000; queue.maxConcurrentOperationCount = 4; queue.qualityOfService = .userInitiated }

    func key(_ v: Version, _ set: AdjustmentSet, _ px: Int) -> String {
        var h = Hasher()
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let d = (try? enc.encode(set)) ?? Data()
        let sum = SHA256.hash(data: d + Data("\(v.rotation)|\(px)".utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(v.id)-\(sum)"
    }

    func fallbackFor(_ v: Version, store: LibraryStore, px: Int) -> CGImage? { store.fallbackImage(v, maxPixel: px) }
    func image(for v: Version, store: LibraryStore, px: Int) async -> NSImage? {
        guard let m = store.masters[v.masterID] else { return nil }
        if m.kind == .audio { return NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) }
        let set = v.hasAdjustments ? store.adjustments(for: v.id) : AdjustmentSet()
        let k = key(v, set, px) + (v.meta["render.fallback"] != nil ? "-fb" : "")
        if let hit = mem.object(forKey: k as NSString) { return hit }
        let disk = store.cacheDir.appendingPathComponent(k + ".jpg")
        let url = store.masterURL(m), size = CGSize(width: m.width, height: m.height), isRaw = m.isRaw, rot = v.rotation
        return await withCheckedContinuation { cont in
            queue.addOperation { [weak self] in
                guard let self else { cont.resume(returning: nil); return }
                var cg: CGImage?
                if let fb = self.fallbackFor(v, store: store, px: px) { cg = fb }
                if cg == nil, m.kind == .video { cg = MediaProbe.poster(url, time: v.posterTime, maxPixel: px) }
                if cg == nil, let src = CGImageSourceCreateWithURL(disk as CFURL, nil) { cg = CGImageSourceCreateImageAtIndex(src, 0, nil) }
                if cg == nil && m.kind == .image {
                    if set.isEmpty && rot == 0 && !isRaw {
                        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: px] as CFDictionary)
                        }
                    }
                    if cg == nil { cg = RenderEngine.shared.renderCG(RenderRequest(url: url, isRaw: isRaw, originalSize: size, rotation: rot, adjustments: set, maxPixel: px)) }
                    if let c = cg, let d = CGImageDestinationCreateWithURL(disk as CFURL, "public.jpeg" as CFString, 1, nil) {
                        CGImageDestinationAddImage(d, c, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary); CGImageDestinationFinalize(d)
                    }
                }
                guard let c = cg else { cont.resume(returning: nil); return }
                let img = NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
                self.mem.setObject(img, forKey: k as NSString)
                cont.resume(returning: img)
            }
        }
    }
}

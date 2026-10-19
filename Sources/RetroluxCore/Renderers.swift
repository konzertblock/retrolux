import Foundation
import CoreGraphics
import CoreText
import AppKit
import ImageIO
import UniformTypeIdentifiers

public extension LibraryStore {
    /// The rendering stored in the legacy library, kept for versions whose recipe cannot be reproduced: shown instead of a fake editable recipe.
    public func fallbackURL(_ v: Version) -> URL? { v.meta["render.fallback"].map { root.appendingPathComponent($0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }
    public func fallbackImage(_ v: Version, maxPixel: Int?) -> CGImage? {
        guard let u = fallbackURL(v), let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        if let mp = maxPixel { return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: mp] as CFDictionary) }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    public func dropFallback(_ id: ID) throws { if let v = versions[id], let u = fallbackURL(v) { try? FileManager.default.removeItem(at: u) }; try update([id]) { $0.meta["render.fallback"] = nil } }
    /// Adjusted rendering of a version (used by books, print, light tables, slideshows, web).
    func renderedImage(_ id: ID, maxPixel: Int?, deep: Bool = false) -> CGImage? {
        guard let v = versions[id], let m = masters[v.masterID] else { return nil }
        if let fb = fallbackImage(v, maxPixel: maxPixel) { return fb }
        let url = masterURL(m)
        if m.kind == .video { return MediaProbe.poster(url, time: v.posterTime, maxPixel: maxPixel ?? 1600) }
        guard m.kind == .image, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return RenderEngine.shared.renderCG(RenderRequest(url: url, isRaw: m.isRaw, originalSize: CGSize(width: m.width, height: m.height), rotation: v.rotation, adjustments: adjustments(for: id), maxPixel: maxPixel), deep: deep)
    }
    func aspect(_ id: ID) -> Double {
        guard let v = versions[id], let m = masters[v.masterID], m.width > 0, m.height > 0 else { return 1.5 }
        let a = Double(m.width) / Double(m.height); return v.rotation % 180 == 0 ? a : 1 / a
    }
}

enum DrawText {
    static func draw(_ text: String, in rect: CGRect, ctx: CGContext, font: String, size: CGFloat, color: [Double], align: String = "center") {
        guard !text.isEmpty else { return }
        let f = CTFontCreateWithName(font as CFString, size, nil)
        let style = NSMutableParagraphStyle(); style.alignment = align == "left" ? .left : (align == "right" ? .right : .center)
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: CGColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: 1), .paragraphStyle: style]
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let path = CGPath(rect: rect, transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), ctx)
    }
}

/// Draws an image into `rect` so that it fills the rect (crop around cx/cy with zoom) or fits inside it.
func drawImage(_ ctx: CGContext, _ img: CGImage, in rect: CGRect, fill: Bool, cx: Double = 0.5, cy: Double = 0.5, zoom: Double = 1) {
    ctx.saveGState(); ctx.clip(to: rect)
    let iw = CGFloat(img.width), ih = CGFloat(img.height)
    let s = (fill ? max(rect.width / iw, rect.height / ih) : min(rect.width / iw, rect.height / ih)) * CGFloat(max(1, zoom))
    let w = iw * s, h = ih * s
    var x = rect.midX - w / 2, y = rect.midY - h / 2
    if fill { x -= (CGFloat(cx) - 0.5) * (w - rect.width); y += (CGFloat(cy) - 0.5) * (h - rect.height) }
    ctx.interpolationQuality = .high; ctx.draw(img, in: CGRect(x: x, y: y, width: w, height: h)); ctx.restoreGState()
}

public enum LightTableRenderer {
    /// Renders the table to an image (or PDF when `pdf` is a URL).
    public static func render(_ doc: LightTableDoc, store: LibraryStore, size: CGSize, scale: CGFloat = 1, pdf: URL? = nil) -> CGImage? {
        let W = Int(size.width * scale), H = Int(size.height * scale)
        var ctx: CGContext?; var pdfMode = false
        if let pdf { var box = CGRect(origin: .zero, size: size); ctx = CGContext(pdf as CFURL, mediaBox: &box, nil); ctx?.beginPDFPage(nil); pdfMode = true }
        else { ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue); ctx?.scaleBy(x: scale, y: scale) }
        guard let c = ctx else { return nil }
        c.setFillColor(gray: CGFloat(doc.background), alpha: 1); c.fill(CGRect(origin: .zero, size: size))
        for it in doc.items.sorted(by: { $0.z < $1.z }) {
            guard let img = store.renderedImage(it.versionID, maxPixel: Int(max(it.width, it.height) * scale * 1.5)) else { continue }
            c.saveGState()
            c.translateBy(x: CGFloat(it.x), y: size.height - CGFloat(it.y)); c.rotate(by: -CGFloat(it.rotation) * .pi / 180)
            let r = CGRect(x: -it.width / 2, y: -it.height / 2, width: it.width, height: it.height)
            c.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: CGColor(gray: 0, alpha: 0.6))
            c.setFillColor(gray: 1, alpha: 1); c.fill(r.insetBy(dx: -3, dy: -3)); c.setShadow(offset: .zero, blur: 0)
            drawImage(c, img, in: r, fill: false)
            c.restoreGState()
            if doc.showLabels, let v = store.versions[it.versionID] {
                DrawText.draw(v.name, in: CGRect(x: CGFloat(it.x) - CGFloat(it.width) / 2, y: size.height - CGFloat(it.y) - CGFloat(it.height) / 2 - 22, width: CGFloat(it.width), height: 16), ctx: c, font: "Helvetica", size: 10, color: [0.9, 0.9, 0.9])
            }
        }
        if pdfMode { c.endPDFPage(); c.closePDF(); return nil }
        return c.makeImage()
    }
}

// MARK: - books → PDF
public struct BookReport: Sendable { public var pages = 0; public var missingImages: [String] = []; public var lowRes: [String] = []; public var emptySlots = 0; public var blankPages: [Int] = []
    public var ok: Bool { missingImages.isEmpty && lowRes.isEmpty && emptySlots == 0 && blankPages.isEmpty }
    public var text: String { "\(pages) pages" + (missingImages.isEmpty ? "" : "\nMissing images: \(missingImages.joined(separator: ", "))") + (lowRes.isEmpty ? "" : "\nLow resolution (<150 dpi): \(lowRes.joined(separator: ", "))") + (emptySlots == 0 ? "" : "\nEmpty image slots: \(emptySlots)") + (blankPages.isEmpty ? "" : "\nBlank pages: \(blankPages.map(String.init).joined(separator: ", "))") } }

public enum BookRenderer {
    public static func check(_ doc: BookDoc, store: LibraryStore) -> BookReport {
        var r = BookReport(); r.pages = doc.pages.count; let t = BookType.type(doc.type)
        for (pi, p) in doc.pages.enumerated() {
            if p.items.allSatisfy({ ($0.kind == .text && $0.text.isEmpty) || ($0.kind == .image && $0.versionID == nil) }) { r.blankPages.append(pi + 1) }
            for it in p.items where it.kind == .image {
                guard let vid = it.versionID else { r.emptySlots += 1; continue }
                guard let v = store.versions[vid], let m = store.masters[v.masterID], !store.isMissing(m) else { r.missingImages.append(store.versions[vid]?.name ?? vid); continue }
                let wIn = it.w * t.widthIn / max(1, it.zoom), pxW = Double(v.rotation % 180 == 0 ? m.width : m.height)
                if pxW / max(0.1, wIn) < 150 { r.lowRes.append(v.name) }
            }
        }
        if doc.pages.count < t.minPages { /* informational only; shown in the editor */ }
        return r
    }
    /// Page size in PDF points (72 per inch) plus bleed (0.125 in) when requested.
    public static func pageSize(_ doc: BookDoc) -> CGSize { let t = BookType.type(doc.type); let b = doc.bleed ? 0.25 : 0; return CGSize(width: (t.widthIn + b) * 72, height: (t.heightIn + b) * 72) }

    public static func draw(page: BookPage, number: Int, doc: BookDoc, store: LibraryStore, in ctx: CGContext, size: CGSize, pxPerInch: CGFloat = 200) {
        let theme = BookTheme.theme(doc.theme); let bleed: CGFloat = doc.bleed ? 9 : 0
        let bg = theme.background; ctx.setFillColor(CGColor(srgbRed: bg[0], green: bg[1], blue: bg[2], alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
        let inner = CGRect(x: bleed, y: bleed, width: size.width - 2 * bleed, height: size.height - 2 * bleed)
        for it in page.items {
            let r = CGRect(x: inner.minX + CGFloat(it.x) * inner.width, y: inner.minY + (1 - CGFloat(it.y + it.h)) * inner.height, width: CGFloat(it.w) * inner.width, height: CGFloat(it.h) * inner.height)
            switch it.kind {
            case .map:
                if !it.text.isEmpty, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: it.text) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { drawImage(ctx, img, in: r, fill: true, cx: it.cropX, cy: it.cropY, zoom: it.zoom) }
                else { ctx.setStrokeColor(gray: 0.6, alpha: 1); ctx.stroke(r) }
            case .image:
                guard let vid = it.versionID else { ctx.setStrokeColor(gray: 0.6, alpha: 1); ctx.setLineDash(phase: 0, lengths: [4, 3]); ctx.stroke(r); ctx.setLineDash(phase: 0, lengths: []); continue }
                let want = Int(max(r.width, r.height) / 72 * pxPerInch * CGFloat(it.zoom))
                guard let img = store.renderedImage(vid, maxPixel: want) else { continue }
                if theme.frameWidth > 0 { ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(r.insetBy(dx: -CGFloat(theme.frameWidth), dy: -CGFloat(theme.frameWidth))); ctx.setStrokeColor(gray: 0.7, alpha: 1); ctx.stroke(r.insetBy(dx: -CGFloat(theme.frameWidth), dy: -CGFloat(theme.frameWidth))) }
                drawImage(ctx, img, in: r, fill: true, cx: it.cropX, cy: it.cropY, zoom: it.zoom)
            case .text:
                DrawText.draw(it.text, in: r, ctx: ctx, font: theme.font, size: CGFloat(it.fontSize), color: theme.text, align: it.align)
            }
        }
        if doc.showPageNumbers { DrawText.draw("\(number)", in: CGRect(x: 0, y: bleed + 4, width: size.width, height: 12), ctx: ctx, font: theme.font, size: 8, color: theme.text) }
    }

    /// Writes the whole book as a PDF; bleed area is part of the media box (crop marks are not drawn).
    @discardableResult public static func pdf(_ doc: BookDoc, store: LibraryStore, to url: URL, progress: ((Int, Int) -> Void)? = nil) throws -> BookReport {
        let size = pageSize(doc); var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: doc.title as CFString, kCGPDFContextCreator: "Retrolux" as CFString] as CFDictionary) else { throw NSError(domain: "Book", code: 1) }
        for (i, p) in doc.pages.enumerated() { progress?(i, doc.pages.count); ctx.beginPDFPage(nil); draw(page: p, number: i + 1, doc: doc, store: store, in: ctx, size: size); ctx.endPDFPage() }
        ctx.closePDF(); progress?(doc.pages.count, doc.pages.count)
        return check(doc, store: store)
    }
}

// MARK: - print layouts / contact sheets → PDF
public struct PrintLayout: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var columns: Int, rows: Int
    public var framed = false
    public var labels = false
    public var title: String
    public init(name: String, columns: Int, rows: Int, framed: Bool = false, labels: Bool = false, title: String) { self.name = name; self.columns = columns; self.rows = rows; self.framed = framed; self.labels = labels; self.title = title }
    public static let presets: [PrintLayout] = [
        .init(name: "4x6", columns: 1, rows: 1, framed: false, labels: false, title: "4 × 6 in"), .init(name: "3x2", columns: 2, rows: 3, framed: false, labels: false, title: "2 × 3 images"),
        .init(name: "Framed", columns: 1, rows: 1, framed: true, labels: true, title: "Framed"), .init(name: "FancyContactSheet", columns: 5, rows: 6, framed: true, labels: true, title: "Contact sheet"),
        .init(name: "PhotoEssay", columns: 1, rows: 2, framed: false, labels: true, title: "Photo essay"), .init(name: "Sequence", columns: 4, rows: 1, framed: false, labels: false, title: "Sequence")]
}
public struct PrintOptions: Codable, Equatable, Sendable {
    public var paperWidthIn = 8.5, paperHeightIn = 11.0, margin = 0.5
    public var landscape = false
    public var header = "", footer = ""
    public var showName = true, showDate = false, showCaption = false, showExif = false, pageNumbers = true
    public var border = 0.0
    public var watermark = ""
    public var sharpen = 0.0                    // output sharpening 0…1
    public var dpi = 240.0
    public var gapIn = 0.15
    public var profileName = "sRGB"
    public init() {}
}
public enum PrintRenderer {
    public static func pdf(layout: PrintLayout, versions: [ID], options o: PrintOptions, store: LibraryStore, to url: URL) throws -> Int {
        var w = (o.landscape ? o.paperHeightIn : o.paperWidthIn) * 72, h = (o.landscape ? o.paperWidthIn : o.paperHeightIn) * 72
        if layout.name == "4x6" { w = 6 * 72; h = 4 * 72 + (o.landscape ? 0 : 0) }
        var box = CGRect(x: 0, y: 0, width: w, height: h)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextCreator: "Retrolux" as CFString] as CFDictionary) else { throw NSError(domain: "Print", code: 1) }
        let perPage = max(1, layout.columns * layout.rows); let pages = max(1, Int(ceil(Double(versions.count) / Double(perPage))))
        let m = o.margin * 72, gap = o.gapIn * 72, headerH: CGFloat = o.header.isEmpty ? 0 : 22, footerH: CGFloat = (o.footer.isEmpty && !o.pageNumbers) ? 0 : 18
        for p in 0..<pages {
            ctx.beginPDFPage(nil); ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(box)
            if !o.header.isEmpty { DrawText.draw(o.header, in: CGRect(x: m, y: h - m - 16, width: w - 2 * m, height: 18), ctx: ctx, font: "Helvetica-Bold", size: 12, color: [0, 0, 0]) }
            let areaTop = h - m - headerH, areaBottom = m + footerH
            let cw = (w - 2 * m - gap * CGFloat(layout.columns - 1)) / CGFloat(layout.columns), ch = (areaTop - areaBottom - gap * CGFloat(layout.rows - 1)) / CGFloat(layout.rows)
            for slot in 0..<perPage {
                let idx = p * perPage + slot; guard idx < versions.count else { break }
                let col = slot % layout.columns, row = slot / layout.columns
                let cell = CGRect(x: m + CGFloat(col) * (cw + gap), y: areaTop - CGFloat(row + 1) * ch - CGFloat(row) * gap, width: cw, height: ch)
                let labelH: CGFloat = (layout.labels || o.showName || o.showDate || o.showCaption || o.showExif) ? 14 * CGFloat((o.showName ? 1 : 0) + (o.showDate ? 1 : 0) + (o.showCaption ? 1 : 0) + (o.showExif ? 1 : 0) + (layout.labels && !o.showName ? 1 : 0)) : 0
                var imgRect = CGRect(x: cell.minX, y: cell.minY + labelH, width: cell.width, height: cell.height - labelH).insetBy(dx: CGFloat(o.border) * 72, dy: CGFloat(o.border) * 72)
                if layout.framed { imgRect = imgRect.insetBy(dx: 6, dy: 6) }
                let id = versions[idx]
                let px = Int(max(imgRect.width, imgRect.height) / 72 * CGFloat(o.dpi))
                if let img = store.renderedImage(id, maxPixel: px) {
                    let s = min(imgRect.width / CGFloat(img.width), imgRect.height / CGFloat(img.height)); let dw = CGFloat(img.width) * s, dh = CGFloat(img.height) * s
                    let dr = CGRect(x: imgRect.midX - dw / 2, y: imgRect.midY - dh / 2, width: dw, height: dh)
                    if layout.framed { ctx.setStrokeColor(gray: 0.4, alpha: 1); ctx.setLineWidth(0.8); ctx.stroke(dr.insetBy(dx: -5, dy: -5)) }
                    ctx.draw(img, in: dr)
                    if !o.watermark.isEmpty { DrawText.draw(o.watermark, in: CGRect(x: dr.minX, y: dr.minY + 4, width: dr.width, height: 14), ctx: ctx, font: "Helvetica-Bold", size: 10, color: [1, 1, 1]) }
                }
                if let v = store.versions[id] {
                    var lines: [String] = []
                    if o.showName || layout.labels { lines.append(v.name) }; if o.showDate { lines.append(v.imageDate.formatted(date: .abbreviated, time: .shortened)) }
                    if o.showCaption, !v.caption.isEmpty { lines.append(v.caption) }
                    if o.showExif, let m = store.masters[v.masterID] { let ex = ExifReader.values(for: store.masterURL(m), master: m, isMissing: false, version: v); lines.append([ex["exif.aperture"], ex["exif.shutter"], ex["exif.iso"].map { "ISO " + $0 }].compactMap { $0 }.joined(separator: " · ")) }
                    for (i, l) in lines.prefix(4).enumerated() { DrawText.draw(l, in: CGRect(x: cell.minX, y: cell.minY + labelH - 14 * CGFloat(i + 1), width: cell.width, height: 13), ctx: ctx, font: "Helvetica", size: 8.5, color: [0.2, 0.2, 0.2]) }
                }
            }
            let footer = [o.footer, o.pageNumbers ? "\(p + 1)/\(pages)" : ""].filter { !$0.isEmpty }.joined(separator: "   ")
            if !footer.isEmpty { DrawText.draw(footer, in: CGRect(x: m, y: m - 4, width: w - 2 * m, height: 12), ctx: ctx, font: "Helvetica", size: 8, color: [0.4, 0.4, 0.4]) }
            ctx.endPDFPage()
        }
        ctx.closePDF(); return pages
    }
}

import SwiftUI
import AppKit
import RetroluxCore

/// Image well: draws the rendered proxy fitted (or 1:1 with panning), handles brush / crop / click tools.
final class CanvasView: NSView {
    weak var model: AppModel?
    var image: NSImage? { didSet { needsDisplay = true } }
    var zoomActual = false { didSet { pan = .zero; needsDisplay = true } }
    var tool: ViewerTool = .select
    var cropRect: CGRect? { didSet { needsDisplay = true } }     // in displayed-image fractions
    var brushRadiusView: CGFloat = 20
    var onPoints: (([CGPoint], CGPoint?, [Double]) -> Void)?       // normalized points, optional source point (normalized), pressures
    var onPick: ((CGPoint) -> Void)?
    var faceBoxes: [FaceBox] = [] { didSet { needsDisplay = true } }
    var addFace = false
    var onFaceClick: ((ID) -> Void)?
    var onFaceRect: ((CGRect) -> Void)?
    private var faceDragStart: CGPoint?
    private var faceDragCur: CGPoint?
    var loupeImage: CGImage?
    var loupeOn = false
    var loupeZoom = 2.0
    var loupeDiameter = 300.0
    private var pressures: [Double] = []
    var onCrop: ((CGRect) -> Void)?
    var onCropEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var pan = CGPoint.zero
    private var stroke: [CGPoint] = []
    private var sourceNorm: CGPoint?
    private var hover: CGPoint?
    private var cropDrag: (handle: Int, start: CGPoint, orig: CGRect)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func imageRect() -> CGRect {
        guard let img = image, img.size.width > 0 else { return .zero }
        let b = bounds.insetBy(dx: 10, dy: 10)
        if zoomActual {
            let sc = window?.backingScaleFactor ?? 2
            let w = img.size.width / sc, h = img.size.height / sc
            return CGRect(x: bounds.midX - w / 2 + pan.x, y: bounds.midY - h / 2 + pan.y, width: w, height: h)
        }
        let s = min(b.width / img.size.width, b.height / img.size.height)
        let w = img.size.width * s, h = img.size.height * s
        return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
    }
    private func norm(_ p: CGPoint) -> CGPoint { let r = imageRect(); return CGPoint(x: (p.x - r.minX) / max(1, r.width), y: (p.y - r.minY) / max(1, r.height)) }
    private func viewPt(_ n: CGPoint) -> CGPoint { let r = imageRect(); return CGPoint(x: r.minX + n.x * r.width, y: r.minY + n.y * r.height) }

    override func draw(_ dirtyRect: NSRect) {
        if model?.fullScreenViewer == true { let v = CGFloat(UserDefaults.standard.double(forKey: "fullScreenBrightness") * 0.62); NSColor(srgbRed: v, green: v, blue: v, alpha: 1).setFill(); bounds.fill() } else {
        NSGradient(starting: NSColor(srgbRed: 0.30, green: 0.30, blue: 0.30, alpha: 1), ending: NSColor(srgbRed: 0.22, green: 0.22, blue: 0.22, alpha: 1))?.draw(in: bounds, angle: 90) }
        guard let img = image else { return }
        let r = imageRect()
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.6); shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width: 0, height: -2); shadow.set()
        NSColor.black.setFill(); r.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        // brush overlay
        if case .select = tool {} else if case .crop = tool {} else if case .wbPicker = tool {} else {
            if let h = hover, r.contains(h) { let rr = brushRadiusView; let c = NSBezierPath(ovalIn: CGRect(x: h.x - rr, y: h.y - rr, width: rr * 2, height: rr * 2)); NSColor.white.withAlphaComponent(0.9).setStroke(); c.lineWidth = 1; c.stroke() }
            if stroke.count > 1 { let p = NSBezierPath(); p.move(to: viewPt(stroke[0])); for q in stroke.dropFirst() { p.line(to: viewPt(q)) }; NSColor.systemYellow.withAlphaComponent(0.6).setStroke(); p.lineWidth = 2; p.stroke() }
            if let s = sourceNorm { let v = viewPt(s); let p = NSBezierPath(); p.move(to: CGPoint(x: v.x - 7, y: v.y)); p.line(to: CGPoint(x: v.x + 7, y: v.y)); p.move(to: CGPoint(x: v.x, y: v.y - 7)); p.line(to: CGPoint(x: v.x, y: v.y + 7)); NSColor.cyan.setStroke(); p.lineWidth = 1.5; p.stroke() }
        }
        for b in faceBoxes {
            let fr = CGRect(x: r.minX + b.rect.minX * r.width, y: r.minY + b.rect.minY * r.height, width: b.rect.width * r.width, height: b.rect.height * r.height)
            (b.confirmed ? NSColor.white : (b.suggested ? NSColor.systemYellow : NSColor.systemOrange)).setStroke()
            let p = NSBezierPath(roundedRect: fr, xRadius: 4, yRadius: 4); p.lineWidth = 2; p.stroke()
            let label = b.label.isEmpty ? "?" : b.label
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
            let sz = (label as NSString).size(withAttributes: attrs)
            let lab = CGRect(x: fr.midX - sz.width / 2 - 5, y: fr.maxY + 3, width: sz.width + 10, height: sz.height + 2)
            NSColor.black.withAlphaComponent(0.65).setFill(); NSBezierPath(roundedRect: lab, xRadius: 4, yRadius: 4).fill(); (label as NSString).draw(at: CGPoint(x: lab.minX + 5, y: lab.minY + 1), withAttributes: attrs)
        }
        if let a = faceDragStart, let b = faceDragCur { let rr = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)); NSColor.systemOrange.setStroke(); let p = NSBezierPath(rect: rr); p.lineWidth = 2; p.setLineDash([5, 3], count: 2, phase: 0); p.stroke() }
        if loupeOn, let h = hover, r.contains(h) {
            let d = CGFloat(loupeDiameter), rr = d / 2
            let nx = (h.x - r.minX) / r.width, ny = (h.y - r.minY) / r.height
            let src = loupeImage ?? img.cgImage(forProposedRect: nil, context: nil, hints: nil)
            if let cg = src {
                NSGraphicsContext.saveGraphicsState()
                let circle = NSBezierPath(ovalIn: CGRect(x: h.x - rr, y: h.y - rr, width: d, height: d)); circle.addClip()
                NSColor.black.setFill(); circle.fill()
                let sc = window?.backingScaleFactor ?? 2
                let zoom = CGFloat(loupeZoom)
                let cx = nx * CGFloat(cg.width), cy = ny * CGFloat(cg.height)       // center in loupe-source pixels (top-left origin)
                let sw = d * sc / zoom, sh = d * sc / zoom
                if let crop = cg.cropping(to: CGRect(x: cx - sw / 2, y: cy - sh / 2, width: sw, height: sh).integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))) {
                    let img2 = NSImage(cgImage: crop, size: NSSize(width: CGFloat(crop.width) / sc * zoom, height: CGFloat(crop.height) / sc * zoom))
                    img2.draw(in: CGRect(x: h.x - img2.size.width / 2, y: h.y - img2.size.height / 2, width: img2.size.width, height: img2.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
                }
                NSGraphicsContext.restoreGraphicsState()
                NSColor.white.setStroke(); circle.lineWidth = 2; circle.stroke()
                let cross = NSBezierPath(); cross.move(to: CGPoint(x: h.x - 6, y: h.y)); cross.line(to: CGPoint(x: h.x + 6, y: h.y)); cross.move(to: CGPoint(x: h.x, y: h.y - 6)); cross.line(to: CGPoint(x: h.x, y: h.y + 6)); NSColor.black.withAlphaComponent(0.6).setStroke(); cross.lineWidth = 1; cross.stroke()
            }
        }
        if case .crop = tool, let c = cropRect {
            let cr = CGRect(x: r.minX + c.minX * r.width, y: r.minY + c.minY * r.height, width: c.width * r.width, height: c.height * r.height)
            NSColor.black.withAlphaComponent(0.55).setFill()
            for rr in [CGRect(x: r.minX, y: r.minY, width: r.width, height: cr.minY - r.minY), CGRect(x: r.minX, y: cr.maxY, width: r.width, height: r.maxY - cr.maxY),
                       CGRect(x: r.minX, y: cr.minY, width: cr.minX - r.minX, height: cr.height), CGRect(x: cr.maxX, y: cr.minY, width: r.maxX - cr.maxX, height: cr.height)] { rr.fill() }
            NSColor.white.setStroke(); let b = NSBezierPath(rect: cr); b.lineWidth = 1; b.stroke()
            NSColor.white.withAlphaComponent(0.4).setStroke()
            for i in 1...2 { let g = NSBezierPath(); let fx = cr.minX + cr.width * CGFloat(i) / 3, fy = cr.minY + cr.height * CGFloat(i) / 3
                g.move(to: CGPoint(x: fx, y: cr.minY)); g.line(to: CGPoint(x: fx, y: cr.maxY)); g.move(to: CGPoint(x: cr.minX, y: fy)); g.line(to: CGPoint(x: cr.maxX, y: fy)); g.lineWidth = 0.5; g.stroke() }
            NSColor.white.setFill()
            for h in handlePoints(cr) { NSBezierPath(rect: CGRect(x: h.x - 4, y: h.y - 4, width: 8, height: 8)).fill() }
        }
    }
    private func handlePoints(_ r: CGRect) -> [CGPoint] { [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] }

    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }
    override func mouseMoved(with e: NSEvent) { hover = convert(e.locationInWindow, from: nil); needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if !faceBoxes.isEmpty || addFace {
            if addFace { faceDragStart = p; faceDragCur = p; return }
            let n = norm(p)
            if let hit = faceBoxes.first(where: { $0.rect.contains(n) }) { onFaceClick?(hit.id); return }
        }
        if e.clickCount == 2, case .select = tool { onDoubleClick?(); return }
        switch tool {
        case .select: break
        case .wbPicker: onPick?(norm(p))
        case .crop:
            guard let c = cropRect else { return }
            let r = imageRect(); let cr = CGRect(x: r.minX + c.minX * r.width, y: r.minY + c.minY * r.height, width: c.width * r.width, height: c.height * r.height)
            let hs = handlePoints(cr)
            if let i = hs.indices.first(where: { hypot(hs[$0].x - p.x, hs[$0].y - p.y) < 10 }) { cropDrag = (i, p, c) }
            else if cr.contains(p) { cropDrag = (-1, p, c) } else { cropDrag = nil }
        default:
            if (tool == .spotPatch || tool == .retouch), e.modifierFlags.contains(.option) { sourceNorm = norm(p); needsDisplay = true; return }
            stroke = [norm(p)]; pressures = [Double(e.pressure)]; needsDisplay = true
        }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil); hover = p
        if addFace, faceDragStart != nil { faceDragCur = p; needsDisplay = true; return }
        switch tool {
        case .select: if zoomActual { pan.x += e.deltaX; pan.y += e.deltaY; needsDisplay = true }
        case .wbPicker: break
        case .crop:
            guard let d = cropDrag else { return }
            let r = imageRect(); let dx = (p.x - d.start.x) / r.width, dy = (p.y - d.start.y) / r.height
            var n = d.orig
            if d.handle < 0 { n.origin.x = min(1 - n.width, max(0, d.orig.minX + dx)); n.origin.y = min(1 - n.height, max(0, d.orig.minY + dy)) }
            else {
                var x0 = d.orig.minX, y0 = d.orig.minY, x1 = d.orig.maxX, y1 = d.orig.maxY
                if d.handle == 0 || d.handle == 2 { x0 = min(x1 - 0.02, max(0, x0 + dx)) } else { x1 = max(x0 + 0.02, min(1, x1 + dx)) }
                if d.handle == 0 || d.handle == 1 { y0 = min(y1 - 0.02, max(0, y0 + dy)) } else { y1 = max(y0 + 0.02, min(1, y1 + dy)) }
                n = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            }
            cropRect = n; onCrop?(n)
        default:
            if !stroke.isEmpty { stroke.append(norm(p)); pressures.append(Double(e.pressure)); needsDisplay = true }
        }
    }
    override func mouseUp(with e: NSEvent) {
        if addFace, let a = faceDragStart, let b = faceDragCur {
            let na = norm(a), nb = norm(b); faceDragStart = nil; faceDragCur = nil; needsDisplay = true
            let rr = CGRect(x: min(na.x, nb.x), y: min(na.y, nb.y), width: abs(na.x - nb.x), height: abs(na.y - nb.y)).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if rr.width > 0.02, rr.height > 0.02 { onFaceRect?(rr) }; return
        }
        switch tool {
        case .crop: if cropDrag != nil { onCropEnd?() }; cropDrag = nil
        case .select, .wbPicker: break
        default:
            if !stroke.isEmpty { onPoints?(stroke, sourceNorm, pressures); stroke = []; pressures = []; needsDisplay = true }
        }
    }
    private var scrollAcc: CGFloat = 0
    override func scrollWheel(with e: NSEvent) {
        if zoomActual { pan.x += e.scrollingDeltaX; pan.y += e.scrollingDeltaY; needsDisplay = true }
        else if UserDefaults.standard.bool(forKey: "scrollNavigates") {      // Preferences ▸ General: scroll to navigate photos in the Viewer
            scrollAcc += e.scrollingDeltaY + e.scrollingDeltaX
            if abs(scrollAcc) >= 12 { model?.move(scrollAcc < 0 ? 1 : -1, columns: 1); scrollAcc = 0 }
        }
    }
    override func magnify(with e: NSEvent) { if e.magnification > 0.05 { model?.zoomActual = true; model?.scheduleRender() } else if e.magnification < -0.05 { model?.zoomActual = false; model?.scheduleRender() } }
}

struct ViewerCanvas: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeNSView(context: Context) -> CanvasView { let v = CanvasView(); v.model = model; return v }
    func updateNSView(_ v: CanvasView, context: Context) {
        v.image = model.viewerImage; v.tool = model.tool; v.zoomActual = model.zoomActual
        v.brushRadiusView = max(3, CGFloat(model.brushRadius) * pxPerMasterPx(v))
        v.cropRect = model.tool == .crop ? cropFractions() : nil
        DispatchQueue.main.async { let px = Int(max(v.bounds.width, v.bounds.height) * (v.window?.backingScaleFactor ?? 2)); if px > 200, abs(px - model.viewerTargetPixel) > 400 { model.viewerTargetPixel = min(4096, px); model.scheduleRender() } }
        v.loupeOn = model.loupe; v.loupeImage = model.loupeImage; v.loupeZoom = model.loupeZoom; v.loupeDiameter = model.loupeDiameter
        v.onPick = { p in model.pickWhiteBalance(at: p) }
        v.faceBoxes = model.faceBoxes(); v.addFace = model.addFaceMode && model.namingMode
        v.onFaceClick = { id in model.namingFace = id }; v.onFaceRect = { r in model.addManualFace(viewRect: r) }
        v.onPoints = { pts, src, pr in
            let mp = pts.compactMap { model.masterPoint(fromDisplay: $0) }
            var off: (Double, Double)? = nil
            if let s = src, let sp = model.masterPoint(fromDisplay: s), let f = mp.first { off = (f[0] - sp[0], f[1] - sp[1]) }
            model.addStroke(mp, source: off, pressure: pr)
        }
        v.onCrop = { f in model.cropFromDisplayFractions(f, commit: false) }
        v.onCropEnd = { model.commitAdjustments(model.L("Crop", "Zuschneiden")) }
        v.onDoubleClick = { model.viewMode = model.viewMode == .viewer ? .split : .viewer }
    }
    private func pxPerMasterPx(_ v: CanvasView) -> CGFloat {
        guard let m = model.primaryMaster, m.width > 0 else { return 0.2 }
        let r = v.imageRect(); let w = (model.primaryVersion?.rotation ?? 0) % 180 == 0 ? CGFloat(m.width) : CGFloat(m.height)
        return r.width / max(1, w)
    }
    private func cropFractions() -> CGRect? {
        guard let m = model.primaryMaster else { return nil }
        let W = Double(m.width), H = Double(m.height)
        let c = model.adjustments.item(Catalog.crop)
        let x = c?.enabled == true ? c!.value("inputXOrigin") : 0, y = c?.enabled == true ? c!.value("inputYOrigin") : 0
        let w = c?.enabled == true ? c!.value("inputWidth") : W, h = c?.enabled == true ? c!.value("inputHeight") : H
        return model.displayRect(master: CGRect(x: x / W, y: y / H, width: w / W, height: h / H))
    }
}

extension AppModel {
    /// Rect in master-pixel fractions → displayed (rotated) fractions
    func displayRect(master r: CGRect) -> CGRect {
        let rot = ((primaryVersion?.rotation ?? 0) % 360 + 360) % 360
        switch rot {
        case 90: return CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
        case 180: return CGRect(x: 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)
        case 270: return CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
        default: return r
        }
    }
    func cropFromDisplayFractions(_ f: CGRect, commit: Bool) {
        guard let m = primaryMaster else { return }
        let rot = ((primaryVersion?.rotation ?? 0) % 360 + 360) % 360
        var r = f
        switch rot {   // inverse of displayRect
        case 90: r = CGRect(x: f.minY, y: 1 - f.maxX, width: f.height, height: f.width)
        case 180: r = CGRect(x: 1 - f.maxX, y: 1 - f.maxY, width: f.width, height: f.height)
        case 270: r = CGRect(x: 1 - f.maxY, y: f.minX, width: f.height, height: f.width)
        default: break
        }
        if editSnapshot0 == nil { beginEdit() }
        setCrop(x: Double(r.minX) * Double(m.width), y: Double(r.minY) * Double(m.height), w: Double(r.width) * Double(m.width), h: Double(r.height) * Double(m.height))
    }
}

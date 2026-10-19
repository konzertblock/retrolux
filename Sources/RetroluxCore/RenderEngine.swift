import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

public struct RenderRequest {
    public var url: URL
    public var isRaw: Bool
    public var originalSize: CGSize        // oriented master size in pixels
    public var rotation: Int
    public var adjustments: AdjustmentSet
    public var maxPixel: Int?              // nil = full resolution
    public var maskPreview = false         // show brush masks as a red overlay instead of their effect
    public init(url: URL, isRaw: Bool, originalSize: CGSize, rotation: Int = 0, adjustments: AdjustmentSet = AdjustmentSet(), maxPixel: Int? = nil) {
        self.url = url; self.isRaw = isRaw; self.originalSize = originalSize; self.rotation = rotation; self.adjustments = adjustments; self.maxPixel = maxPixel
    }
}

/// Constants of the Core Image approximations. Calibrated against reference renderings.
public struct RenderTuning: Sendable {
    // Calibrated against reference renderings (41 adjusted versions without brush masks, train/validation split):
    // validation error 10.41 → 9.89 (mean |Δ| per channel, 0–255). See docs/COLOR-DEVIATION.md.
    public var evScale = 1.08, biasPerUnit = 0.00119, brightnessScale = 0.1, recoveryStrength = 0.14875
    public var contrastScale = 0.6, definitionScale = 0.8, vibrancyScale = 1.0
    public var hsShadow = 0.75, hsHighlight = 1.68, hsRadius = 0.2
    public var vignetteIntensity = 1.02, vignetteRadius = 2.4
    public var satScale = 1.0
    /// Space in which the Levels/Curves/Color LUT and the tint cube are applied (0 sRGB, 1 ProPhoto γ1.8, 2 ProPhoto γ2.2, 3 Adobe RGB γ2.2, 4 sRGB primaries γ1.8, 5 linear). Chosen by measurement against Apple previews.
    public var lutSpace = 0.0
    /// Gamma of the perceptual space used for contrast operations (0 = sRGB curve).
    public var percGamma = 3.12
    /// Processing chain structure; switches let the fit decide when measurement disagrees.
    public var tone = 1.0                 // 1 = use the staged Exposure/Enhance chain
    public var rawEVInDecoder = 1.0        // RAW: EV inside the decoder instead of a gain afterwards
    public var levelsTone = 1.0, levelsMode = 0.0   // levelsMode: 0 = control points are gamma-1.8 values, 1 = gamma 2.2 (input mode of the filter)
    public var vignetteTone = 1.0, curveInGamma = 0.0, rawEDR = 1.0, rawShadow = -1.0, rawBoost = -1.0
    public var biasScale = 0.001, contrastMean = 0.6, brightnessK = 1.0, lumaR = 0.2126, lumaG = 0.7152, lumaB = 0.0722
    nonisolated(unsafe) public static var current: RenderTuning = {
        var t = RenderTuning()
        // development aid: RL_TUNING='{"contrastMean":0.5}' overrides constants without a rebuild
        if let j = ProcessInfo.processInfo.environment["RL_TUNING"], let d = try? JSONSerialization.jsonObject(with: Data(j.utf8)) as? [String: Double] {
            let m: [String: WritableKeyPath<RenderTuning, Double>] = ["evScale": \.evScale, "biasScale": \.biasScale, "contrastMean": \.contrastMean, "brightnessK": \.brightnessK, "tone": \.tone,  "curveInGamma": \.curveInGamma, "rawEDR": \.rawEDR, "rawShadow": \.rawShadow, "rawBoost": \.rawBoost, "vignetteTone": \.vignetteTone, "levelsTone": \.levelsTone, "levelsMode": \.levelsMode, "rawEVInDecoder": \.rawEVInDecoder, "lumaR": \.lumaR, "lumaG": \.lumaG, "lumaB": \.lumaB, "satScale": \.satScale, "vibrancyScale": \.vibrancyScale, "lutSpace": \.lutSpace, "percGamma": \.percGamma, "hsShadow": \.hsShadow, "hsHighlight": \.hsHighlight, "hsRadius": \.hsRadius, "vignetteIntensity": \.vignetteIntensity, "vignetteRadius": \.vignetteRadius]
            for (k, v) in d { if let kp = m[k] { t[keyPath: kp] = v } }
        }
        return t
    }()
}

/// Non-destructive render pipeline. Original files are only ever read. Formulas are Core Image approximations of the
/// classic photo-editing operations.
public final class RenderEngine {
    public static let shared = RenderEngine()
    public let context: CIContext
    public let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let baseCache = NSCache<NSString, CIImage>()
    private let lock = NSLock()

    public init() {
        context = CIContext(options: [.cacheIntermediates: true, .priorityRequestLow: false])
        baseCache.countLimit = 12
    }

    // MARK: loading
    public static func probe(url: URL) -> (size: CGSize, date: Date?, rating: Int?, lat: Double?, lon: Double?, orientation: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        var w = (p[kCGImagePropertyPixelWidth] as? Double) ?? 0, h = (p[kCGImagePropertyPixelHeight] as? Double) ?? 0
        let o = (p[kCGImagePropertyOrientation] as? Int) ?? 1
        if o >= 5 { swap(&w, &h) }
        var date: Date?
        if let ex = p[kCGImagePropertyExifDictionary] as? [CFString: Any], let s = ex[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); date = f.date(from: s)
        }
        var lat: Double?, lon: Double?
        if let g = p[kCGImagePropertyGPSDictionary] as? [CFString: Any], let la = g[kCGImagePropertyGPSLatitude] as? Double, let lo = g[kCGImagePropertyGPSLongitude] as? Double {
            lat = (g[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -la : la; lon = (g[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lo : lo
        }
        return (CGSize(width: w, height: h), date, nil, lat, lon, o)
    }

    public func loadBase(url: URL, isRaw: Bool, originalSize: CGSize, maxPixel: Int?, raw: Adjustment?, wb: Adjustment?, ev: Double = 0) -> CIImage? {
        let key = "\(url.path)|\(maxPixel ?? 0)|ev\(ev)|\(raw.map { String(describing: $0.params.sorted { $0.key < $1.key }) } ?? "")|\(wb.map { String(describing: $0.params.sorted { $0.key < $1.key }) } ?? "")" as NSString
        lock.lock(); let hit = baseCache.object(forKey: key); lock.unlock()
        if let hit { return hit }
        var img: CIImage?
        if isRaw, let f = CIRAWFilter(imageURL: url) {
            let T = RenderTuning.current      // experiment knobs (RL_TUNING), neutral by default
            if T.rawEDR > 0 { f.extendedDynamicRangeAmount = Float(T.rawEDR) }
            if T.rawShadow >= 0 { f.boostShadowAmount = Float(T.rawShadow) }
            if T.rawBoost >= 0 { f.boostAmount = Float(T.rawBoost) }
            let longest = max(originalSize.width, originalSize.height)
            if let mp = maxPixel, longest > 0, CGFloat(mp) < longest { f.scaleFactor = Float(CGFloat(mp) / longest) }
            if let r = raw, r.enabled {
                f.boostAmount = Float(r.value("inputBoostAmount"))
                f.sharpnessAmount = Float(r.value("inputSharpenIntensity")) * 0.5
                f.luminanceNoiseReductionAmount = Float(r.value("inputNoiseReductionAmount"))
                f.moireReductionAmount = Float(r.value("inputChromaBlurMoireAmount"))
                // RAW Fine Tuning ▸ decoder: 2 = newest decoder, 1 = the previous one (historic processing,)
                let vers = f.supportedDecoderVersions
                if r.value("inputMethodVersion") < 1.5, vers.count > 1 { f.decoderVersion = vers[vers.count - 2] }
            }
            if ev != 0 { f.exposure = Float(ev) }
            if let w = wb, w.enabled, w.value("inputIsDefaults") < 0.5 { f.neutralTemperature = Float(w.value("inputTemperature")); f.neutralTint = Float(w.value("inputTint")) }
            img = f.outputImage
        } else if let mp = maxPixel, let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: mp, kCGImageSourceShouldCacheImmediately: true]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { img = CIImage(cgImage: cg) }
        } else {
            img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard let out = img else { return nil }
        let norm = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        lock.lock(); baseCache.setObject(norm, forKey: key); lock.unlock()
        return norm
    }

    // MARK: render
    public func render(_ req: RenderRequest) -> CIImage? {
        let set = req.adjustments
        let rawAdj = set.item(Catalog.raw), wbAdj = set.item(Catalog.wb)
        let T = RenderTuning.current
        let exAdj = set.item(Catalog.exposure), enAdj = set.item(Catalog.enhance)
        let useTone = T.tone > 0.5
        let rawEV = (useTone && req.isRaw && T.rawEVInDecoder > 0.5 && exAdj?.enabled == true) ? (exAdj?.value("inputEV") ?? 0) : 0
        guard var img = loadBase(url: req.url, isRaw: req.isRaw, originalSize: req.originalSize, maxPixel: req.maxPixel, raw: rawAdj, wb: wbAdj, ev: rawEV) else { return nil }
        let ow = max(1, req.originalSize.width > 0 ? req.originalSize.width : img.extent.width)
        let scale = img.extent.width / ow
        let H = img.extent.height
        let full = img.extent
        var toneDone = false
        for a in set.items where a.enabled && !a.isDefault {
            if a.id == Catalog.raw { continue }
            if useTone && (a.id == Catalog.exposure || a.id == Catalog.enhance) {
                if !toneDone { toneDone = true; img = toneStage(img, toneParams(exposure: exAdj, enhance: enAdj, isRaw: req.isRaw, rawEVApplied: rawEV != 0, scale: scale, extent: img.extent)) }
                continue
            }
            if a.id == Catalog.wb && req.isRaw { continue }      // applied inside the RAW decoder
            if a.id == Catalog.crop || a.id == Catalog.straighten { continue }   // geometric, applied last
            if a.id == Catalog.vignette && RenderTuning.current.vignetteTone > 0.5 { continue }   // post-geometry operation
            img = apply(a, to: img, scale: scale, set: set)
        }
        // stroke-based retouching works in master pixel coordinates
        for a in set.items where a.enabled && !a.strokes.isEmpty { img = applyStrokes(a, to: img, scale: scale, height: H) }
        for b in set.brushes where b.enabled && !b.strokes.isEmpty { img = applyBrush(b, to: img, scale: scale, height: H, full: full, preview: req.maskPreview) }
        if let s = set.item(Catalog.straighten), s.enabled, abs(s.value("inputRotation")) > 0.001 { img = straighten(img, degrees: s.value("inputRotation")) }
        if let c = set.item(Catalog.crop), c.enabled {
            let x = c.value("inputXOrigin") * scale, w = c.value("inputWidth") * scale, h = c.value("inputHeight") * scale
            let y = c.value("inputYOrigin") * scale
            if w > 1, h > 1 { img = img.cropped(to: CGRect(x: img.extent.minX + x, y: img.extent.maxY - y - h, width: w, height: h)).transformed(by: CGAffineTransform(translationX: -(img.extent.minX + x), y: -(img.extent.maxY - y - h))) }
        }
        if let v = set.item(Catalog.vignette), v.enabled, !v.isDefault, RenderTuning.current.vignetteTone > 0.5 { img = toneVignette(img, v) }
        img = rotate(img, degrees: req.rotation)
        return img
    }

    /// Map slider values onto the staged Exposure/Enhance chain.
    func toneParams(exposure ex: Adjustment?, enhance en: Adjustment?, isRaw: Bool, rawEVApplied: Bool, scale: CGFloat, extent: CGRect) -> ToneParams {
        let T = RenderTuning.current
        var p = ToneParams()
        if let e = ex, e.enabled {
            let ev = e.value("inputEV"), b = e.value("inputBias") * T.biasScale
            p.recovery = e.value("inputRecoveryEV")
            p.brightnessPower = exp(-T.brightnessK * e.value("inputBrightness"))
            if isRaw {
                // RAW: EV inside the decoder, then slope/offset black point, then recovery
                if !rawEVApplied { p.gain = pow(2, ev) }
                let s = pow(2, ev)
                if b != 0 { p.biasSlope = 1 / (1 - b); p.biasOffset = b * s / (1 - b) * (rawEVApplied ? 1 : 1) }
                p.recoveryBeforeBias = false
            } else {
                // other masters: gain 1/(2^-EV − b), recovery cubic, then an additive black point of −b·gain
                let g = b != 0 ? 1 / (pow(2, -ev) - b) : pow(2, ev)
                p.gain = g; p.biasOffset = b * g; p.recoveryBeforeBias = true
            }
        }
        if let e = en, e.enabled {
            p.contrast = e.value("inputContrast"); p.mean = T.contrastMean
            p.cast = ["inputBlackUOffset", "inputBlackVOffset", "inputGrayUOffset", "inputGrayVOffset", "inputWhiteUOffset", "inputWhiteVOffset"].map { e.value($0) * 1.0 }
            p.grayBrightness = e.params["inputGrayBrightness"] ?? 0.5
            p.saturation = 1 + (e.value("inputSaturation") - 1) * T.satScale
            p.vibrance = e.value("inputVibrancy") * T.vibrancyScale
            p.definition = e.value("inputDefinition") * 0.5
            let minDim = min(extent.width, extent.height)
            p.sigma = Double(max(0, min(minDim / 3000 * 50, scale * 50)))
            p.lumaWeights = [T.lumaR, T.lumaG, T.lumaB]
        }
        return p
    }

    func rotate(_ img: CIImage, degrees: Int) -> CIImage {
        let d = ((degrees % 360) + 360) % 360
        guard d != 0 else { return img }
        let e = img.extent
        let t: CGAffineTransform
        switch d { case 90: t = CGAffineTransform(rotationAngle: -.pi / 2); case 180: t = CGAffineTransform(rotationAngle: .pi); default: t = CGAffineTransform(rotationAngle: .pi / 2) }
        let r = img.transformed(by: t)
        return r.transformed(by: CGAffineTransform(translationX: -r.extent.minX, y: -r.extent.minY))
            .cropped(to: CGRect(x: 0, y: 0, width: d == 180 ? e.width : e.height, height: d == 180 ? e.height : e.width))
    }

    func straighten(_ img: CIImage, degrees: Double) -> CIImage {
        let e = img.extent, th = degrees * .pi / 180
        let c = CGPoint(x: e.midX, y: e.midY)
        var t = CGAffineTransform(translationX: c.x, y: c.y); t = t.rotated(by: th); t = t.translatedBy(x: -c.x, y: -c.y)
        let rot = img.clampedToExtent().transformed(by: t)
        let a = max(e.width / e.height, e.height / e.width)
        let s = 1 / (abs(cos(th)) + abs(sin(th)) * a)
        let w = e.width * s, h = e.height * s
        let r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        return rot.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    // MARK: operations
    func perceptual(_ img: CIImage, _ f: (CIImage) -> CIImage) -> CIImage {
        if RenderTuning.current.percGamma > 0.1 {
            let g = RenderTuning.current.percGamma
            let a = CIFilter.gammaAdjust(); a.inputImage = img; a.power = Float(1 / g)
            let b = CIFilter.gammaAdjust(); b.inputImage = f(a.outputImage ?? img); b.power = Float(g)
            return b.outputImage ?? img
        }
        let a = CIFilter.linearToSRGBToneCurve(); a.inputImage = img
        let b = CIFilter.sRGBToneCurveToLinear(); b.inputImage = f(a.outputImage ?? img)
        return b.outputImage ?? img
    }

    func matrix(_ img: CIImage, r: CIVector, g: CIVector, b: CIVector, bias: CIVector = CIVector(x: 0, y: 0, z: 0, w: 0)) -> CIImage {
        let f = CIFilter.colorMatrix(); f.inputImage = img
        f.rVector = r; f.gVector = g; f.bVector = b; f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1); f.biasVector = bias
        return f.outputImage ?? img
    }

    func apply(_ a: Adjustment, to input: CIImage, scale: CGFloat, set: AdjustmentSet) -> CIImage {
        var img = input
        func v(_ k: String) -> Double { a.value(k) }
        switch a.id {
        case Catalog.wb:
            if v("inputIsDefaults") >= 0.5 { return img }
            let f = CIFilter.temperatureAndTint(); f.inputImage = img
            f.neutral = CIVector(x: v("inputTemperature"), y: v("inputTint")); f.targetNeutral = CIVector(x: 6500, y: 0)
            return f.outputImage ?? img
        case Catalog.exposure:
            if v("inputEV") != 0 { let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = Float(v("inputEV") * RenderTuning.current.evScale); img = f.outputImage ?? img }
            let rec = v("inputRecoveryEV")
            if rec > 0 { let f = CIFilter.highlightShadowAdjust(); f.inputImage = img; f.highlightAmount = Float(1 - min(rec / 1.5, 1) * RenderTuning.current.recoveryStrength); f.shadowAmount = 0; f.radius = 0; img = f.outputImage ?? img }
            let bp = min(0.2, max(-0.05, v("inputBias") * RenderTuning.current.biasPerUnit)), br = v("inputBrightness") * RenderTuning.current.brightnessScale
            if bp != 0 || br != 0 {
                let s = 1 / (1 - bp), bias = -bp * s + br
                img = matrix(img, r: CIVector(x: s, y: 0, z: 0, w: 0), g: CIVector(x: 0, y: s, z: 0, w: 0), b: CIVector(x: 0, y: 0, z: s, w: 0), bias: CIVector(x: bias, y: bias, z: bias, w: 0))
            }
            return img
        case Catalog.enhance:
            let c = v("inputContrast"), sat = v("inputSaturation"), vib = v("inputVibrancy"), def = v("inputDefinition")
            if c != 0 { img = perceptual(img) { i in let f = CIFilter.colorControls(); f.inputImage = i; f.contrast = Float(1 + c * RenderTuning.current.contrastScale); return f.outputImage ?? i } }
            if sat != 1 { let f = CIFilter.colorControls(); f.inputImage = img; f.saturation = Float(1 + (sat - 1) * RenderTuning.current.satScale); img = f.outputImage ?? img }
            if vib != 0 { let f = CIFilter.vibrance(); f.inputImage = img; f.amount = Float(vib * RenderTuning.current.vibrancyScale); img = f.outputImage ?? img }
            if def > 0 { let f = CIFilter.unsharpMask(); f.inputImage = img; f.radius = Float(max(2, 40 * scale)); f.intensity = Float(def * RenderTuning.current.definitionScale); img = f.outputImage ?? img }
            if let tint = ColorLUT.tintCube(a) { let f = CIFilter.colorCubeWithColorSpace(); f.inputImage = img; f.cubeDimension = 33; f.cubeData = tint; f.colorSpace = WorkingSpaces.lut(Int(RenderTuning.current.lutSpace.rounded())); img = f.outputImage ?? img }
            return img
        case Catalog.shadowHighlight:
            let f = CIFilter.highlightShadowAdjust(); f.inputImage = img
            f.shadowAmount = Float(v("inputShadowAmount") / 100 * RenderTuning.current.hsShadow); f.highlightAmount = Float(1 - v("inputHighlightAmount") / 100 * RenderTuning.current.hsHighlight)
            f.radius = Float(min(100, max(0, v("inputRadius") * scale * RenderTuning.current.hsRadius)))
            img = f.outputImage ?? img
            let mc = v("inputMidtoneContrast")
            if mc != 0 { img = perceptual(img) { i in let g = CIFilter.colorControls(); g.inputImage = i; g.contrast = Float(1 + mc / 100 * 0.5); return g.outputImage ?? i } }
            return img
        case Catalog.levels where RenderTuning.current.levelsTone > 0.5:
            return toneLevels(img, a, mode: Int(a.params["inputMode"] ?? RenderTuning.current.levelsMode))
        case Catalog.levels, Catalog.curves, Catalog.color:
            // They are applied at their own positions in the chain (Curves → Shadows & Highlights → Levels → Color), so one LUT per operation
            let lv = a.id == Catalog.levels ? a : nil, cu = a.id == Catalog.curves ? a : nil, co = a.id == Catalog.color ? a : nil
            guard let data = ColorLUT.cube(levels: lv, curves: cu, color: co) else { return img }
            let f = CIFilter.colorCubeWithColorSpace(); f.inputImage = img; f.cubeDimension = 33; f.cubeData = data; f.colorSpace = WorkingSpaces.lut(Int(RenderTuning.current.lutSpace.rounded()))
            return f.outputImage ?? img
        case Catalog.mono:
            let r = v("inputRValue") / 100, g = v("inputGValue") / 100, b = v("inputBValue") / 100
            let row = CIVector(x: r, y: g, z: b, w: 0)
            return matrix(img, r: row, g: row, b: row)
        case Catalog.sepia: let f = CIFilter.sepiaTone(); f.inputImage = img; f.intensity = Float(v("inputIntensity")); return f.outputImage ?? img
        case Catalog.colorMono:
            let f = CIFilter.colorMonochrome(); f.inputImage = img; f.color = CIColor(red: v("inputRed"), green: v("inputGreen"), blue: v("inputBlue")); f.intensity = Float(v("inputIntensity")); return f.outputImage ?? img
        case Catalog.noise:
            let f = CIFilter.noiseReduction(); f.inputImage = img; f.noiseLevel = Float(0.02 * v("inputRadius")); f.sharpness = Float(0.4 * v("inputEdgeDetail") / 1.5); return f.outputImage ?? img
        case Catalog.sharpen:
            let f = CIFilter.sharpenLuminance(); f.inputImage = img; f.sharpness = Float(v("inputIntensity")); f.radius = Float(max(0.5, v("inputRadius") * 1.7 * scale)); return f.outputImage ?? img
        case Catalog.edgeSharpen:
            let f = CIFilter.unsharpMask(); f.inputImage = img; f.radius = Float(max(1, (1 + 6 * v("inputEdgeScale")) * scale * 2)); f.intensity = Float(v("inputSharpness") * 1.2 * (1 - 0.5 * v("inputFalloff"))); return f.outputImage ?? img
        case Catalog.vignette:
            let f = CIFilter.vignette(); f.inputImage = img; f.intensity = Float(min(1, v("inputIntensity") * RenderTuning.current.vignetteIntensity)); f.radius = Float(max(0.01, v("inputRadius") * RenderTuning.current.vignetteRadius)); return f.outputImage ?? img
        case Catalog.devignette:
            let f = CIFilter.vignette(); f.inputImage = img; f.intensity = Float(-min(1, v("inputIntensity"))); f.radius = Float(max(0.01, 1 + v("inputRadius"))); return f.outputImage ?? img
        case Catalog.chromatic:
            return chromatic(img, red: v("inputRedCyan"), blue: v("inputBlueYellow"))
        case Catalog.flip:
            let t = Int(v("inputFlipType")), e = img.extent
            var m = CGAffineTransform.identity
            if t & 1 != 0 { m = m.concatenating(CGAffineTransform(translationX: -e.midX, y: 0)).concatenating(CGAffineTransform(scaleX: -1, y: 1)).concatenating(CGAffineTransform(translationX: e.midX, y: 0)) }
            if t & 2 != 0 { m = m.concatenating(CGAffineTransform(translationX: 0, y: -e.midY)).concatenating(CGAffineTransform(scaleX: 1, y: -1)).concatenating(CGAffineTransform(translationX: 0, y: e.midY)) }
            return img.transformed(by: m)
        default: return img
        }
    }

    func chromatic(_ img: CIImage, red: Double, blue: Double) -> CIImage {
        guard red != 0 || blue != 0 else { return img }
        let e = img.extent, c = CGPoint(x: e.midX, y: e.midY)
        func scaled(_ ch: CIImage, _ s: Double) -> CIImage {
            let k = 1 + s * 0.0006
            var t = CGAffineTransform(translationX: c.x, y: c.y); t = t.scaledBy(x: k, y: k); t = t.translatedBy(x: -c.x, y: -c.y)
            return ch.transformed(by: t)
        }
        let z = CIVector(x: 0, y: 0, z: 0, w: 0)
        let r = scaled(matrix(img, r: CIVector(x: 1, y: 0, z: 0, w: 0), g: z, b: z), red)
        let g = matrix(img, r: z, g: CIVector(x: 0, y: 1, z: 0, w: 0), b: z)
        let b = scaled(matrix(img, r: z, g: z, b: CIVector(x: 0, y: 0, z: 1, w: 0)), blue)
        let a1 = CIFilter.additionCompositing(); a1.inputImage = r; a1.backgroundImage = g
        let a2 = CIFilter.additionCompositing(); a2.inputImage = a1.outputImage; a2.backgroundImage = b
        return (a2.outputImage ?? img).cropped(to: e)
    }

    // MARK: masks / strokes
    /// Renders strokes into a gray mask (white = effect). Coordinates: master pixels, top-left origin → proxy via `scale`.
    func mask(for strokes: [Stroke], size: CGSize, scale: CGFloat) -> CIImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cs = CGColorSpaceCreateDeviceGray()
        for s in strokes {
            let r = max(1, CGFloat(s.radius) * scale), op = CGFloat(min(1, max(0, s.opacity)))
            let soft = CGFloat(min(0.98, max(0.02, s.softness)))
            // gray + alpha pairs; solid core, falloff over `softness`. Paint = lighten (max), erase = darken (min).
            let grad = s.erase ? CGGradient(colorSpace: cs, colorComponents: [0, 1, 0, 1, 1, 1], locations: [0, 1 - soft, 1], count: 3)!
                               : CGGradient(colorSpace: cs, colorComponents: [op, 1, op, 1, 0, 1], locations: [0, 1 - soft, 1], count: 3)!
            ctx.setBlendMode(s.erase ? .darken : .lighten)
            var pts: [CGPoint] = s.points.compactMap { $0.count >= 2 ? CGPoint(x: $0[0] * Double(scale), y: Double(h) - $0[1] * Double(scale)) : nil }
            var pr = s.pressure.count == s.points.count ? s.pressure : [Double](repeating: 1, count: s.points.count)
            if pts.count == 1 { pts.append(pts[0]); pr.append(pr.first ?? 1) }
            let step = max(1, r * 0.25)
            for i in 1..<max(pts.count, 2) {
                let a = pts[i - 1], b = pts[min(i, pts.count - 1)], d = hypot(b.x - a.x, b.y - a.y), n = max(1, Int(d / step))
                for k in 0...n {
                    let t = CGFloat(k) / CGFloat(n), p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    let pp = CGFloat(pr[i - 1] + (pr[min(i, pr.count - 1)] - pr[i - 1]) * Double(t))
                    ctx.drawRadialGradient(grad, startCenter: p, startRadius: 0, endCenter: p, endRadius: max(1, r * (0.3 + 0.7 * pp)), options: [])
                }
            }
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    func applyBrush(_ b: BrushAdjustment, to img: CIImage, scale: CGFloat, height: CGFloat, full: CGRect, preview: Bool = false) -> CIImage {
        var effOpt = brushEffect(b, img, scale: scale)
        if preview { let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1)).cropped(to: full); let d = CIFilter.dissolveTransition(); d.inputImage = img; d.targetImage = red; d.time = 0.55; effOpt = d.outputImage }
        guard var m = mask(for: b.strokes, size: full.size, scale: scale), let eff = effOpt else { return img }
        if b.edgeDetect, let em = edgeMask(b.strokes, img, full: full, scale: scale) { m = multiplyMasks(m, em, full) }
        if b.tonalRange != 0 { m = multiplyMasks(m, tonalMask(img, b.tonalRange), full) }
        let f = CIFilter.blendWithMask(); f.inputImage = eff; f.backgroundImage = img; f.maskImage = m
        return f.outputImage?.cropped(to: full) ?? img
    }

    func multiplyMasks(_ a: CIImage, _ b: CIImage, _ full: CGRect) -> CIImage {
        let f = CIFilter.multiplyCompositing(); f.inputImage = a; f.backgroundImage = b
        return f.outputImage?.cropped(to: full) ?? a
    }
    /// luminance-based tone mask: 1 = shadows / midtones / highlights region
    func tonalMask(_ img: CIImage, _ range: Int) -> CIImage {
        let z = CIVector(x: 0, y: 0, z: 0, w: 0)
        func lum(_ k: Double, _ bias: Double) -> CIImage {
            let row = CIVector(x: 0.299 * k, y: 0.587 * k, z: 0.114 * k, w: 0)
            let m = matrix(img, r: row, g: row, b: row, bias: CIVector(x: bias, y: bias, z: bias, w: 0))
            let c = CIFilter.colorClamp(); c.inputImage = m; c.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0); c.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1); return c.outputImage ?? m
        }
        _ = z
        let perceptualImg = perceptual(img) { $0 }
        _ = perceptualImg
        let sh = lum(-2, 1), hi = lum(2, -1)
        switch range {
        case 1: return sh
        case 3: return hi
        default:
            let mx = CIFilter.maximumCompositing(); mx.inputImage = sh; mx.backgroundImage = hi
            let inv = CIFilter.colorInvert(); inv.inputImage = mx.outputImage; return inv.outputImage ?? sh
        }
    }
    /// Limits each stroke to pixels whose color is close to the color under the stroke's first point.
    func edgeMask(_ strokes: [Stroke], _ img: CIImage, full: CGRect, scale: CGFloat) -> CIImage? {
        var acc: CIImage?
        for s in strokes {
            guard let p = s.points.first, p.count >= 2, let sm = mask(for: [s], size: full.size, scale: scale) else { continue }
            let x = full.minX + CGFloat(p[0]) * scale, y = full.maxY - CGFloat(p[1]) * scale
            var px = [Float](repeating: 0, count: 4)
            context.render(img.cropped(to: CGRect(x: x, y: y, width: 1, height: 1)), toBitmap: &px, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            let ref = CIImage(color: CIColor(red: CGFloat(px[0]), green: CGFloat(px[1]), blue: CGFloat(px[2]))).cropped(to: full)
            let d = CIFilter.differenceBlendMode(); d.inputImage = img; d.backgroundImage = ref
            let sum = CIVector(x: 1.5, y: 1.5, z: 1.5, w: 0)
            let g = matrix(d.outputImage ?? img, r: sum, g: sum, b: sum)
            let inv = CIFilter.colorInvert(); inv.inputImage = g
            let gain = matrix(inv.outputImage ?? g, r: CIVector(x: 3, y: 0, z: 0, w: 0), g: CIVector(x: 0, y: 3, z: 0, w: 0), b: CIVector(x: 0, y: 0, z: 3, w: 0), bias: CIVector(x: -2, y: -2, z: -2, w: 0))
            let c = CIFilter.colorClamp(); c.inputImage = gain; c.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0); c.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
            let sim = c.outputImage ?? gain
            let lim = multiplyMasks(sm, sim, full)
            if let a = acc { let mx = CIFilter.maximumCompositing(); mx.inputImage = lim; mx.backgroundImage = a; acc = mx.outputImage?.cropped(to: full) } else { acc = lim }
        }
        return acc
    }

    func brushEffect(_ b: BrushAdjustment, _ img: CIImage, scale: CGFloat) -> CIImage? {
        func v(_ k: String) -> Double { b.value(k) }
        func mix(_ eff: CIImage?, _ t: Double) -> CIImage? {
            guard let eff else { return nil }; let f = CIFilter.dissolveTransition(); f.inputImage = img; f.targetImage = eff; f.time = Float(min(1, max(0, t))); return f.outputImage
        }
        switch b.op {
        case "skinSmoothing":
            let f = CIFilter.gaussianBlur(); f.inputImage = img.clampedToExtent(); f.radius = Float(max(0.1, v("inputRadius") * scale)); return mix(f.outputImage?.cropped(to: img.extent), v("inputIntensity") * 1.6)
        case "dodge": let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = Float(v("inputExposure") * 2); return f.outputImage
        case "burn": let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = Float(-v("inputExposure") * 2); return f.outputImage
        case "multiply": let f = CIFilter.multiplyBlendMode(); f.inputImage = img; f.backgroundImage = img; return mix(f.outputImage, v("inputIntensity"))
        case "overlayBlend": let f = CIFilter.overlayBlendMode(); f.inputImage = img; f.backgroundImage = img; return mix(f.outputImage, v("inputIntensity"))
        case "tint":
            let a = v("inputAngle") * .pi / 180, k = 0.06
            return matrix(img, r: CIVector(x: 1, y: 0, z: 0, w: 0), g: CIVector(x: 0, y: 1, z: 0, w: 0), b: CIVector(x: 0, y: 0, z: 1, w: 0), bias: CIVector(x: k * cos(a), y: k * sin(a + 2), z: k * sin(a), w: 0))
        case "contrast": return perceptual(img) { i in let f = CIFilter.colorControls(); f.inputImage = i; f.contrast = Float(1 + v("inputContrast") * 0.6); return f.outputImage ?? i }
        case "saturation": let f = CIFilter.colorControls(); f.inputImage = img; f.saturation = Float(v("inputSaturation")); return f.outputImage
        case "definition": let f = CIFilter.unsharpMask(); f.inputImage = img; f.radius = Float(max(1, v("inputRadius") * scale)); f.intensity = Float(v("inputIntensity")); return f.outputImage
        case "vibrancy": let f = CIFilter.vibrance(); f.inputImage = img; f.amount = Float(v("inputAmount")); return f.outputImage
        case "blur": let f = CIFilter.gaussianBlur(); f.inputImage = img.clampedToExtent(); f.radius = Float(max(0.1, v("inputIntensity") * scale * 0.6)); return f.outputImage?.cropped(to: img.extent)
        case "sharpen": let f = CIFilter.sharpenLuminance(); f.inputImage = img; f.sharpness = Float(v("inputSharpness") * 0.8); f.radius = Float(max(0.5, 1.7 * scale)); return f.outputImage
        case "defringe": let f = CIFilter.gaussianBlur(); f.inputImage = img.clampedToExtent(); f.radius = Float(max(0.1, 1.2 * scale)); return mix(f.outputImage?.cropped(to: img.extent), v("inputIntensity"))
        case "noise": let f = CIFilter.noiseReduction(); f.inputImage = img; f.noiseLevel = Float(0.02 * v("inputRadius")); f.sharpness = Float(0.4 * v("inputEdgeDetail") / 1.5); return f.outputImage
        default: return nil
        }
    }

    /// Retouch / Spot & Patch: copies pixels from an offset source through the stroke mask; Red Eye darkens red inside the spots.
    func applyStrokes(_ a: Adjustment, to img: CIImage, scale: CGFloat, height: CGFloat) -> CIImage {
        let ext = img.extent
        guard let m = mask(for: a.strokes, size: ext.size, scale: scale == 0 ? 1 : scale) else { return img }
        if a.id == Catalog.redEye {
            let z = CIVector(x: 0, y: 0, z: 0, w: 0)
            let fix = matrix(img, r: CIVector(x: 0.1, y: 0.45, z: 0.45, w: 0), g: CIVector(x: 0, y: 0.5, z: 0.1, w: 0), b: CIVector(x: 0, y: 0.1, z: 0.5, w: 0), bias: z)
            let f = CIFilter.blendWithMask(); f.inputImage = fix; f.backgroundImage = img; f.maskImage = m
            return f.outputImage?.cropped(to: ext) ?? img
        }
        // one source offset per stroke: composite stroke by stroke
        var out = img
        for s in a.strokes {
            guard let sm = mask(for: [s], size: ext.size, scale: scale == 0 ? 1 : scale) else { continue }
            let src = out.transformed(by: CGAffineTransform(translationX: CGFloat(s.sourceDX) * scale, y: -CGFloat(s.sourceDY) * scale))
            let f = CIFilter.blendWithMask(); f.inputImage = src; f.backgroundImage = out; f.maskImage = sm
            out = f.outputImage?.cropped(to: ext) ?? out
        }
        return out
    }

    // MARK: output
    public func cgImage(_ img: CIImage, colorSpace: CGColorSpace? = nil, deep: Bool = false) -> CGImage? {
        let e = img.extent.integral
        guard e.width >= 1, e.height >= 1 else { return nil }
        return context.createCGImage(img, from: e, format: deep ? .RGBA16 : .RGBA8, colorSpace: colorSpace ?? srgb)
    }
    public func renderCG(_ req: RenderRequest, deep: Bool = false, colorSpace: CGColorSpace? = nil) -> CGImage? { render(req).flatMap { cgImage($0, colorSpace: colorSpace, deep: deep) } }

    /// 256-bin RGB + luma histogram of the rendered image (small proxy), values normalized to 0…1.
    public func histogram(of cg: CGImage) -> [[Float]] {
        let w = 256, h = max(1, 256 * cg.height / max(1, cg.width))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .low; ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bins = [[Float]](repeating: [Float](repeating: 0, count: 256), count: 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i+1]), b = Int(px[i+2])
            bins[0][r] += 1; bins[1][g] += 1; bins[2][b] += 1
            bins[3][(r * 299 + g * 587 + b * 114) / 1000] += 1
        }
        let mx = max(1, bins.flatMap { $0 }.sorted().dropLast(4).last ?? 1)
        return bins.map { $0.map { min(1, $0 / mx) } }
    }

    /// Paints clipped highlights red and crushed shadows blue (View ▸ Highlight Hot & Cold Areas).
    /// `hot`/`cold` are the Preferences ▸ Advanced thresholds (100 % = only fully clipped values); `mono` paints white/black instead of red/blue.
    public func clippingOverlay(_ cg: CGImage, hot: Double = 1, cold: Double = 1, mono: Bool = false) -> CGImage? {
        let hi = 252 - Int((1 - min(1, max(0, hot))) * 40), lo = 3 + Int((1 - min(1, max(0, cold))) * 40)
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = px[i], g = px[i+1], b = px[i+2]
            if Int(r) >= hi || Int(g) >= hi || Int(b) >= hi { if mono { px[i] = 255; px[i+1] = 255; px[i+2] = 255 } else { px[i] = 255; px[i+1] = 0; px[i+2] = 0 } }
            else if Int(r) <= lo && Int(g) <= lo && Int(b) <= lo { if mono { px[i] = 0; px[i+1] = 0; px[i+2] = 0 } else { px[i] = 0; px[i+1] = 60; px[i+2] = 255 } }
        }
        return ctx.makeImage()
    }

    // MARK: white balance picker
    func sampleRGB(_ img: CIImage, at p: CGPoint, radius: CGFloat = 3) -> (Double, Double, Double)? {
        let e = img.extent
        let x = e.minX + p.x * e.width, y = e.maxY - p.y * e.height
        let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2).intersection(e)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let avg = CIFilter.areaAverage(); avg.inputImage = img.cropped(to: rect); avg.extent = rect
        guard let o = avg.outputImage else { return nil }
        var px = [Float](repeating: 0, count: 4)
        context.render(o, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: o.extent.minX, y: o.extent.minY, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }

    /// Finds temperature/tint that make the clicked pixel neutral. `p` is the click in fractions of the uncropped, unrotated image.
    /// Uses a finite-difference solve on a small render, so it is independent of the filter's sign conventions.
    public func solveWhiteBalance(url: URL, isRaw: Bool, originalSize: CGSize, adjustments: AdjustmentSet, at p: CGPoint, start: (Double, Double)) -> (temperature: Double, tint: Double)? {
        var set = adjustments
        set.remove(Catalog.crop); set.remove(Catalog.straighten); set.remove(Catalog.wb)
        // measure the picked pixel with all other adjustments applied but WB set to (t, tint)
        func err(_ t: Double, _ tint: Double) -> (Double, Double)? {
            var s2 = set; s2.upsert(Adjustment(id: Catalog.wb, params: ["inputTemperature": t, "inputTint": tint, "inputIsDefaults": 0]))
            guard let img = render(RenderRequest(url: url, isRaw: isRaw, originalSize: originalSize, rotation: 0, adjustments: s2, maxPixel: 600)),
                  let c = sampleRGB(img, at: p), c.0 > 1e-5, c.1 > 1e-5, c.2 > 1e-5 else { return nil }
            return (log(c.0 / c.2), log(c.1 / ((c.0 + c.2) / 2)))      // warm/cool error, green/magenta error
        }
        var m = 1e6 / min(14000, max(2000, start.0)), tint = start.1
        for _ in 0..<8 {
            guard let e0 = err(1e6 / m, tint), let e1 = err(1e6 / (m + 40), tint), let e2 = err(1e6 / m, tint + 10) else { return nil }
            if abs(e0.0) < 0.01 && abs(e0.1) < 0.01 { break }
            // 2x2 Jacobian solve: J * d = -e0
            let a = (e1.0 - e0.0) / 40, c = (e1.1 - e0.1) / 40, b = (e2.0 - e0.0) / 10, d = (e2.1 - e0.1) / 10
            let det = a * d - b * c
            guard abs(det) > 1e-12 else { break }
            let dm = (-e0.0 * d + e0.1 * b) / det, dt = (-a * e0.1 + c * e0.0) / det
            m = min(1e6 / 2000, max(1e6 / 14000, m + max(-150, min(150, dm)))); tint = min(150, max(-150, tint + max(-40, min(40, dt))))
        }
        return (min(14000, max(2000, 1e6 / m)), tint)
    }

    // MARK: soft proofing
    /// Simulates how `cg` looks when reproduced in `proof` (round trip through the profile; out-of-gamut colors are clipped).
    /// With `gamutWarning`, pixels that change noticeably are painted neutral gray.
    public func softProof(_ cg: CGImage, profile proof: CGColorSpace, intent: CGColorRenderingIntent = .relativeColorimetric, gamutWarning: Bool = false) -> CGImage? {
        let w = cg.width, h = cg.height
        let bi: UInt32 = proof.model == .cmyk ? CGImageAlphaInfo.none.rawValue : (proof.model == .monochrome ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let pctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: proof, bitmapInfo: bi) else { return nil }
        pctx.setRenderingIntent(intent); pctx.interpolationQuality = .none; pctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let proofed = pctx.makeImage(), let back = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        back.setRenderingIntent(intent); back.draw(proofed, in: CGRect(x: 0, y: 0, width: w, height: h))
        if gamutWarning, let base = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            base.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let a = base.data?.assumingMemoryBound(to: UInt8.self), let b = back.data?.assumingMemoryBound(to: UInt8.self) {
                let bpr = base.bytesPerRow
                for y in 0..<h { for x in 0..<w { let i = y * bpr + x * 4; let d = abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i+1]) - Int(b[i+1])) + abs(Int(a[i+2]) - Int(b[i+2])); if d > 24 { b[i] = 128; b[i+1] = 128; b[i+2] = 128 } } }
            }
        }
        return back.makeImage()
    }
}

/// Output / proofing profiles offered in the UI (names are our own; ICC files can be added by the user).
public enum WorkingSpaces {
    static func calibrated(white: [CGFloat], gamma: CGFloat, matrix: [CGFloat]) -> CGColorSpace? {
        CGColorSpace(calibratedRGBWhitePoint: white, blackPoint: nil, gamma: [gamma, gamma, gamma], matrix: matrix)
    }
    public static func lut(_ i: Int) -> CGColorSpace {
        let d50: [CGFloat] = [0.9642, 1, 0.8249], d65: [CGFloat] = [0.9505, 1, 1.089]
        let pro: [CGFloat] = [0.7977, 0.2880, 0.0000, 0.1352, 0.7119, 0.0000, 0.0313, 0.0001, 0.8249]
        let srgbM: [CGFloat] = [0.4124, 0.2126, 0.0193, 0.3576, 0.7152, 0.1192, 0.1805, 0.0722, 0.9505]
        switch i {
        case 1: return CGColorSpace(name: CGColorSpace.rommrgb) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        case 2: return calibrated(white: d50, gamma: 2.2, matrix: pro) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        case 3: return CGColorSpace(name: CGColorSpace.adobeRGB1998) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        case 4: return calibrated(white: d65, gamma: 1.8, matrix: srgbM) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        case 5: return CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        default: return CGColorSpace(name: CGColorSpace.sRGB)!
        }
    }
}

public enum ColorProfiles {
    public static let builtin: [(name: String, space: () -> CGColorSpace?)] = [
        ("sRGB IEC61966-2.1", { CGColorSpace(name: CGColorSpace.sRGB) }), ("Display P3", { CGColorSpace(name: CGColorSpace.displayP3) }), ("Adobe RGB (1998)", { CGColorSpace(name: CGColorSpace.adobeRGB1998) }),
        ("ProPhoto RGB", { CGColorSpace(name: CGColorSpace.rommrgb) }), ("Generic RGB", { CGColorSpace(name: CGColorSpace.genericRGBLinear) }), ("Gray Gamma 2.2", { CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) }), ("Generic CMYK (proof only)", { CGColorSpace(name: CGColorSpace.genericCMYK) })]
    public static func space(named n: String) -> CGColorSpace? {
        if let b = builtin.first(where: { $0.name == n }) { return b.space() }
        if n.hasPrefix("icc:"), let d = FileManager.default.contents(atPath: String(n.dropFirst(4))) { return CGColorSpace(iccData: d as CFData) }
        return nil
    }
}

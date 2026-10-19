import Foundation
import CoreImage
import Accelerate

/// Exposure + Enhance as one CPU pass, one processing chain:
/// gain → recovery cubic (Adobe RGB linear) → black point → brightness (power), then contrast (square-root space), colour cast,
/// saturation, vibrance and definition. 
struct ToneParams {
    var gain = 1.0                      // linear gain (EV applied here for non-RAW masters; RAW applies EV inside the decoder)
    var recovery = 0.0, breakpoint = 0.0
    var recoveryBeforeBias = true       // non-RAW: recovery then bias; RAW: bias then recovery
    var biasOffset = 0.0, biasSlope = 1.0, biasAdds = false   // t = (t*slope - offset); `biasAdds` = additive variant with gamut mapping
    var brightnessPower = 1.0
    var contrast = 0.0, mean = 0.0
    var cast: [Double] = [0, 0, 0, 0, 0, 0]   // black U/V, gray U/V, white U/V
    var grayBrightness = 0.5
    var saturation = 1.0, vibrance = 0.0
    var definition = 0.0, sigma = 0.0
    var lumaWeights: [Double] = [0.2126, 0.7152, 0.0722]

    var array: [Double] {
        [gain, recovery, breakpoint, recoveryBeforeBias ? 1 : 0, biasOffset, biasSlope, biasAdds ? 1 : 0, brightnessPower, contrast, mean,
         cast[0], cast[1], cast[2], cast[3], cast[4], cast[5], grayBrightness, saturation, vibrance, definition, sigma] + lumaWeights
    }
    var active: Bool {
        gain != 1 || recovery != 0 || biasOffset != 0 || biasSlope != 1 || brightnessPower != 1 || contrast != 0 || cast.contains { $0 != 0 }
            || grayBrightness != 0.5 || saturation != 1 || vibrance != 0 || definition != 0
    }
}

final class ToneStageKernel: CIImageProcessorKernel {
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    override class var outputFormat: CIFormat { .RGBAf }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        let a = (arguments?["p"] as? [Double]) ?? []
        let pad = a.count > 20 && a[19] != 0 ? CGFloat(ceil(3 * a[20])) : 0
        return outputRect.insetBy(dx: -pad, dy: -pad)
    }

    // linear sRGB ↔ Adobe RGB (1998) linear
    static let toA: [Float] = [0.71522, 0.28478, 0.0, 0.0, 1.0, 0.0, 0.0, 0.04115, 0.95885]
    static let fromA: [Float] = [1.39816, -0.39816, 0.0, 0.0, 1.0, 0.0, 0.0, -0.04291, 1.04291]
    @inline(__always) static func mul(_ m: [Float], _ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        (m[0] * r + m[1] * g + m[2] * b, m[3] * r + m[4] * g + m[5] * b, m[6] * r + m[7] * g + m[8] * b)
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let a = arguments?["p"] as? [Double], a.count >= 24 else { return }
        let inBase = input.baseAddress, outBase = output.baseAddress
        let iw = Int(input.region.width), ih = Int(input.region.height), ow = Int(output.region.width), oh = Int(output.region.height)
        let ox = Int(output.region.minX - input.region.minX), oy = Int(output.region.minY - input.region.minY)
        let inRow = input.bytesPerRow, outRow = output.bytesPerRow
        if ProcessInfo.processInfo.environment["RL_DEBUG"] != nil { FileHandle.standardError.write("tone iw=\(iw) ih=\(ih) ow=\(ow) oh=\(oh) ox=\(ox) oy=\(oy) inRow=\(inRow) outRow=\(outRow) in=\(input.region) out=\(output.region)\n".data(using: .utf8)!) }
        // working copy of the input region
        var buf = [Float](repeating: 0, count: iw * ih * 4)
        buf.withUnsafeMutableBytes { dst in for y in 0..<ih { memcpy(dst.baseAddress! + y * iw * 16, inBase + y * inRow, iw * 16) } }
        let dbg = ProcessInfo.processInfo.environment["RL_DEBUG"] != nil
        func stats(_ b: [Float]) -> String { var s: Float = 0, n = 0, nan = 0; for i in stride(from: 0, to: b.count, by: 4) { let v = b[i] + b[i+1] + b[i+2]; if v.isNaN { nan += 1 } else { s += v; n += 1 } }; return "mean=\(s / Float(max(n, 1)) / 3) nan=\(nan)" }
        if dbg { FileHandle.standardError.write("tone in \(stats(buf)) fmt=\(input.format.rawValue) outfmt=\(output.format.rawValue) p=\(a)\n".data(using: .utf8)!) }
        process(&buf, w: iw, h: ih, p: a)
        if dbg { FileHandle.standardError.write("tone out \(stats(buf))\n".data(using: .utf8)!) }
        if output.format == .RGBAf {
            buf.withUnsafeBytes { src in for y in 0..<oh { memcpy(outBase + y * outRow, src.baseAddress! + ((y + oy) * iw + ox) * 16, ow * 16) } }
        } else {   // the context may ask for half-float output
            buf.withUnsafeBufferPointer { src in
                for y in 0..<oh {
                    let d = (outBase + y * outRow).assumingMemoryBound(to: Float16.self)
                    let sp = src.baseAddress! + ((y + oy) * iw + ox) * 4
                    for i in 0..<(ow * 4) { d[i] = Float16(max(-65000, min(65000, sp[i]))) }
                }
            }
        }
    }

    static func process(_ buf: inout [Float], w: Int, h: Int, p a: [Double]) {
        let gain = Float(a[0]), rec = a[1], bp = a[2], recFirst = a[3] > 0.5
        let bOff = Float(a[4]), bSlope = Float(a[5]), bAdds = a[6] > 0.5, power = Float(a[7])
        let contrast = Float(a[8]), mean = Float(a[9])
        let cast = a[10..<16].map { Float($0) }, gray = Float(a[16]), sat = Float(a[17]), vib = Float(a[18]), def = Float(a[19]), sigma = a[20]
        let lw = a[21..<24].map { Float($0) }
        // recovery cubic: Hermite from (0,0) slope m0 to (2^rec, 1) slope m1
        var ca: Float = 0, cb: Float = 0, cc: Float = 1
        if rec != 0 {
            let x1 = pow(2.0, rec), m0 = bp / -5 + 1, m1 = (1 - m0 * 0.5) / (x1 - 0.5)
            ca = Float((x1 * m1 + x1 * m0 - 2) / (x1 * x1 * x1)); cb = Float((3 - 2 * x1 * m0 - x1 * m1) / (x1 * x1)); cc = Float(m0)
        }
        let doRec = rec != 0, doBias = bOff != 0 || bSlope != 1, doCast = cast.contains { $0 != 0 } || gray != 0.5
        // definition needs a blurred luminance-sum image of the image state before the definition step; computed lazily after the point ops
        let rowsPerChunk = 16, chunks = (h + rowsPerChunk - 1) / rowsPerChunk
        let doDef = def != 0 && sigma > 0.2
        var sums: [Float] = []
        buf.withUnsafeMutableBufferPointer { bp_ in
            let base = bp_.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { ch in
                for y in (ch * rowsPerChunk)..<min(h, (ch + 1) * rowsPerChunk) {
                    for x in 0..<w {
                        let q = base + (y * w + x) * 4
                        var r = q[0] * gain, g = q[1] * gain, b = q[2] * gain
                        func recover() {
                            var (ar, ag, ab) = mul(toA, r, g, b)
                            @inline(__always) func cub(_ v: Float) -> Float { ((ca * v + cb) * v + cc) * v }
                            ar = cub(ar); ag = cub(ag); ab = cub(ab)
                            (r, g, b) = mul(fromA, ar, ag, ab)
                        }
                        func bias() {
                            var (ar, ag, ab) = mul(toA, r, g, b)
                            ar = ar * bSlope - bOff; ag = ag * bSlope - bOff; ab = ab * bSlope - bOff
                            // gamut handling: keep luminance, pull negative components back (kernel bias2 / biasGamutMap)
                            let lum = (max(ar, 0) + max(ag, 0) + max(ab, 0)) / 3, tmin = min(ar, min(ag, ab))
                            var scale: Float = tmin < 0 ? lum / (lum - tmin) : 1
                            scale += (1 - scale) * min(lum * 2, 1)
                            ar = lum + scale * (ar - lum); ag = lum + scale * (ag - lum); ab = lum + scale * (ab - lum)
                            (r, g, b) = mul(fromA, ar, ag, ab)
                        }
                        if doRec && recFirst { recover() }
                        if doBias { bias() }
                        if doRec && !recFirst { recover() }
                        if power != 1 {
                            r = r > 0 ? powf(r, power) : r; g = g > 0 ? powf(g, power) : g; b = b > 0 ? powf(b, power) : b
                        }
                        if contrast != 0 {   // contrast in square-root space, negatives preserved
                            @inline(__always) func c(_ v: Float) -> Float {
                                let s = v < 0 ? -sqrtf(-v) : sqrtf(v); let smin = min(s, 0)
                                let t = max((1 + contrast) * s - contrast * mean, smin); return t < 0 ? -t * t : t * t
                            }
                            r = c(r); g = c(g); b = c(b)
                        }
                        if doCast {          // colour cast correction in YUV
                            let y0 = 0.299 * r + 0.587 * g + 0.114 * b, u0 = -0.147 * r - 0.289 * g + 0.436 * b, v0 = 0.615 * r - 0.515 * g - 0.100 * b
                            let lowT = max(0, min(1, y0 / gray)), upT = (y0 - gray) / (1 - gray)
                            var du: Float, dv: Float
                            if y0 - gray < 0 { du = cast[0] + (cast[2] - cast[0]) * lowT; dv = cast[1] + (cast[3] - cast[1]) * lowT }
                            else { du = cast[2] + (cast[4] - cast[2]) * upT; dv = cast[3] + (cast[5] - cast[3]) * upT }
                            let u = u0 + du, v = v0 + dv
                            r = y0 + 1.140 * v; g = y0 - 0.395 * u - 0.581 * v; b = y0 + 2.032 * u
                        }
                        if sat != 1 { let l = lw[0] * r + lw[1] * g + lw[2] * b; r = l + sat * (r - l); g = l + sat * (g - l); b = l + sat * (b - l) }
                        if vib != 0 {        // vibrance, skin-tone preserving
                            let p0 = (r, g, b)
                            let pr = min(max(r, 0.0001), 0.9999), pg = min(max(g, 0.0001), 0.9999), pb = min(max(b, 0.0001), 0.9999)
                            let dr = p0.0 - pr, dg = p0.1 - pg, db = p0.2 - pb
                            let gr = (pr + pg + pb) * 0.33333, mult = 1 / ((1 - gr) * gr), gi = (1 - gr) * mult, gii = gr * mult
                            func rs(_ v: Float) -> Float { min(max((v - gr) * gii, (gr - v) * gi), 0.99999) }
                            let sr = rs(pr), sg = rs(pg), sb = rs(pb)
                            let sat0 = min(max(max(sr, max(sg, sb)), 0.00001), 0.99999)
                            var skin = min(max(0, min(pr - pg, pg * 2 - pb)) * 4 * (1 - sr) * gi, 1)
                            skin = 0.15 + skin * 0.7
                            let v = vib
                            var tsat = max(1 - powf(1 - sat0, 1 + 3 * v), 0)
                            let tsat2 = sat0 + ((sat0 * sat0) * (sat0 - 1) + sat0) * v
                            tsat = tsat2 + (tsat - tsat2) * ((v > 0 ? 1 : v < 0 ? -1 : 0) * 0.5 + 0.5)
                            let boost = (1 - skin) * (tsat / sat0 - 1)
                            r = min(max(pr + (pr - gr) * boost, 0), 1) + dr; g = min(max(pg + (pg - gr) * boost, 0), 1) + dg; b = min(max(pb + (pb - gr) * boost, 0), 1) + db
                        }
                        q[0] = r; q[1] = g; q[2] = b
                    }
                }
            }
        }
        if doDef {
            // clarity: multiplicative local-contrast gain from the difference between the pixel and a Gaussian-blurred luminance sum
            sums = [Float](repeating: 0, count: w * h)
            for i in 0..<(w * h) { sums[i] = buf[i * 4] + buf[i * 4 + 1] + buf[i * 4 + 2] }
            let blur = gaussian(sums, w: w, h: h, sigma: Float(sigma))
            let pct = def
            for i in 0..<(w * h) {
                let sl = sums[i], bl = blur[i], dl = sl + (sl - bl) * pct
                var mult = dl / max(sl, 0.0001); mult = 1.571 * (mult - 1); mult = mult / (1 + abs(mult)); mult += 1
                mult = min(max(mult, 1 - 0.5 * pct), 1 + pct)
                buf[i * 4] *= mult; buf[i * 4 + 1] *= mult; buf[i * 4 + 2] *= mult
            }
        }
    }

    static func gaussian(_ src: [Float], w: Int, h: Int, sigma: Float) -> [Float] {
        let rad = max(1, Int(ceil(3 * sigma)))
        var k = [Float](repeating: 0, count: 2 * rad + 1); var s: Float = 0
        for i in -rad...rad { let v = expf(-Float(i * i) / (2 * sigma * sigma)); k[i + rad] = v; s += v }
        for i in 0..<k.count { k[i] /= s }
        var tmp = [Float](repeating: 0, count: w * h), out = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { var a: Float = 0; for i in -rad...rad { a += k[i + rad] * src[y * w + min(max(x + i, 0), w - 1)] }; tmp[y * w + x] = a } }
        for y in 0..<h { for x in 0..<w { var a: Float = 0; for i in -rad...rad { a += k[i + rad] * tmp[min(max(y + i, 0), h - 1) * w + x] }; out[y * w + x] = a } }
        return out
    }
}

extension RenderEngine {
    /// Run the Exposure/Enhance stage on `img`; no-op when nothing is set.
    func toneStage(_ img: CIImage, _ p: ToneParams) -> CIImage {
        guard p.active else { return img }
        let pad = p.definition != 0 ? Int(ceil(3 * p.sigma)) : 0
        _ = pad
        do { return try ToneStageKernel.apply(withExtent: img.extent, inputs: [img], arguments: ["p": p.array]) } catch { return img }
    }
}

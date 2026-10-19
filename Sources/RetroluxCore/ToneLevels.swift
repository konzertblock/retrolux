import Foundation
import CoreImage

/// Levels: per channel a master curve followed by a channel curve; each curve is the straight
/// line through black/white plus three smooth bumps that pull the quarter-tone, mid-tone and three-quarter-tone points onto their targets.
enum ToneLevels {
    /// Value of one curve (control points src/dst: black, shadow, mid, highlight, white) at x.
    static func curve(_ x: Double, _ s: [Double], _ d: [Double]) -> Double {
        let slope = (d[4] - d[0]) / (s[4] - s[0]), bias = d[0] - s[0] * slope
        func bump(_ x: Double, center c: Double, lower lo: Double, upper up: Double) -> Double {
            let inv = x >= c ? 1 / (c - up) : 1 / (c - lo)
            let t = (x - c) * inv
            return t + 1 >= 0 ? 1 - (2 * t + 3) * t * t : 0
        }
        let magMid = d[2] - (s[2] * slope + bias)
        let magSh = d[1] - (bump(s[1], center: s[2], lower: s[0], upper: s[4]) * magMid + bias + s[1] * slope)
        let magHl = d[3] - (bump(s[3], center: s[2], lower: s[0], upper: s[4]) * magMid + bias + s[3] * slope)
        return bias + slope * x + bump(x, center: s[2], lower: s[0], upper: s[4]) * magMid
            + bump(x, center: s[1], lower: s[0], upper: s[2]) * magSh + bump(x, center: s[3], lower: s[2], upper: s[4]) * magHl
    }

    /// 4096-entry tables over [-1, 3] for R, G, B.
    static func tables(_ a: [Double]) -> [[Float]] {
        let mode = Int(a[0])
        func pts(_ o: Int) -> ([Double], [Double]) {
            var s = Array(a[(1 + o)..<(6 + o)]), d = Array(a[(6 + o)..<(11 + o)])
            if mode == 0 { s = s.map { pow(max($0, 0), 1.8) }; d = d.map { pow(max($0, 0), 1.8) } }   // control points are gamma-1.8 values
            return (s, d)
        }
        let (ms, md) = pts(0)
        var out: [[Float]] = []
        for ch in 0..<3 {
            let (cs, cd) = pts(10 * (ch + 1))
            var t = [Float](repeating: 0, count: 4096)
            for i in 0..<4096 {
                var x = -1 + 4 * Double(i) / 4095
                if mode == 1 { x = x <= 0 ? x : pow(x, 0.4545) }
                var y = curve(curve(x, ms, md), cs, cd)
                if mode == 1 { y = y <= 0 ? y : pow(y, 2.2) }
                t[i] = Float(min(3, max(-1, y)))
            }
            out.append(t)
        }
        return out
    }
}

final class ToneLevelsKernel: CIImageProcessorKernel {
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    override class var outputFormat: CIFormat { .RGBAf }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let a = arguments?["p"] as? [Double], a.count >= 41 else { return }
        let tabs = ToneLevels.tables(a)
        let w = Int(output.region.width), h = Int(output.region.height)
        let ox = Int(output.region.minX - input.region.minX), oy = Int(output.region.minY - input.region.minY)
        let half = output.format != .RGBAf
        for y in 0..<h {
            let src = (input.baseAddress + (y + oy) * input.bytesPerRow).assumingMemoryBound(to: Float.self) + ox * 4
            let dstRow = output.baseAddress + y * output.bytesPerRow
            for x in 0..<w {
                var px: [Float] = [src[x * 4], src[x * 4 + 1], src[x * 4 + 2], src[x * 4 + 3]]
                for c in 0..<3 {
                    let v = max(px[c], 0), f = min(max((v + 1) / 4 * 4095, 0), 4094.0), i = Int(f), fr = f - Float(i)
                    px[c] = tabs[c][i] * (1 - fr) + tabs[c][i + 1] * fr
                }
                if half { let d = dstRow.assumingMemoryBound(to: Float16.self) + x * 4; for k in 0..<4 { d[k] = Float16(px[k]) } }
                else { let d = dstRow.assumingMemoryBound(to: Float.self) + x * 4; for k in 0..<4 { d[k] = px[k] } }
            }
        }
    }
}

extension RenderEngine {
    func toneLevels(_ img: CIImage, _ a: Adjustment, mode: Int) -> CIImage {
        func p(_ ch: String) -> [Double] {
            ["BlackSrc", "ShadowSrc", "MidSrc", "HilightSrc", "WhiteSrc", "BlackDst", "ShadowDst", "MidDst", "HilightDst", "WhiteDst"].map { a.value("input\($0)\(ch)") }
        }
        let arr = [Double(mode)] + p("RGB") + p("Red") + p("Green") + p("Blue")
        do { return try ToneLevelsKernel.apply(withExtent: img.extent, inputs: [img], arguments: ["p": arr]) } catch { return img }
    }
}

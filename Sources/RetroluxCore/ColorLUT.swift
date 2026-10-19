import Foundation

/// Per-channel tone mapping (Levels + Curves) and the six-band Color adjustment, baked into one 3D LUT in sRGB-encoded space.
public enum ColorLUT {
    /// Piecewise-linear map through (src,dst) points; below first src → first dst, above last → last dst.
    static func piecewise(_ pts: [(Double, Double)]) -> (Double) -> Double {
        let p = pts.sorted { $0.0 < $1.0 }
        return { x in
            guard let f = p.first, let l = p.last else { return x }
            if x <= f.0 { return f.1 }; if x >= l.0 { return l.1 }
            for i in 1..<p.count where x <= p[i].0 {
                let a = p[i-1], b = p[i]; let d = b.0 - a.0
                return d <= 1e-9 ? b.1 : a.1 + (b.1 - a.1) * (x - a.0) / d
            }
            return x
        }
    }

    static func levelsFunc(_ a: Adjustment?, channel: String) -> ((Double) -> Double)? {
        guard let a, a.enabled else { return nil }
        let names = ["Black", "Shadow", "Mid", "Hilight", "White"]
        let spec = Catalog.spec(Catalog.levels)
        func v(_ k: String) -> Double { a.params[k] ?? spec?.param(k)?.def ?? 0 }
        let pts = names.map { (v("input\($0)Src\(channel)"), v("input\($0)Dst\(channel)")) }
        if zip(pts, names.indices).allSatisfy({ abs($0.0.0 - $0.0.1) < 1e-9 }) { return nil }
        return piecewise(pts)
    }

    /// Natural cubic spline through the control points, : the first and last list entries are
    /// sentinels, the rest are spline knots; left of the first knot the curve is held, right of the last knot it is held when that knot is
    /// left of 1 and extended linearly otherwise. Returns nil for the identity.
    public static func curveFunc(_ pts: [CurvePoint]?) -> ((Double) -> Double)? {
        guard let pts, pts.contains(where: { $0.editable }), pts.count >= 4 else { return nil }
        let k = pts[1..<(pts.count - 1)].map { ($0.x, $0.y) }
        let n = k.count
        guard n >= 2 else { return nil }
        let x = k.map { $0.0 }, a = k.map { $0.1 }
        var b = [Double](repeating: 0, count: n), c = b, d = b
        if n > 2 {
            var h = [Double](repeating: 0, count: n - 1)
            for i in 0..<n-1 { h[i] = x[i+1] - x[i] }
            var mu = b, z = b, l = [Double](repeating: 1, count: n)
            for i in 1..<n-1 {
                let al = 3 / h[i] * (a[i+1] - a[i]) - 3 / h[i-1] * (a[i] - a[i-1])
                l[i] = 2 * (x[i+1] - x[i-1]) - h[i-1] * mu[i-1]
                mu[i] = h[i] / l[i]; z[i] = (al - h[i-1] * z[i-1]) / l[i]
            }
            for j in stride(from: n - 2, through: 0, by: -1) {
                c[j] = z[j] - mu[j] * c[j+1]
                b[j] = (a[j+1] - a[j]) / h[j] - h[j] * (c[j+1] + 2 * c[j]) / 3
                d[j] = (c[j+1] - c[j]) / (3 * h[j])
            }
        } else { b[0] = (a[1] - a[0]) / (x[1] - x[0]) }
        // last knot: slope continues from the final segment (cubic terms zero)
        let hl = x[n-1] - x[n-2]
        b[n-1] = b[n-2] + 2 * c[n-2] * hl + 3 * d[n-2] * hl * hl
        return { v in
            var i = 0; while i < n - 1 && v > x[i+1] { i += 1 }
            let dx = v - x[i]
            var y = a[i] + dx * b[i]
            if dx > 0 { y += dx * dx * c[i] + dx * dx * dx * d[i] }
            if x[0] > 0 && i == 0 && dx < 0 { y = a[0] }
            if x[n-1] < 1 && i == n - 1 { y = a[n-1] }
            return min(5, max(0, y))
        }
    }

    static func rgb2hsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn, s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double = mx == r ? (g - b) / d + (g < b ? 6 : 0) : (mx == g ? (b - r) / d + 2 : (r - g) / d + 4)
        h *= 60; return (h, s, l)
    }
    static func hsl2rgb(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func f(_ t0: Double) -> Double {
            var t = t0; if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1/6 { return p + (q - p) * 6 * t }; if t < 0.5 { return q }; if t < 2/3 { return p + (q - p) * (2/3 - t) * 6 }; return p
        }
        let hh = h.truncatingRemainder(dividingBy: 360) / 360
        return (f(hh + 1/3), f(hh), f(hh - 1/3))
    }

    static func colorFunc(_ a: Adjustment?) -> ((Double, Double, Double) -> (Double, Double, Double))? {
        guard let a, a.enabled, let spec = Catalog.spec(Catalog.color), !a.isDefault else { return nil }
        let bands = ["Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas"]
        let vals = bands.map { b in (a.value("input\(b)HueShift"), a.value("input\(b)Saturation"), a.value("input\(b)Luminance")) }
        _ = spec
        return { r, g, b in
            var (h, s, l) = rgb2hsl(r, g, b)
            guard s > 0.001 else { return (r, g, b) }
            var dh = 0.0, ds = 0.0, dl = 0.0
            for (i, v) in vals.enumerated() {
                var d = abs(h - Double(i) * 60); if d > 180 { d = 360 - d }
                let w = max(0, 1 - d / 60); if w == 0 { continue }
                dh += v.0 / 100 * 30 * w; ds += v.1 / 100 * w; dl += v.2 / 100 * 0.5 * w
            }
            h += dh; s = min(1, max(0, s * (1 + ds))); l = min(1, max(0, l + dl * s))
            return hsl2rgb(h < 0 ? h + 360 : h, s, l)
        }
    }

    /// Returns cube data (RGBA float, dimension n) or nil when the combined mapping is the identity.
    static func cube(levels: Adjustment?, curves: Adjustment?, color: Adjustment?, n: Int = 33) -> Data? {
        let lRGB = levelsFunc(levels, channel: "RGB"), lR = levelsFunc(levels, channel: "Red"), lG = levelsFunc(levels, channel: "Green"), lB = levelsFunc(levels, channel: "Blue")
        func cv(_ k: String) -> ((Double) -> Double)? {
            guard curves?.enabled == true, let f = curveFunc(curves?.curves[k]) else { return nil }
            guard RenderTuning.current.curveInGamma > 0.5 else { return f }
            // table lookup happens on linear^gamma; our LUT axis is sRGB-encoded
            let g = curves?.params["gamma"] ?? 0.4545454680919647
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            func enc(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
            return { x in enc(pow(f(pow(lin(x), g)), 1 / g)) }
        }
        let cRGB = cv("RGBCurvePoints"), cR = cv("redCurvePoints"), cG = cv("greenCurvePoints"), cB = cv("blueCurvePoints")
        let col = colorFunc(color)
        if lRGB == nil && lR == nil && lG == nil && lB == nil && cRGB == nil && cR == nil && cG == nil && cB == nil && col == nil { return nil }
        func chain(_ x: Double, _ fs: [((Double) -> Double)?]) -> Double { var v = x; for f in fs { if let f { v = f(v) } }; return min(1, max(0, v)) }
        var out = [Float](); out.reserveCapacity(n * n * n * 4)
        // CIColorCube: red varies fastest, then green, then blue
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            var r = Double(ri) / Double(n - 1), g = Double(gi) / Double(n - 1), b = Double(bi) / Double(n - 1)
            r = chain(r, [lRGB, lR, cRGB, cR]); g = chain(g, [lRGB, lG, cRGB, cG]); b = chain(b, [lRGB, lB, cRGB, cB])
            if let col { (r, g, b) = col(r, g, b); r = min(1, max(0, r)); g = min(1, max(0, g)); b = min(1, max(0, b)) }
            out.append(Float(r)); out.append(Float(g)); out.append(Float(b)); out.append(1)
        } } }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Split-toning from the Enhance tint wheels: black/gray/white U,V offsets weighted by luminance.
    static func tintCube(_ a: Adjustment, n: Int = 33) -> Data? {
        let keys = ["Black", "Gray", "White"]
        let off = keys.map { (a.value("input\($0)UOffset"), a.value("input\($0)VOffset")) }
        if off.allSatisfy({ abs($0.0) < 1e-6 && abs($0.1) < 1e-6 }) { return nil }
        var out = [Float](); out.reserveCapacity(n * n * n * 4)
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let r = Double(ri) / Double(n - 1), g = Double(gi) / Double(n - 1), b = Double(bi) / Double(n - 1)
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            let w = [(1 - l) * (1 - l), 4 * l * (1 - l), l * l]
            var du = 0.0, dv = 0.0
            for i in 0..<3 { du += off[i].0 * w[i]; dv += off[i].1 * w[i] }
            let k = 0.12
            let rr = r + k * 1.402 * dv, gg = g + k * (-0.344 * du - 0.714 * dv), bb = b + k * 1.772 * du
            out.append(Float(min(1, max(0, rr)))); out.append(Float(min(1, max(0, gg)))); out.append(Float(min(1, max(0, bb)))); out.append(1)
        } } }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

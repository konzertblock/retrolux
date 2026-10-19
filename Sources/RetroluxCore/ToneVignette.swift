import Foundation
import CoreImage

/// Power-law (cos²θ) vignette. Works on the cropped image: centre = middle of the crop,
/// size = min(width, height) / 2, radius = (4 − r) · size; type 1 raises the pixel to cos²θ^(−2I), the other types multiply by cos²θ^(2I).
final class ToneVignetteKernel: CIImageProcessorKernel {
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    override class var outputFormat: CIFormat { .RGBAf }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let a = arguments?["p"] as? [Double], a.count >= 6 else { return }
        let W = a[0], H = a[1], intensity = a[2] * 2, type = Int(a[3]), signFlip = a[4]
        let size = min(W, H) / 2, diag = (W * W + H * H).squareRoot() / 2
        var r = a[5]
        if size < diag / (4 - r) { r = 4 - diag / size }          // keep the vignette reaching the corners
        let radius = (4 - r) * size, radius2 = radius * radius, cx = W / 2, cy = H / 2
        let w = Int(output.region.width), h = Int(output.region.height)
        let ox = Int(output.region.minX - input.region.minX), oy = Int(output.region.minY - input.region.minY)
        let half = output.format != .RGBAf
        let gamma = type == 1
        let inten = Float(signFlip * intensity)
        for y in 0..<h {
            let src = (input.baseAddress + (y + oy) * input.bytesPerRow).assumingMemoryBound(to: Float.self) + ox * 4
            let dstRow = output.baseAddress + y * output.bytesPerRow
            let py = Double(Int(output.region.minY) + y) + 0.5 - cy
            for x in 0..<w {
                let px = Double(Int(output.region.minX) + x) + 0.5 - cx
                let len2 = px * px + py * py
                let cos2 = len2 < radius2 ? Float(1 - len2 / radius2) : 0
                var v = cos2 > 0 ? powf(cos2, gamma ? -inten : inten) : (gamma ? Float.infinity : 0)
                if v.isNaN { v = 1 }
                var r = src[x * 4], g = src[x * 4 + 1], b = src[x * 4 + 2]
                if gamma { r = r > 0 ? powf(r, v) : r; g = g > 0 ? powf(g, v) : g; b = b > 0 ? powf(b, v) : b }
                else { r *= v; g *= v; b *= v }
                let o: [Float] = [r, g, b, src[x * 4 + 3]]
                if half { let d = dstRow.assumingMemoryBound(to: Float16.self) + x * 4; for k in 0..<4 { d[k] = Float16(max(-65000, min(65000, o[k]))) } }
                else { let d = dstRow.assumingMemoryBound(to: Float.self) + x * 4; for k in 0..<4 { d[k] = o[k] } }
            }
        }
    }
}

extension RenderEngine {
    func toneVignette(_ img: CIImage, _ a: Adjustment) -> CIImage {
        let type = Int(a.value("inputType"))
        let arr = [Double(img.extent.width), Double(img.extent.height), a.value("inputIntensity"), Double(type == 2 ? 0 : type), type == 2 ? -1 : 1, a.value("inputRadius")]
        do { return try ToneVignetteKernel.apply(withExtent: img.extent, inputs: [img], arguments: ["p": arr]) } catch { return img }
    }
}

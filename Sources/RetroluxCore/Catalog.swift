import Foundation

/// Parameter definition. Keys, defaults and ranges of the adjustment controls; values that are estimates are marked `approx`.
public struct ParamSpec: Sendable {
    public enum Unit: String, Sendable { case none, kelvin, percent, degrees, pixels, ev }
    public let key: String
    public let en: String
    public let de: String
    public let def: Double
    public let min: Double
    public let max: Double
    public let sliderMin: Double
    public let sliderMax: Double
    public let unit: Unit
    public let approx: Bool
    public init(_ key: String, _ en: String, _ de: String, def: Double = 0, min: Double, max: Double,
                slider: ClosedRange<Double>? = nil, unit: Unit = .none, approx: Bool = false) {
        self.key = key; self.en = en; self.de = de; self.def = def; self.min = min; self.max = max
        self.sliderMin = slider?.lowerBound ?? min; self.sliderMax = slider?.upperBound ?? max
        self.unit = unit; self.approx = approx
    }
    public func clamp(_ v: Double) -> Double { Swift.min(max, Swift.max(min, v)) }
}

public enum OpKind: Sendable { case global, brush, stroke }

public struct OpSpec: Sendable {
    public let id: String          // operation identifier, e.g. exposure
    public let en: String
    public let de: String
    public let params: [ParamSpec]
    public let kind: OpKind
    public let tooltipEN: String
    /// true when merely adding the brick changes the image (Black & White, Sepia, Vignette …): defaults are not the identity
    public let alwaysApplies: Bool
    public init(_ id: String, _ en: String, _ de: String, kind: OpKind = .global, always: Bool = false, _ params: [ParamSpec], tip: String = "") {
        self.id = id; self.en = en; self.de = de; self.kind = kind; self.params = params; self.tooltipEN = tip; self.alwaysApplies = always
    }
    public func param(_ key: String) -> ParamSpec? { params.first { $0.key == key } }
    public var defaults: [String: Double] { Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.def) }) }
}

public enum Catalog {
    public static let raw = "rawDecode", wb = "whiteBalance", exposure = "exposure"
    public static let enhance = "enhance", shadowHighlight = "shadowHighlight"
    public static let levels = "levels", curves = "curves", color = "color"
    public static let mono = "monochromeMixer", sepia = "sepiaTone", colorMono = "colorMonochrome"
    public static let noise = "noiseReduction", sharpen = "proSharpen", edgeSharpen = "proEdgeSharpen"
    public static let vignette = "vignette", devignette = "devignette", chromatic = "chromaticAberration"
    public static let crop = "crop", straighten = "straightenCrop"
    public static let flip = "flip"
    public static let retouch = "retouch", redEye = "redEye", spotPatch = "spotPatch"

    static func band(_ id: String, _ en: String, _ de: String, base: Double) -> [ParamSpec] {
        [ParamSpec("input\(id)HueShift", "\(en) Hue", "\(de) Farbton", min: -100, max: 100, approx: true),
         ParamSpec("input\(id)Saturation", "\(en) Saturation", "\(de) Sättigung", min: -100, max: 100, approx: true),
         ParamSpec("input\(id)Luminance", "\(en) Luminance", "\(de) Luminanz", min: -100, max: 100, approx: true)]
    }

    /// Order = brick order in the Adjustments inspector (matches the 3.0 screenshot order, extended).
    public static let ops: [OpSpec] = [
        OpSpec(raw, "RAW Fine Tuning", "RAW-Feinabstimmung", [
            ParamSpec("inputBoostAmount", "Boost", "Verstärkt", def: 1, min: 0, max: 1),
            ParamSpec("inputBoostPreserveHueAmount", "Hue Boost", "Farbton verstärken", def: 0, min: 0, max: 1),
            ParamSpec("inputSharpenIntensity", "Sharpening", "Scharfzeichnen", def: 0.65, min: 0, max: 1),
            ParamSpec("inputSharpenEdgeIntensity", "Edges", "Kanten", def: 0.714, min: 0, max: 1),
            ParamSpec("inputChromaBlurRadius", "Chroma Blur Radius", "Radius für Chroma weichzeichnen", def: 4, min: 0, max: 10, approx: true),
            ParamSpec("inputChromaBlurMoireAmount", "Moire Amount", "Moire-Stärke", def: 0, min: 0, max: 1),
            ParamSpec("inputChromaBlurMoireSize", "Moire Radius", "Moire-Radius", def: 4, min: 0, max: 25),
            ParamSpec("inputNoiseReductionAmount", "Noise Reduction", "Störungen reduzieren", def: 0, min: 0, max: 1),
            ParamSpec("inputMethodVersion", "Decoder", "Decoder", def: 1, min: 1, max: 2),
        ]),
        OpSpec(wb, "White Balance", "Weißabgleich", [
            ParamSpec("inputTemperature", "Temp", "Temp.", def: 5000, min: 2000, max: 14000, unit: .kelvin, approx: true),
            ParamSpec("inputTint", "Tint", "Tönung", def: 0, min: -150, max: 150, approx: true),
            ParamSpec("inputIsDefaults", "As Shot", "Wie aufgenommen", def: 1, min: 0, max: 1),
        ]),
        OpSpec(exposure, "Exposure", "Belichtung", [
            ParamSpec("inputEV", "Exposure", "Belichtung", min: -9.99, max: 9.99, slider: -2...2, unit: .ev),
            ParamSpec("inputRecoveryEV", "Recovery", "Wiederherstellung", min: 0, max: 1.5),
            ParamSpec("inputBias", "Black Point", "Schwarzpunkt", min: -5, max: 50),
            ParamSpec("inputBrightness", "Brightness", "Helligkeit", min: -2, max: 2, slider: -0.5...0.5),
        ]),
        OpSpec(enhance, "Enhance", "Optimieren", [
            ParamSpec("inputContrast", "Contrast", "Kontrast", min: -1, max: 1, slider: -0.5...0.5),
            ParamSpec("inputDefinition", "Definition", "Definition", min: 0, max: 1),
            ParamSpec("inputSaturation", "Saturation", "Sättigung", def: 1, min: 0, max: 4, slider: 0...2),
            ParamSpec("inputVibrancy", "Vibrancy", "Lebendigkeit", min: -1, max: 1),
            ParamSpec("inputBlackUOffset", "Black Tint U", "Schwarzton U", min: -1, max: 1, approx: true), ParamSpec("inputBlackVOffset", "Black Tint V", "Schwarzton V", min: -1, max: 1, approx: true),
            ParamSpec("inputGrayUOffset", "Gray Tint U", "Grauton U", min: -1, max: 1, approx: true), ParamSpec("inputGrayVOffset", "Gray Tint V", "Grauton V", min: -1, max: 1, approx: true),
            ParamSpec("inputWhiteUOffset", "White Tint U", "Weißton U", min: -1, max: 1, approx: true), ParamSpec("inputWhiteVOffset", "White Tint V", "Weißton V", min: -1, max: 1, approx: true),
        ]),
        OpSpec(shadowHighlight, "Highlights & Shadows", "Lichter & Schatten", [
            ParamSpec("inputShadowAmount", "Shadows", "Schatten", min: 0, max: 100),
            ParamSpec("inputHighlightAmount", "Highlights", "Glanzlichter", min: 0, max: 100),
            ParamSpec("inputRadius", "Radius", "Radius", def: 200, min: 1, max: 1000),
            ParamSpec("inputColorCorrection", "Color Correction", "Farbkorrektur", min: -100, max: 100),
            ParamSpec("inputMidtoneContrast", "Mid Contrast", "Kontrast (Mitten)", min: -100, max: 100),
            ParamSpec("inputShadowTonalWidth", "Low Tonal Width", "Untere Tonwerte", def: 40, min: 0, max: 100),
            ParamSpec("inputHighlightTonalWidth", "High Tonal Width", "Obere Tonwerte", def: 40, min: 0, max: 100),
        ]),
        OpSpec(levels, "Levels", "Tonwerte", levelsParams()),
        OpSpec(color, "Color", "Farbe", [("Reds", "Reds", "Rot"), ("Yellows", "Yellows", "Gelb"), ("Greens", "Greens", "Grün"),
                                          ("Cyans", "Cyans", "Cyan"), ("Blues", "Blues", "Blau"), ("Magentas", "Magentas", "Magenta")]
                .flatMap { band($0.0, $0.1, $0.2, base: 0) }),
        OpSpec(curves, "Curves", "Gradationskurven", [ParamSpec("gamma", "Gamma", "Gamma", def: 0.4545, min: 0.1, max: 3)]),
        OpSpec(mono, "Black & White", "Schwarzweiß", always: true, [
            ParamSpec("inputRValue", "Red", "Rot", def: 29.9, min: -100, max: 200, slider: -100...100),
            ParamSpec("inputGValue", "Green", "Grün", def: 58.7, min: -100, max: 200, slider: -100...100),
            ParamSpec("inputBValue", "Blue", "Blau", def: 11.4, min: -100, max: 200, slider: -100...100),
        ]),
        OpSpec(sepia, "Sepia Tone", "Sepia", always: true, [ParamSpec("inputIntensity", "Intensity", "Intensität", def: 1, min: 0, max: 1)]),
        OpSpec(colorMono, "Color Monochrome", "Einfarbig", always: true, [
            ParamSpec("inputIntensity", "Intensity", "Intensität", def: 1, min: 0, max: 1),
            ParamSpec("inputRed", "Red", "Rot", def: 0.6, min: 0, max: 1), ParamSpec("inputGreen", "Green", "Grün", def: 0.45, min: 0, max: 1),
            ParamSpec("inputBlue", "Blue", "Blau", def: 0.3, min: 0, max: 1)]),
        OpSpec(noise, "Noise Reduction", "Störungen reduzieren", [
            ParamSpec("inputRadius", "Radius", "Radius", def: 1, min: 0, max: 4, slider: 0...2),
            ParamSpec("inputEdgeDetail", "Edge Detail", "Kanten-Detail", def: 1.5, min: 0, max: 6, slider: 0...3)]),
        OpSpec(sharpen, "Sharpen", "Scharfzeichnen", [
            ParamSpec("inputIntensity", "Intensity", "Intensität", def: 0.5, min: 0, max: 2, slider: 0...1),
            ParamSpec("inputRadius", "Radius", "Radius", def: 1, min: 0, max: 200, slider: 0...20, unit: .pixels)]),
        OpSpec(edgeSharpen, "Edge Sharpen", "Kanten scharfzeichnen", [
            ParamSpec("inputSharpness", "Intensity", "Intensität", def: 0.81, min: 0, max: 1),
            ParamSpec("inputEdgeScale", "Edges", "Kanten", def: 0.22, min: 0, max: 1),
            ParamSpec("inputFalloff", "Falloff", "Nachlassen", def: 0.69, min: 0, max: 1)]),
        OpSpec(vignette, "Vignette", "Vignette", always: true, [
            ParamSpec("inputIntensity", "Intensity", "Intensität", def: 0.6, min: 0, max: 20, slider: 0...1, approx: true),
            ParamSpec("inputRadius", "Radius", "Radius", def: 0.5, min: 0, max: 2)]),
        OpSpec(devignette, "Devignette", "Vignettierung entfernen", always: true, [
            ParamSpec("inputIntensity", "Intensity", "Intensität", def: 1, min: 0, max: 1),
            ParamSpec("inputRadius", "Radius", "Radius", def: 0, min: 0, max: 2)]),
        OpSpec(chromatic, "Chromatic Aberration", "Chromatische Aberration", [
            ParamSpec("inputRedCyan", "Red/Cyan", "Rot/Zyan", min: -5, max: 5, slider: -3...3),
            ParamSpec("inputBlueYellow", "Blue/Yellow", "Blau/Gelb", min: -5, max: 5, slider: -3...3)]),
        OpSpec(crop, "Crop", "Zuschneiden", [
            ParamSpec("inputXOrigin", "X", "X", min: 0, max: 100000, unit: .pixels), ParamSpec("inputYOrigin", "Y", "Y", min: 0, max: 100000, unit: .pixels),
            ParamSpec("inputWidth", "Width", "Breite", min: 1, max: 100000, unit: .pixels), ParamSpec("inputHeight", "Height", "Höhe", min: 1, max: 100000, unit: .pixels)]),
        OpSpec(straighten, "Straighten", "Begradigen", [ParamSpec("inputRotation", "Straighten", "Begradigen", min: -20, max: 20, unit: .degrees)]),
        OpSpec(flip, "Flip", "Spiegeln", [ParamSpec("inputFlipType", "Flip", "Spiegeln", min: 0, max: 3)]),
        OpSpec(redEye, "Red Eye", "Rote Augen", kind: .stroke, []),
        OpSpec(spotPatch, "Spot & Patch", "Fleck", kind: .stroke, []),
        OpSpec(retouch, "Retouch", "Retuschieren", kind: .stroke, []),
    ]

    static func levelsParams() -> [ParamSpec] {
        var p: [ParamSpec] = []
        let points: [(String, Double)] = [("Black", 0), ("Shadow", 0.25), ("Mid", 0.5), ("Hilight", 0.75), ("White", 1)]
        for ch in ["RGB", "Red", "Green", "Blue"] {
            for (n, v) in points {
                p.append(ParamSpec("input\(n)Src\(ch)", "\(n) in \(ch)", "\(n) \(ch)", def: v, min: 0, max: 1))
                p.append(ParamSpec("input\(n)Dst\(ch)", "\(n) out \(ch)", "\(n) \(ch) Ziel", def: v, min: 0, max: 1))
            }
        }
        return p
    }

    /// The 14 Quick Brushes, plus Retouch handled as `retouch`.
    public static let brushes: [OpSpec] = [
        OpSpec("skinSmoothing", "Skin Smoothing", "Hautglättung", kind: .brush, [
            ParamSpec("inputRadius", "Radius", "Radius", def: 10, min: 0, max: 100, slider: 0...20),
            ParamSpec("inputEdgeDetail", "Detail", "Details", def: 0.75, min: 0, max: 1),
            ParamSpec("inputIntensity", "Intensity", "Intensität", def: 0.5, min: 0, max: 1)]),
        OpSpec("dodge", "Dodge (Lighten)", "Nachbelichten (Aufhellen)", kind: .brush, [ParamSpec("inputExposure", "Amount", "Stärke", def: 0.4, min: 0, max: 1)]),
        OpSpec("burn", "Burn (Darken)", "Abwedeln (Abdunkeln)", kind: .brush, [ParamSpec("inputExposure", "Amount", "Stärke", def: 0.4, min: 0, max: 1)]),
        OpSpec("multiply", "Polarize (Multiply)", "Polarisieren (Multiplizieren)", kind: .brush, [ParamSpec("inputIntensity", "Intensity", "Intensität", def: 0.75, min: 0, max: 1)]),
        OpSpec("overlayBlend", "Intensify Contrast (Overlay)", "Kontrast verstärken (Überlagerung)", kind: .brush, [ParamSpec("inputIntensity", "Intensity", "Intensität", def: 0.75, min: 0, max: 1)]),
        OpSpec("tint", "Tint", "Farbton", kind: .brush, [ParamSpec("inputAngle", "Angle", "Winkel", def: 45, min: -180, max: 180, unit: .degrees)]),
        OpSpec("contrast", "Contrast", "Kontrast", kind: .brush, [ParamSpec("inputContrast", "Amount", "Stärke", def: 0.25, min: -1, max: 1, slider: -0.5...0.5)]),
        OpSpec("saturation", "Saturation", "Sättigung", kind: .brush, [ParamSpec("inputSaturation", "Amount", "Stärke", def: 1.5, min: 0, max: 2)]),
        OpSpec("definition", "Definition", "Definition", kind: .brush, [
            ParamSpec("inputRadius", "Radius", "Radius", def: 30, min: 1, max: 100),
            ParamSpec("inputIntensity", "Intensity", "Intensität", def: 0.75, min: 0, max: 2, slider: 0...1)]),
        OpSpec("vibrancy", "Vibrancy", "Lebendigkeit", kind: .brush, [ParamSpec("inputAmount", "Amount", "Stärke", def: 0.75, min: -1, max: 1)]),
        OpSpec("blur", "Blur", "Weichzeichnen", kind: .brush, [ParamSpec("inputIntensity", "Amount", "Stärke", def: 5, min: 0, max: 100, slider: 0...50)]),
        OpSpec("sharpen", "Sharpen", "Scharfzeichnen", kind: .brush, [ParamSpec("inputSharpness", "Amount", "Stärke", def: 1, min: 0, max: 2)]),
        OpSpec("defringe", "Halo Reduction", "Halo-Reduzierung", kind: .brush, [ParamSpec("inputIntensity", "Amount", "Stärke", def: 0.5, min: 0, max: 1, approx: true)]),
        OpSpec("noise", "Noise Reduction", "Störungen reduzieren", kind: .brush, [
            ParamSpec("inputRadius", "Radius", "Radius", def: 1, min: 0, max: 4, slider: 0...2),
            ParamSpec("inputEdgeDetail", "Edge Detail", "Kanten-Detail", def: 1.5, min: 0, max: 6, slider: 0...3)]),
    ]

    public static func spec(_ id: String) -> OpSpec? { ops.first { $0.id == id } ?? brushes.first { $0.id == id } }
    public static func brushSpec(_ id: String) -> OpSpec? { brushes.first { $0.id == id } }
    /// Identifiers of the legacy library format (RK…/DG… class-style names) map to ours; unknown names pass through.
    public static func canonicalID(_ name: String) -> String {
        if name == "DGSharpenOperation" { return sharpen }
        for prefix in ["DGGNG", "RK", "DG"] where name.hasPrefix(prefix) && name.hasSuffix("Operation") {
            let core = name.dropFirst(prefix.count).dropLast("Operation".count)
            guard let f = core.first else { return name }
            return f.lowercased() + core.dropFirst()
        }
        return name
    }
}

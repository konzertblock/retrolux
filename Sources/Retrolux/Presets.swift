import RetroluxCore

/// Adjustment presets. Factory preset names and folders;
/// the parameter values are own approximations.
struct AdjPreset: Identifiable {
    let folder: String, name: String
    let make: () -> AdjustmentSet
    var id: String { folder + "/" + name }
}

enum Presets {
    static func a(_ id: String, _ p: [String: Double] = [:], curves: [String: [CurvePoint]] = [:]) -> Adjustment {
        var params = Catalog.spec(id)?.defaults ?? [:]; for (k, v) in p { params[k] = v }
        return Adjustment(id: id, params: params, curves: curves)
    }
    static func set(_ items: Adjustment...) -> AdjustmentSet { var s = AdjustmentSet(); for i in items { s.upsert(i) }; return s }
    static func sCurve(_ k: Double) -> [CurvePoint] { [CurvePoint(x: 0, y: 0, editable: false), CurvePoint(x: 0.25, y: 0.25 - k), CurvePoint(x: 0.75, y: 0.75 + k), CurvePoint(x: 1, y: 1, editable: false)] }
    static func mixer(_ r: Double, _ g: Double, _ b: Double) -> Adjustment { a(Catalog.mono, ["inputRValue": r, "inputGValue": g, "inputBValue": b]) }
    static func wb(_ t: Double, _ tint: Double = 0) -> AdjustmentSet { set(a(Catalog.wb, ["inputTemperature": t, "inputTint": tint, "inputIsDefaults": 0])) }

    static let all: [AdjPreset] = [
        AdjPreset(folder: "Quick Fixes", name: "Auto Enhance") { set(a(Catalog.enhance, ["inputContrast": 0.12, "inputSaturation": 1.12, "inputVibrancy": 0.2]), a(Catalog.levels, ["inputBlackSrcRGB": 0.02, "inputWhiteSrcRGB": 0.98]), a(Catalog.sharpen, ["inputIntensity": 0.4])) },
        AdjPreset(folder: "Quick Fixes", name: "Exposure (+1)") { set(a(Catalog.exposure, ["inputEV": 1])) },
        AdjPreset(folder: "Quick Fixes", name: "Exposure (+2)") { set(a(Catalog.exposure, ["inputEV": 2])) },
        AdjPreset(folder: "Quick Fixes", name: "Exposure (-1)") { set(a(Catalog.exposure, ["inputEV": -1])) },
        AdjPreset(folder: "Quick Fixes", name: "Exposure (-2)") { set(a(Catalog.exposure, ["inputEV": -2])) },
        AdjPreset(folder: "Quick Fixes", name: "Hold Highlights") { set(a(Catalog.exposure, ["inputRecoveryEV": 1.0]), a(Catalog.shadowHighlight, ["inputHighlightAmount": 25])) },
        AdjPreset(folder: "Quick Fixes", name: "Brighten Shadows") { set(a(Catalog.enhance, ["inputContrast": 0.05]), a(Catalog.shadowHighlight, ["inputShadowAmount": 45])) },
        AdjPreset(folder: "Color", name: "Cross Process 1") { set(a(Catalog.curves, curves: ["redCurvePoints": sCurve(0.12), "blueCurvePoints": [CurvePoint(x: 0, y: 0.12, editable: false), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 0.88, editable: false)], "greenCurvePoints": sCurve(0.04)]), a(Catalog.enhance, ["inputSaturation": 1.25])) },
        AdjPreset(folder: "Color", name: "Cross Process 2") { set(a(Catalog.curves, curves: ["blueCurvePoints": sCurve(0.14), "redCurvePoints": [CurvePoint(x: 0, y: 0.1, editable: false), CurvePoint(x: 0.5, y: 0.52), CurvePoint(x: 1, y: 0.92, editable: false)]]), a(Catalog.enhance, ["inputSaturation": 1.2, "inputContrast": 0.1])) },
        AdjPreset(folder: "Color", name: "Vintage") { set(a(Catalog.enhance, ["inputSaturation": 0.7, "inputContrast": -0.05]), a(Catalog.curves, curves: ["RGBCurvePoints": [CurvePoint(x: 0, y: 0.08, editable: false), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 0.94, editable: false)]]), a(Catalog.vignette, ["inputIntensity": 0.5, "inputRadius": 0.7])) },
        AdjPreset(folder: "Color", name: "Toy Camera") { set(a(Catalog.enhance, ["inputSaturation": 1.4, "inputContrast": 0.2]), a(Catalog.vignette, ["inputIntensity": 0.9, "inputRadius": 0.45])) },
        AdjPreset(folder: "Color", name: "Punch") { set(a(Catalog.enhance, ["inputContrast": 0.25, "inputSaturation": 1.3, "inputDefinition": 0.5])) },
        AdjPreset(folder: "Color", name: "Intensify") { set(a(Catalog.enhance, ["inputSaturation": 1.3, "inputVibrancy": 0.4, "inputContrast": 0.15])) },
        AdjPreset(folder: "Color", name: "Sepia Tone (Low Contrast)") { set(a(Catalog.enhance, ["inputContrast": -0.1]), a(Catalog.sepia, ["inputIntensity": 1])) },
        AdjPreset(folder: "Color", name: "Sepia Tone (High Contrast)") { set(a(Catalog.enhance, ["inputContrast": 0.3]), a(Catalog.sepia, ["inputIntensity": 1])) },
        AdjPreset(folder: "Color", name: "Cyanotype") { set(a(Catalog.enhance, ["inputContrast": 0.25]), a(Catalog.mono), a(Catalog.colorMono, ["inputRed": 0.1, "inputGreen": 0.35, "inputBlue": 0.65, "inputIntensity": 1])) },
        AdjPreset(folder: "White Balance", name: "Daylight") { wb(5500) },
        AdjPreset(folder: "White Balance", name: "Cloudy") { wb(6500, 5) },
        AdjPreset(folder: "White Balance", name: "Shade") { wb(7500, 8) },
        AdjPreset(folder: "White Balance", name: "Tungsten") { wb(3200) },
        AdjPreset(folder: "White Balance", name: "Fluorescent") { wb(4000, 20) },
        AdjPreset(folder: "White Balance", name: "Flash") { wb(5500, 3) },
        AdjPreset(folder: "Black & White", name: "Red Filter") { set(mixer(100, 0, 0)) },
        AdjPreset(folder: "Black & White", name: "Orange Filter") { set(mixer(70, 30, 0)) },
        AdjPreset(folder: "Black & White", name: "Yellow Filter") { set(mixer(50, 50, 0)) },
        AdjPreset(folder: "Black & White", name: "Green Filter") { set(mixer(0, 100, 0)) },
        AdjPreset(folder: "Black & White", name: "Blue Filter") { set(mixer(0, 0, 100)) },
        AdjPreset(folder: "Black & White", name: "Low Contrast (Grade 0)") { set(a(Catalog.exposure, ["inputBrightness": 0.1]), mixer(29.9, 58.7, 11.4), a(Catalog.enhance, ["inputContrast": -0.2])) },
        AdjPreset(folder: "Black & White", name: "Higher Contrast (Grade 2)") { set(mixer(29.9, 58.7, 11.4), a(Catalog.enhance, ["inputContrast": 0.2])) },
        AdjPreset(folder: "Black & White", name: "High Contrast (Grade 5)") { set(mixer(29.9, 58.7, 11.4), a(Catalog.enhance, ["inputContrast": 0.6])) },
        AdjPreset(folder: "Black & White", name: "Infrared") { set(mixer(-30, 130, -10), a(Catalog.enhance, ["inputContrast": 0.2]), a(Catalog.vignette, ["inputIntensity": 0.4, "inputRadius": 0.8])) },
    ]
    static var folders: [String] { var s: [String] = []; for p in all where !s.contains(p.folder) { s.append(p.folder) }; return s }
}

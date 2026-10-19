import SwiftUI
import AppKit
import RetroluxCore

struct HistogramView: View {
    var bins: [[Float]]
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.hex(0x2E2E2E)))
            guard bins.count == 4 else { return }
            let cols: [Color] = [Color.red, Color.green, Color.blue]
            for (i, c) in cols.enumerated() {
                var p = Path(); p.move(to: CGPoint(x: 0, y: size.height))
                for x in 0..<256 { p.addLine(to: CGPoint(x: size.width * CGFloat(x) / 255, y: size.height - size.height * CGFloat(bins[i][x]))) }
                p.addLine(to: CGPoint(x: size.width, y: size.height)); p.closeSubpath()
                ctx.blendMode = .plusLighter; ctx.fill(p, with: .color(c.opacity(0.55)))
            }
            ctx.blendMode = .normal
            var l = Path(); l.move(to: CGPoint(x: 0, y: size.height))
            for x in 0..<256 { l.addLine(to: CGPoint(x: size.width * CGFloat(x) / 255, y: size.height - size.height * CGFloat(bins[3][x]))) }
            ctx.stroke(l, with: .color(.white.opacity(0.7)), lineWidth: 0.7)
        }
    }
}

/// Aqua-style popup pill ("Presets ▾"), dark variant inside the HUD.
struct PopupPill: View {
    let text: String; var width: CGFloat = 96; @Environment(\.hudDark) var dark
    var body: some View {
        HStack(spacing: 2) { Text(text).font(Theme.font(11, bold: true)); Spacer(minLength: 0); Image(systemName: "chevron.up.chevron.down").font(.system(size: 7)) }
            .foregroundColor(dark ? .white : .black).padding(.horizontal, 7).frame(width: width, height: 18)
            .background(LinearGradient(colors: dark ? [Theme.hex(0x4C4C4C), Theme.hex(0x2A2A2A)] : [.white, Theme.hex(0xD2D2D2)], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(dark ? 0.8 : 0.45), lineWidth: 0.7))
    }
}

struct AdjustmentsTab: View {
    @ObservedObject var model: AppModel
    @Environment(\.hudDark) var dark
    @State private var added: Set<String> = []
    @State private var exifLine = ""
    static let defaultBricks = [Catalog.raw, Catalog.wb, Catalog.exposure, Catalog.enhance, Catalog.shadowHighlight, Catalog.levels, Catalog.color, Catalog.curves]
    var visible: [OpSpec] {
        Catalog.ops.filter { $0.kind == .global && (Self.defaultBricks.contains($0.id) || added.contains($0.id) || (model.adjustments.item($0.id) != nil)) }
    }
    var body: some View {
        VStack(spacing: 0) {
            if model.primaryVersion == nil { Text(model.L("No Image Selected", "Kein Bild ausgewählt")).font(Theme.body).foregroundColor(.gray).padding(20); Spacer() }
            else {
                VStack(spacing: 3) {
                    HistogramView(bins: model.histogram).frame(height: 80).overlay(Rectangle().stroke(Color.black.opacity(0.5), lineWidth: 0.5))
                    if !exifLine.isEmpty { Text(exifLine).font(Theme.font(10)).foregroundColor(dark ? .white : Color(white: 0.2)).frame(maxWidth: .infinity).padding(.vertical, 2).background(dark ? Color.black.opacity(0.45) : Color.black.opacity(0.1)).cornerRadius(3) }
                }.padding(8)
                HStack(spacing: 6) {
                    Menu {
                        ForEach(Presets.folders, id: \.self) { f in Menu(f) { ForEach(Presets.all.filter { $0.folder == f }) { p in Button(p.name) { model.applyPreset(p) } } } }
                        if !model.userPresets.isEmpty { Menu(model.L("My Presets", "Meine Voreinstellungen")) { ForEach(model.userPresets) { p in
                            Button(p.name) { model.apply(user: p, replace: false) }
                            Button(model.L("Replace with ", "Ersetzen durch ") + p.name) { model.apply(user: p, replace: true) }.modifierKeyAlternate(.option) } } }
                        Divider()
                        Button(model.L("Save Current as Preset…", "Aktuelle als Voreinstellung sichern …")) { model.showSavePreset = true }
                        Button(model.L("Import Presets…", "Voreinstellungen importieren …")) { model.importUserPresets() }
                        if !model.userPresets.isEmpty { Menu(model.L("Manage My Presets", "Meine Voreinstellungen verwalten")) { ForEach(model.userPresets) { p in
                            Button(model.L("Export ", "Exportieren ") + p.name) { model.exportUserPreset(p.id) }
                            Button(model.L("Delete ", "Löschen ") + p.name) { model.deleteUserPreset(p.id) } } } }
                    } label: { PopupPill(text: model.L("Presets", "Voreinstellungen"), width: 112) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    Menu {
                        ForEach(Catalog.ops.filter { $0.kind == .global }, id: \.id) { o in Button(model.lang == "de" ? o.de : o.en) { added.insert(o.id); model.expanded.insert(o.id) } }
                    } label: { PopupPill(text: model.L("Adjustments", "Anpassungen"), width: 100) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    Spacer()
                    Menu { Button(model.L("Reset All Adjustments", "Alle Anpassungen zurücksetzen")) { model.resetAllAdjustments() }
                        Button(model.L("Lift Adjustments", "Anpassungen aufnehmen")) { model.lift(meta: false, adj: true) }; Button(model.L("Stamp", "Stempeln")) { model.stamp() } } label: { Image(systemName: "gearshape.fill").foregroundColor(dark ? .white : Color(white: 0.3)) }.menuStyle(.borderlessButton).frame(width: 30)
                }.padding(.horizontal, 8).padding(.bottom, 6)
                Etched()
                ScrollView {
                    VStack(spacing: 0) { ForEach(visible, id: \.id) { op in Brick(model: model, op: op) } }
                }.background(dark ? Color(white: 0.13) : Color.clear)
            }
        }
        .onAppear { added = [] }
        .onChange(of: model.primary) { _ in added = [] }
        .task(id: model.primary) {
            guard let v = model.primaryVersion, let m = model.primaryMaster else { exifLine = ""; return }
            let url = model.store.masterURL(m)
            let ex = await Task.detached(priority: .utility) { ExifReader.values(for: url, master: m, isMissing: false, version: v) }.value
            exifLine = [ex["exif.iso"].map { "ISO " + $0 }, ex["exif.aperture"], ex["exif.shutter"], ex["exif.focal"]].compactMap { $0 }.joined(separator: "   ")
        }
    }
}

struct Brick: View {
    @ObservedObject var model: AppModel
    @Environment(\.hudDark) var dark
    let op: OpSpec
    var expanded: Bool { model.expanded.contains(op.id) }
    var title: String { model.lang == "de" ? op.de : op.en }
    var body: some View {
        let on = model.isOn(op.id), has = model.adjustments.item(op.id) != nil
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Button { if expanded { model.expanded.remove(op.id) } else { model.expanded.insert(op.id) } } label: { Image(systemName: expanded ? "triangle.fill" : "triangle.fill").rotationEffect(.degrees(expanded ? 180 : 90)).font(.system(size: 6)).frame(width: 12) }.buttonStyle(.plain)
                Button { model.setEnabled(op.id, !on) } label: { Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 12)).foregroundColor(on ? Theme.hex(0x3A6EBB) : Theme.hex(0x666666)) }.buttonStyle(.plain).accessibilityLabel(title + " " + model.L("enabled", "aktiv")).accessibilityValue(on ? "1" : "0")
                Text(title).font(Theme.font(11, bold: true)).foregroundColor(dark ? (on ? .white : Color(white: 0.6)) : (on ? .black : Theme.hex(0x555555)))
                Spacer()
                Button { model.resetOp(op.id) } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 9)) }.buttonStyle(.plain).disabled(!has).opacity(has ? 1 : 0.3)
                Menu { Button(model.L("Reset", "Zurücksetzen")) { model.resetOp(op.id) }; Button(model.L("Disable", "Deaktivieren")) { model.setEnabled(op.id, false) } } label: { Image(systemName: "gearshape").font(.system(size: 9)) }.menuStyle(.borderlessButton).frame(width: 22)
            }
            .padding(.horizontal, 6).frame(height: 22)
            .background(LinearGradient(colors: dark ? [Theme.hex(0x303030), Theme.hex(0x222222)] : [Theme.hex(0xE0E0E0), Theme.hex(0xC4C4C4)], startPoint: .top, endPoint: .bottom))
            .foregroundColor(dark ? .white : .black)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(dark ? 0.6 : 0.3)).frame(height: 1) }
            if expanded {
                VStack(spacing: 3) { content }.padding(.horizontal, 8).padding(.vertical, 6).opacity(on ? 1 : 0.6)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.15)).frame(height: 1) }
            }
        }
    }

    @ViewBuilder var content: some View {
        switch op.id {
        case Catalog.levels: LevelsView(model: model)
        case Catalog.curves: CurvesView(model: model)
        case Catalog.color: ColorBandsView(model: model)
        case Catalog.crop: CropControls(model: model)
        case Catalog.flip: FlipControls(model: model)
        case Catalog.raw: RawBody(model: model, op: op)
        case Catalog.enhance: EnhanceBody(model: model, op: op)
        case Catalog.exposure: ExposureBody(model: model, op: op)
        default:
            ForEach(op.params.filter { !$0.key.hasPrefix("inputIs") }, id: \.key) { p in SliderRow(model: model, opID: op.id, p: p) }
        }
    }
}

struct SliderRow: View {
    @ObservedObject var model: AppModel
    let opID: String
    let p: ParamSpec
    @State private var text = ""
    @Environment(\.hudDark) var dark
    var value: Double { model.value(opID, p.key) }
    func fmt(_ v: Double) -> String {
        switch p.unit {
        case .kelvin: return String(format: "%.0f K", v)
        case .pixels: return String(format: "%.1f", v)
        case .degrees: return String(format: "%.2f°", v)
        default: return abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.2f", v)
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Text((model.lang == "de" ? p.de : p.en) + ":").font(Theme.tiny).foregroundColor(dark ? Color(white: 0.85) : Color(white: 0.2)).frame(width: 74, alignment: .trailing).lineLimit(1)
            AquaSlider(value: Binding(get: { value }, set: { model.setParam(opID, p.key, $0) }), range: p.sliderMin...p.sliderMax, def: p.def, label: model.lang == "de" ? p.de : p.en) { start in
                if start { model.beginEdit() } else { model.endEdit(model.L("Adjust", "Anpassen")) }
            }
            ValuePill(text: $text, dark: dark, commit: { if let d = Double(text.replacingOccurrences(of: ",", with: ".").filter { "-0123456789.".contains($0) }) { model.beginEdit(); model.setParam(opID, p.key, d); model.endEdit(model.L("Adjust", "Anpassen")) } }, step: { dir in model.beginEdit(); model.setParam(opID, p.key, min(p.max, max(p.min, value + dir * max((p.sliderMax - p.sliderMin) / 100, 0.01)))); model.endEdit(model.L("Adjust", "Anpassen")) })
                .frame(width: 66)
                .onAppear { text = fmt(value) }.onChange(of: value) { text = fmt($0) }
        }
        .help(p.approx ? model.L("Range approximated", "Bereich geschätzt") : "")
    }
}

struct LevelsView: View {
    @ObservedObject var model: AppModel
    @State private var channel = "RGB"
    func key(_ n: String, _ io: String) -> String { "input\(n)\(io)\(channel)" }
    func v(_ n: String) -> Double { model.value(Catalog.levels, key(n, "Src")) }
    func set(_ n: String, _ x: Double) { model.setParam(Catalog.levels, key(n, "Src"), x) }
    func rebalance() {
        let b = v("Black"), m = v("Mid"), w = v("White")
        set("Shadow", b + (m - b) / 2); set("Hilight", m + (w - m) / 2)
    }
    var body: some View {
        VStack(spacing: 4) {
            HStack { Picker("", selection: $channel) { Text("RGB").tag("RGB"); Text("Red").tag("Red"); Text("Green").tag("Green"); Text("Blue").tag("Blue") }.labelsHidden().controlSize(.small).frame(width: 90)
                Spacer(); Button("Auto") { autoLevels() }.buttonStyle(AquaButtonStyle()) }
            ZStack(alignment: .bottom) {
                HistogramView(bins: model.histogram).frame(height: 70)
                GeometryReader { g in
                    ForEach([("Black", Color.black), ("Mid", Color.gray), ("White", Color.white)], id: \.0) { h in
                        Triangle().fill(h.1).overlay(Triangle().stroke(Color.black, lineWidth: 0.7)).frame(width: 12, height: 10)
                            .position(x: CGFloat(v(h.0)) * g.size.width, y: g.size.height - 5)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                                if model.editSnapshot0 == nil { model.beginEdit() }
                                var x = min(1, max(0, Double(d.location.x / g.size.width)))
                                if h.0 == "Black" { x = min(x, v("White") - 0.02) } else if h.0 == "White" { x = max(x, v("Black") + 0.02) } else { x = min(v("White") - 0.01, max(v("Black") + 0.01, x)) }
                                set(h.0, x); rebalance()
                            }.onEnded { _ in model.endEdit(model.L("Levels", "Tonwerte")) })
                    }
                }.frame(height: 70)
            }
            HStack { Text("B: " + String(format: "%.2f", v("Black"))).font(Theme.tiny); Spacer(); Text("G: " + String(format: "%.2f", v("Mid"))).font(Theme.tiny); Spacer(); Text("W: " + String(format: "%.2f", v("White"))).font(Theme.tiny) }
        }
    }
    func autoLevels() {
        guard model.histogram.count == 4 else { return }
        let h = model.histogram[3]; let tot = h.reduce(0, +); guard tot > 0 else { return }
        var acc: Float = 0, lo = 0, hi = 255
        for i in 0..<256 { acc += h[i]; if acc / tot > 0.005 { lo = i; break } }
        acc = 0; for i in stride(from: 255, through: 0, by: -1) { acc += h[i]; if acc / tot > 0.005 { hi = i; break } }
        model.beginEdit(); set("Black", Double(lo) / 255); set("White", Double(max(hi, lo + 5)) / 255); set("Mid", (Double(lo) + Double(max(hi, lo + 5))) / 510); rebalance(); model.endEdit("Auto Levels")
    }
}
struct Triangle: Shape { func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath(); return p } }

struct CurvesView: View {
    @ObservedObject var model: AppModel
    @State private var channel = "RGBCurvePoints"
    var pts: [CurvePoint] { model.adj(Catalog.curves).curves[channel] ?? [CurvePoint(x: 0, y: 0, editable: false), CurvePoint(x: 1, y: 1, editable: false)] }
    var body: some View {
        VStack(spacing: 4) {
            Picker("", selection: $channel) { Text("RGB").tag("RGBCurvePoints"); Text("Red").tag("redCurvePoints"); Text("Green").tag("greenCurvePoints"); Text("Blue").tag("blueCurvePoints") }.labelsHidden().controlSize(.small).frame(width: 90).frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { g in
                let s = min(g.size.width, g.size.height)
                ZStack {
                    Canvas { ctx, size in
                        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.hex(0x2E2E2E)))
                        for i in 1..<4 { var l = Path(); l.move(to: CGPoint(x: size.width * CGFloat(i) / 4, y: 0)); l.addLine(to: CGPoint(x: size.width * CGFloat(i) / 4, y: size.height)); l.move(to: CGPoint(x: 0, y: size.height * CGFloat(i) / 4)); l.addLine(to: CGPoint(x: size.width, y: size.height * CGFloat(i) / 4)); ctx.stroke(l, with: .color(.white.opacity(0.15)), lineWidth: 0.5) }
                        let f = ColorLUT.curveFunc(pts.contains { $0.editable } ? pts : nil)
                        var c = Path()
                        for x in 0...100 { let t = Double(x) / 100; let y = f?(t) ?? t; let pt = CGPoint(x: size.width * t, y: size.height * (1 - min(1, max(0, y)))); if x == 0 { c.move(to: pt) } else { c.addLine(to: pt) } }
                        ctx.stroke(c, with: .color(.white), lineWidth: 1.2)
                        for p in pts where p.editable && p.x <= 1 { ctx.fill(Path(ellipseIn: CGRect(x: size.width * p.x - 4, y: size.height * (1 - p.y) - 4, width: 8, height: 8)), with: .color(.yellow)) }
                    }
                }
                .frame(width: s, height: s)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { d in
                        let x = min(1, max(0, Double(d.location.x / s))), y = min(1, max(0, 1 - Double(d.location.y / s)))
                        if model.editSnapshot0 == nil { model.beginEdit() }
                        var p = pts.contains { $0.editable } ? pts : [CurvePoint(x: 0, y: 0, editable: false), CurvePoint(x: 1, y: 1, editable: false)]
                        if let i = p.indices.filter({ p[$0].editable }).min(by: { abs(p[$0].x - x) < abs(p[$1].x - x) }), abs(p[i].x - x) < 0.06, hypot(p[i].x - x, p[i].y - y) < 0.12 { p[i].x = x; p[i].y = y }
                        else if d.translation == .zero { p.append(CurvePoint(x: x, y: y)) }
                        p.sort { $0.x < $1.x }
                        model.setCurve(Catalog.curves, channel, p)
                    }
                    .onEnded { _ in model.endEdit(model.L("Curves", "Gradationskurven")) })
                .simultaneousGesture(TapGesture(count: 2).onEnded { model.beginEdit(); model.setCurve(Catalog.curves, channel, [CurvePoint(x: 0, y: 0, editable: false), CurvePoint(x: 1, y: 1, editable: false)]); model.endEdit("Curves") })
            }.frame(height: 150)
            Text(model.L("Click to add a point, drag to move, double-click to reset", "Klicken: Punkt hinzufügen, Ziehen: bewegen, Doppelklick: zurücksetzen")).font(Theme.font(9)).foregroundColor(.gray)
        }
    }
}

struct ColorBandsView: View {
    @ObservedObject var model: AppModel
    @State private var band = "Reds"
    static let bands = ["Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas"]
    var body: some View {
        VStack(spacing: 3) {
            Picker("", selection: $band) { ForEach(Self.bands, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).labelsHidden().controlSize(.mini)
            ForEach(["HueShift", "Saturation", "Luminance"], id: \.self) { k in
                if let p = Catalog.spec(Catalog.color)?.param("input\(band)\(k)") { SliderRow(model: model, opID: Catalog.color, p: p).id(p.key) }
            }
        }
    }
}

struct CropControls: View {
    @ObservedObject var model: AppModel
    var body: some View { Button(model.L("Crop Tool", "Zuschneiden-Werkzeug")) { model.tool = .crop }.buttonStyle(AquaButtonStyle()) }
}

struct FlipControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack {
            ForEach([(1, "arrow.left.and.right.righttriangle.left.righttriangle.right", model.L("Horizontal", "Horizontal")), (2, "arrow.up.and.down.righttriangle.up.righttriangle.down", model.L("Vertical", "Vertikal"))], id: \.0) { f in
                Button { var t = Int(model.value(Catalog.flip, "inputFlipType")); t ^= f.0; model.beginEdit(); model.setParam(Catalog.flip, "inputFlipType", Double(t)); model.endEdit(model.L("Flip", "Spiegeln")) } label: { Label(f.2, systemImage: f.1).font(Theme.tiny) }.buttonStyle(AquaButtonStyle())
            }
        }
    }
}

struct ExposureBody: View {
    @ObservedObject var model: AppModel
    let op: OpSpec
    var body: some View {
        VStack(spacing: 3) {
            HStack { Spacer(); Button("Auto") { model.autoExposure() }.buttonStyle(AquaButtonStyle()) }
            ForEach(op.params, id: \.key) { p in SliderRow(model: model, opID: op.id, p: p) }
        }
    }
}

struct TintPad: View {
    @ObservedObject var model: AppModel
    let title: String
    let uKey: String, vKey: String
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)).opacity(0.5)
                RoundedRectangle(cornerRadius: 3).fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: 40))
                GeometryReader { g in
                    let u = model.value(Catalog.enhance, uKey), v = model.value(Catalog.enhance, vKey)
                    Circle().stroke(Color.black, lineWidth: 1.5).background(Circle().fill(Color.white.opacity(0.6))).frame(width: 9, height: 9)
                        .position(x: g.size.width * (0.5 + u / 2), y: g.size.height * (0.5 - v / 2))
                }
            }
            .frame(width: 70, height: 70).overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.4)))
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                if model.editSnapshot0 == nil { model.beginEdit() }
                let u = min(1, max(-1, Double(d.location.x / 70) * 2 - 1)), v = min(1, max(-1, 1 - Double(d.location.y / 70) * 2))
                model.setParam(Catalog.enhance, uKey, u); model.setParam(Catalog.enhance, vKey, v)
            }.onEnded { _ in model.endEdit(model.L("Tint", "Tönung")) })
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.beginEdit(); model.setParam(Catalog.enhance, uKey, 0); model.setParam(Catalog.enhance, vKey, 0); model.endEdit("Tint") })
            Text(title).font(Theme.font(9))
        }
    }
}

struct EnhanceBody: View {
    @ObservedObject var model: AppModel
    let op: OpSpec
    @State private var tint = false
    var body: some View {
        VStack(spacing: 3) {
            ForEach(op.params.filter { !$0.key.contains("Offset") }, id: \.key) { p in SliderRow(model: model, opID: op.id, p: p) }
            DisclosureGroup(model.L("Tint", "Tönung"), isExpanded: $tint) {
                HStack(spacing: 10) {
                    TintPad(model: model, title: model.L("Shadows", "Tiefen"), uKey: "inputBlackUOffset", vKey: "inputBlackVOffset")
                    TintPad(model: model, title: model.L("Midtones", "Mitten"), uKey: "inputGrayUOffset", vKey: "inputGrayVOffset")
                    TintPad(model: model, title: model.L("Highlights", "Lichter"), uKey: "inputWhiteUOffset", vKey: "inputWhiteVOffset")
                }.padding(.top, 4)
            }.font(Theme.tiny)
        }
    }
}

extension View {
    /// `Menu` alternates are not exposed by SwiftUI; hide the replace entry unless ⌥ is down at open time.
    @ViewBuilder func modifierKeyAlternate(_ m: NSEvent.ModifierFlags) -> some View { if NSEvent.modifierFlags.contains(m) { self } else { EmptyView() } }
}

struct RawBody: View {
    @ObservedObject var model: AppModel
    let op: OpSpec
    var body: some View {
        VStack(spacing: 3) {
            HStack { Text(model.L("Decoder", "Decoder")).font(Theme.tiny).frame(width: 74, alignment: .trailing)
                Picker("", selection: Binding(get: { model.value(Catalog.raw, "inputMethodVersion") < 1.5 ? 1 : 2 }, set: { model.beginEdit(); model.setParam(Catalog.raw, "inputMethodVersion", Double($0)); model.endEdit(model.L("RAW Decoder", "RAW-Decoder")) })) { Text(model.L("Current", "Aktuell")).tag(2); Text(model.L("Previous", "Vorherige")).tag(1) }.labelsHidden().controlSize(.small) }
            ForEach(op.params.filter { $0.key != "inputMethodVersion" }, id: \.key) { p in SliderRow(model: model, opID: op.id, p: p) }
        }
    }
}

/// Capsule value field with ‹ › step arrows, as usual sliders.
struct ValuePill: View {
    @Binding var text: String
    var dark: Bool
    var commit: () -> Void
    var step: (Double) -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button { step(-1) } label: { Image(systemName: "arrowtriangle.left.fill").font(.system(size: 6)).frame(width: 10, height: 16) }.buttonStyle(.plain)
            TextField("", text: $text, onCommit: commit).textFieldStyle(.plain).multilineTextAlignment(.center).font(Theme.tiny).foregroundColor(dark ? .white : .black)
            Button { step(1) } label: { Image(systemName: "arrowtriangle.right.fill").font(.system(size: 6)).frame(width: 10, height: 16) }.buttonStyle(.plain)
        }.foregroundColor(dark ? Color(white: 0.7) : Color(white: 0.4))
        .background(LinearGradient(colors: dark ? [Theme.hex(0x555555), Theme.hex(0x3A3A3A)] : [.white, Theme.hex(0xE2E2E2)], startPoint: .top, endPoint: .bottom))
        .clipShape(Capsule()).overlay(Capsule().stroke(Color.black.opacity(dark ? 0.8 : 0.4), lineWidth: 0.7)).frame(height: 16)
    }
}

import SwiftUI
import RetroluxCore

/// Image Export presets editor (Retrolux ▸ Presets ▸ Image Export…). Fields:
/// Image Format, Include Metadata, Image Quality, Size To (+ Width/Height/DPI), Color Profile.
struct ExportPresetEditor: View {
    @ObservedObject var model: AppModel
    @State private var custom = ExportPreset.custom
    @State private var selected = ExportPreset.factory[6].name
    private static let formats: [(String, ExportPreset.Format, Bool)] = [("JPEG", .jpeg, false), ("PNG", .png, false), ("TIFF", .tiff, false), ("TIFF (16-bit)", .tiff, true), ("PSD", .psd, false), ("PSD (16-bit)", .psd, true)]
    private static let sizes = ["Original Size", "Fit Within (Pixels)", "Fit Within (Inches)", "Fit Within (Centimeters)", "Percent of Original"]

    var isCustom: Bool { custom.contains { $0.name == selected } }
    var current: ExportPreset { (custom + ExportPreset.factory).first { $0.name == selected } ?? ExportPreset.factory[6] }
    func update(_ f: (inout ExportPreset) -> Void) {
        guard let i = custom.firstIndex(where: { $0.name == selected }) else { return }
        f(&custom[i]); ExportPreset.custom = custom
    }
    var sizeIndex: Int {
        switch current.size { case .original: return 0; case .fit: return 1; case .percent: return 4
        case .box(_, _, let u): return u == .inches ? 2 : (u == .centimeters ? 3 : 1) }
    }
    func setSizeIndex(_ i: Int) {
        update { p in
            let (w, h) = boxValues(p.size)
            switch i { case 0: p.size = .original; case 1: p.size = .box(width: w == 0 ? 1024 : w, height: h == 0 ? 1024 : h, unit: .pixels)
            case 2: p.size = .box(width: w == 0 ? 8 : w, height: h == 0 ? 8 : h, unit: .inches); case 3: p.size = .box(width: w == 0 ? 20 : w, height: h == 0 ? 20 : h, unit: .centimeters)
            default: p.size = .percent(50) }
        }
    }
    func boxValues(_ s: ExportPreset.Size) -> (Double, Double) {
        switch s { case .box(let w, let h, _): return (w, h); case .fit(let f): return (Double(f), Double(f)); default: return (0, 0) }
    }
    func newPreset() {
        var p = current; p.isCustom = true
        var n = p.name + " copy"; var k = 2; while (custom + ExportPreset.factory).contains(where: { $0.name == n }) { n = p.name + " copy \(k)"; k += 1 }
        p.name = n; custom.append(p); ExportPreset.custom = custom; selected = n
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.L("Image Export Presets", "Bild-Export-Voreinstellungen")).font(Theme.title)
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    List(selection: Binding(get: { selected as String? }, set: { if let s = $0 { selected = s } })) {
                        Section(model.L("Presets", "Voreinstellungen")) {
                            ForEach(ExportPreset.factory) { Text($0.name).font(Theme.tiny).foregroundColor(.gray).tag($0.name) }
                            ForEach(custom) { Text($0.name).font(Theme.tiny).tag($0.name) }
                        }
                    }.frame(width: 250, height: 330)
                    HStack(spacing: 4) {
                        Button("+") { newPreset() }.buttonStyle(AquaButtonStyle()).help(model.L("Duplicate the selected preset", "Gewählte Voreinstellung duplizieren"))
                        Button("−") { if let i = custom.firstIndex(where: { $0.name == selected }) { custom.remove(at: i); ExportPreset.custom = custom; selected = ExportPreset.factory[6].name } }.buttonStyle(AquaButtonStyle()).disabled(!isCustom)
                        Spacer()
                    }.padding(.top, 4)
                }
                editor.disabled(!isCustom).opacity(isCustom ? 1 : 0.6)
            }
            if !isCustom { Text(model.L("Factory presets cannot be changed. Use + to make an editable copy.", "Werkseinstellungen sind nicht änderbar. Mit + eine bearbeitbare Kopie anlegen.")).font(Theme.tiny).foregroundColor(.gray) }
            HStack { Spacer(); Button("OK") { model.showExportPresetEditor = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).background(Theme.chrome)
    }

    var editor: some View {
        let p = current
        let (w, h) = boxValues(p.size)
        func lbl(_ s: String, _ d: String) -> some View { Text(model.L(s, d)).font(Theme.small).frame(width: 110, alignment: .trailing) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack { lbl("Name:", "Name:"); TextField("", text: Binding(get: { p.name }, set: { n in
                guard !n.isEmpty, !(custom + ExportPreset.factory).contains(where: { $0.name == n && $0.name != p.name }) else { return }
                update { $0.name = n }; selected = n })).textFieldStyle(.roundedBorder).frame(width: 200) }
            HStack { lbl("Image Format:", "Bildformat:"); Picker("", selection: Binding(get: { Self.formats.firstIndex { $0.1 == p.format && $0.2 == p.deep } ?? 0 }, set: { i in update { $0.format = Self.formats[i].1; $0.deep = Self.formats[i].2 } })) {
                ForEach(Self.formats.indices, id: \.self) { Text(Self.formats[$0].0).tag($0) } }.labelsHidden().frame(width: 160) }
            HStack { Spacer().frame(width: 118); Toggle(model.L("Include Metadata", "Metadaten einschließen"), isOn: Binding(get: { p.includeMetadata }, set: { v in update { $0.includeMetadata = v } })).toggleStyle(.checkbox).font(Theme.small) }
            HStack { lbl("Image Quality:", "Bildqualität:"); Slider(value: Binding(get: { p.quality }, set: { v in update { $0.quality = v } }), in: 0...1).frame(width: 150).disabled(p.format != .jpeg)
                Text(String(format: "%.0f", p.quality * 10)).font(Theme.tiny).frame(width: 24) }
            Divider()
            HStack { lbl("Size To:", "Größe:"); Picker("", selection: Binding(get: { sizeIndex }, set: { setSizeIndex($0) })) { ForEach(Self.sizes.indices, id: \.self) { Text(Self.sizes[$0]).tag($0) } }.labelsHidden().frame(width: 200) }
            if sizeIndex == 4, case .percent(let pc) = p.size {
                HStack { lbl("Percent:", "Prozent:"); Stepper(value: Binding(get: { pc }, set: { v in update { $0.size = .percent(max(1, v)) } }), in: 1...400) { Text("\(pc) %").font(Theme.small) } }
            } else if sizeIndex >= 1, case .box(_, _, let u) = p.size {
                HStack { lbl("Width:", "Breite:"); TextField("", value: Binding(get: { w }, set: { v in update { $0.size = .box(width: v, height: h, unit: u) } }), format: .number).textFieldStyle(.roundedBorder).frame(width: 64)
                    Text(model.L("Height:", "Höhe:")).font(Theme.small); TextField("", value: Binding(get: { h }, set: { v in update { $0.size = .box(width: w, height: v, unit: u) } }), format: .number).textFieldStyle(.roundedBorder).frame(width: 64) }
            } else if case .fit(let f) = p.size {
                HStack { lbl("Fit Within:", "Einpassen in:"); Text("\(f) × \(f) px").font(Theme.small) }
            }
            HStack { lbl("DPI:", "DPI:"); TextField("", value: Binding(get: { p.dpi }, set: { v in update { $0.dpi = max(1, v) } }), format: .number).textFieldStyle(.roundedBorder).frame(width: 64) }
            Spacer()
        }.frame(width: 360, alignment: .leading)
    }
}

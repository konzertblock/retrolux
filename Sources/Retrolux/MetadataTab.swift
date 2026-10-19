import SwiftUI
import AVFoundation
import MapKit
import AppKit
import RetroluxCore

struct MetadataTab: View {
    @ObservedObject var model: AppModel
    @State private var values: [String: String] = [:]
    @State private var kw = ""
    var body: some View {
        ScrollView {
            if let v = model.primaryVersion, let m = model.primaryMaster {
                VStack(alignment: .leading, spacing: 8) {
                    CameraHeader(model: model, m: m, values: values)
                    HStack {
                        ForEach(1...5, id: \.self) { i in Button { model.setRating(v.rating == i ? 0 : i) } label: { Text(i <= v.rating ? "★" : "☆").font(.system(size: 15)).foregroundColor(i <= v.rating ? Theme.hex(0xE0A400) : .gray) }.buttonStyle(.plain) }
                        Button { model.setRating(v.rating < 0 ? 0 : -1) } label: { Image(systemName: "xmark.circle\(v.rating < 0 ? ".fill" : "")").foregroundColor(.red) }.buttonStyle(.plain).help(model.L("Reject", "Ablehnen"))
                        Spacer()
                        Button { model.toggleFlag() } label: { Image(systemName: v.flagged ? "flag.fill" : "flag").foregroundColor(v.flagged ? .orange : .gray) }.buttonStyle(.plain)
                    }
                    HStack(spacing: 4) { Text(model.L("Label", "Etikett")).font(Theme.tiny); ForEach(1...7, id: \.self) { i in
                        Button { model.setLabel(i) } label: { Circle().fill(Theme.labelColors[i]).frame(width: 12, height: 12).overlay(Circle().stroke(Color.black.opacity(v.colorLabel == i ? 0.9 : 0.3), lineWidth: v.colorLabel == i ? 2 : 0.5)) }.buttonStyle(.plain).help(model.labelName(i)) } }
                    HStack(spacing: 4) {
                        Picker("", selection: $model.metaViewName) { ForEach(model.metaConfig.views) { Text($0.name).tag($0.name) } }.labelsHidden().controlSize(.small)
                        Menu {
                            Button(model.L("Batch Change…", "Stapeländerung …")) { model.showBatchChange = true }
                            Button(model.L("Adjust Date and Time…", "Datum und Uhrzeit anpassen …")) { model.showAdjustDate = true }
                            Menu(model.L("Apply Metadata Preset", "Metadaten-Voreinstellung anwenden")) { ForEach(model.metaConfig.presets) { p in Button(p.name) { model.applyMetadataPreset(p) } }; if model.metaConfig.presets.isEmpty { Text("—") } }
                            Divider()
                            Button(model.L("Keywords & Keyword Sets…", "Schlagwörter und Schlagwortsets …")) { model.showKeywordManager = true }
                            Button(model.L("Customize Metadata Views…", "Metadatenansichten anpassen …")) { model.showMetaViewEditor = true }
                            Button(model.L("Metadata Presets…", "Metadaten-Voreinstellungen …")) { model.showMetaPresetEditor = true }
                            Button(model.L("Edit AutoFill List…", "AutoFill-Liste bearbeiten …")) { model.showAutofillEditor = true }
                            Divider()
                            Button(model.L("Update from Master", "Vom Original aktualisieren")) { model.updateFromMaster() }
                            Button(model.L("Write IPTC to Master…", "IPTC ins Original schreiben …")) { model.writeIPTCToMaster() }
                        } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).frame(width: 30)
                    }
                    Etched()
                    ForEach(model.currentMetaView.fields, id: \.self) { id in
                        if let f = MetadataField.field(id) { FieldRow(model: model, f: f, v: v, value: displayValue(f, v)) }
                    }
                    if model.currentMetaView.fields.isEmpty { Text(model.L("This view has no fields.", "Diese Ansicht hat keine Felder.")).font(Theme.tiny).foregroundColor(.gray) }
                    AudioAttachmentRow(model: model, v: v)
                    if let la = v.latitude, let lo = v.longitude {
                        Etched()
                        Text(model.L("Location: ", "Ort: ") + ([v.meta["place.name"], v.meta["place.city"], v.meta["place.state"], v.meta["place.country"]].compactMap { $0 }.joined(separator: ", ").isEmpty ? String(format: "%.4f, %.4f", la, lo) : [v.meta["place.name"], v.meta["place.city"], v.meta["place.state"], v.meta["place.country"]].compactMap { $0 }.joined(separator: ", "))).font(Theme.small)
                        MiniMap(lat: la, lon: lo).frame(height: 150).overlay(Rectangle().stroke(Color.black.opacity(0.4)))
                    }
                    if v.originalImageDate != nil { HStack { Text(model.L("Date adjusted (original: ", "Datum angepasst (Original: ") + (v.originalImageDate?.formatted(date: .abbreviated, time: .shortened) ?? "") + ")").font(Theme.tiny).foregroundColor(.orange); Button(model.L("Restore", "Zurücksetzen")) { model.restoreOriginalDates() }.buttonStyle(AquaButtonStyle()) } }
                }.padding(10)
                .onAppear { reload(m, v) }.onChange(of: model.primary) { _ in if let v2 = model.primaryVersion, let m2 = model.primaryMaster { reload(m2, v2) } }
            } else { Text(model.L("No Image Selected", "Kein Bild ausgewählt")).font(Theme.body).foregroundColor(.gray).padding(20) }
        }
    }
    func reload(_ m: Master, _ v: Version) { values = ExifReader.values(for: model.store.masterURL(m), master: m, isMissing: model.store.isMissing(m), version: v) }
    func displayValue(_ f: MetadataField, _ v: Version) -> String {
        switch f.id {
        case "name": return v.name; case "caption": return v.caption; case "rating": return v.rating < 0 ? "Rejected" : String(repeating: "★", count: v.rating)
        case "label": return model.labelName(v.colorLabel); case "flag": return v.flagged ? "⚑" : "—"; case "date": return v.imageDate.formatted(date: .abbreviated, time: .standard)
        case "version": return "\(v.versionNumber)"; case "keywords": return v.keywords.joined(separator: ", ")
        case "people": let n = model.store.peopleNames(of: v.id); return n.isEmpty ? "—" : n.joined(separator: ", ")
        default: return f.editable ? (v.meta[f.id] ?? "") : (values[f.id] ?? "—")
        }
    }
}

struct FieldRow: View {
    @ObservedObject var model: AppModel
    let f: MetadataField
    let v: Version
    let value: String
    @State private var text = ""
    @State private var kw = ""
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(model.lang == "de" ? f.de : f.en).font(Theme.tiny).foregroundColor(.gray).frame(width: 78, alignment: .trailing).padding(.top, 3)
            Group {
                if f.id == "keywords" {
                    VStack(alignment: .leading, spacing: 4) {
                        FlowTags(tags: v.keywords) { model.removeKeyword($0) }
                        HStack { TextField(model.L("Add keyword", "Schlagwort hinzufügen"), text: $kw, onCommit: { model.addKeyword(kw); kw = "" }).textFieldStyle(.roundedBorder).font(Theme.small)
                            Button { model.showKeywordManager = true } label: { Image(systemName: "list.bullet.indent") }.buttonStyle(.plain).help(model.L("Keyword Manager", "Schlagwort-Manager")) }
                    }
                } else if f.editable {
                    HStack(spacing: 2) {
                        TextField("", text: $text, onCommit: { model.setMetaField(f.id, text) }).textFieldStyle(.roundedBorder).font(Theme.small)
                        let fill = model.metaConfig.autofill(f.id)
                        if !fill.isEmpty { Menu { ForEach(fill, id: \.self) { s in Button(s) { text = s; model.setMetaField(f.id, s) } } } label: { Image(systemName: "chevron.down.circle").font(.system(size: 10)) }.menuStyle(.borderlessButton).frame(width: 22) }
                    }
                } else { Text(value).font(Theme.small).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
        .onAppear { text = value }.onChange(of: value) { text = $0 }
    }
}

struct AudioAttachmentRow: View {
    @ObservedObject var model: AppModel
    let v: Version
    @State private var player: AVAudioPlayer?
    var body: some View {
        if m?.kind == .image {
            HStack(spacing: 6) {
                Text(model.L("Audio", "Audio")).font(Theme.tiny).foregroundColor(.gray).frame(width: 78, alignment: .trailing)
                if let url = model.store.attachmentURL(v) {
                    Button { if player?.isPlaying == true { player?.stop() } else { player = try? AVAudioPlayer(contentsOf: url); player?.play() } } label: { Image(systemName: "speaker.wave.2.fill") }.buttonStyle(.plain)
                    Text(url.lastPathComponent).font(Theme.small).lineLimit(1)
                    Button { try? model.store.removeAudio(from: v.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                } else { Button(model.L("Attach Audio…", "Audio anhängen …")) { model.attachAudioFile() }.buttonStyle(AquaButtonStyle()) }
            }
        }
    }
    var m: Master? { model.store.masters[v.masterID] }
}

/// Camera card at the top of the Metadata inspector (camera, lens, format badge, ISO · focal length · bias · aperture · shutter).
struct CameraHeader: View {
    @ObservedObject var model: AppModel
    let m: Master
    let values: [String: String]
    var body: some View {
        if values["exif.camera"] != nil || values["exif.iso"] != nil {
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(values["exif.camera"] ?? "—").font(Theme.font(13, bold: true)); Spacer()
                    Text(m.isRaw ? "RAW" : (m.kind == .video ? "VIDEO" : "JPEG")).font(Theme.font(9, bold: true)).foregroundColor(.white).padding(.horizontal, 5).padding(.vertical, 1).background(Color.gray).cornerRadius(3) }
                Text(values["exif.lens"] ?? "").font(Theme.small).foregroundColor(.gray).lineLimit(1)
                HStack(spacing: 0) {
                    ForEach([("ISO", values["exif.iso"]), ("", values["exif.focal"]), ("", values["exif.bias"]?.replacingOccurrences(of: " EV", with: "ev")), ("", values["exif.aperture"]), ("", values["exif.shutter"]?.replacingOccurrences(of: " s", with: ""))], id: \.0) { c in
                        Text(((c.0.isEmpty ? "" : c.0 + " ") + (c.1 ?? "–"))).font(Theme.font(11)).frame(maxWidth: .infinity).padding(.vertical, 3).overlay(Rectangle().stroke(Color.black.opacity(0.15), lineWidth: 0.5)) } }
                    .background(Color.white.opacity(0.5))
            }.padding(8).background(LinearGradient(colors: [Theme.hex(0xEFEFEF), Theme.hex(0xD6D6D6)], startPoint: .top, endPoint: .bottom)).cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.3), lineWidth: 0.5))
        }
    }
}

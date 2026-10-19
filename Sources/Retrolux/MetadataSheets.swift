import SwiftUI
import AppKit
import RetroluxCore

struct SheetFrame<C: View>: View {
    let title: String
    var width: CGFloat = 520
    var done: () -> Void
    @ViewBuilder var content: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.font(14, bold: true))
            content()
            HStack { Spacer(); Button("OK", action: done).buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: width).background(Theme.chrome)
    }
}

struct BatchChangeSheet: View {
    @ObservedObject var model: AppModel
    @State private var useName = false
    @State private var nameTemplate = "{name} {nn}"
    @State private var start = 1
    @State private var mode = BatchMode.replace
    @State private var fields: [String: String] = [:]
    @State private var enabled: Set<String> = []
    @State private var shiftDays = 0
    @State private var shiftHours = 0
    @State private var shiftMinutes = 0
    @State private var keywords = ""
    var preview: String {
        guard let v = model.primaryVersion else { return "" }
        return nameTemplate.replacingOccurrences(of: "{n}", with: "\(start)").replacingOccurrences(of: "{nn}", with: String(format: "%02d", start)).replacingOccurrences(of: "{name}", with: v.name).replacingOccurrences(of: "{date}", with: v.imageDate.formatted(.iso8601.year().month().day()))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.L("Batch Change – \(model.selection.count) photos", "Stapeländerung – \(model.selection.count) Fotos")).font(Theme.font(14, bold: true))
            Picker(model.L("Existing text", "Vorhandener Text"), selection: $mode) { Text(model.L("Replace", "Ersetzen")).tag(BatchMode.replace); Text(model.L("Append", "Anhängen")).tag(BatchMode.append); Text(model.L("Only if empty", "Nur wenn leer")).tag(BatchMode.setIfEmpty) }.pickerStyle(.segmented)
            Toggle(model.L("Version name", "Versionsname"), isOn: $useName).toggleStyle(.checkbox)
            if useName { HStack { TextField("{name} {nn}", text: $nameTemplate).textFieldStyle(.roundedBorder); Stepper("\(model.L("start", "Start")) \(start)", value: $start, in: 0...99999).font(Theme.tiny) }
                Text("{name} {n} {nn} {date}  →  " + preview).font(Theme.tiny).foregroundColor(.gray) }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach([MetadataField.field("caption")!] + MetadataField.editableIPTC, id: \.id) { f in
                        HStack { Toggle("", isOn: Binding(get: { enabled.contains(f.id) }, set: { if $0 { enabled.insert(f.id) } else { enabled.remove(f.id) } })).toggleStyle(.checkbox).labelsHidden()
                            Text(model.lang == "de" ? f.de : f.en).font(Theme.tiny).frame(width: 110, alignment: .trailing)
                            TextField("", text: Binding(get: { fields[f.id] ?? "" }, set: { fields[f.id] = $0; if !$0.isEmpty { enabled.insert(f.id) } })).textFieldStyle(.roundedBorder).font(Theme.small) }
                    }
                }
            }.frame(height: 180)
            HStack { Text(model.L("Add keywords", "Schlagwörter hinzufügen")).font(Theme.tiny); TextField("a, b/c", text: $keywords).textFieldStyle(.roundedBorder) }
            HStack { Text(model.L("Shift date by", "Datum verschieben um")).font(Theme.tiny)
                Stepper("\(shiftDays) d", value: $shiftDays, in: -3650...3650).font(Theme.tiny); Stepper("\(shiftHours) h", value: $shiftHours, in: -48...48).font(Theme.tiny); Stepper("\(shiftMinutes) min", value: $shiftMinutes, in: -600...600).font(Theme.tiny) }
            HStack { Spacer(); Button(model.L("Cancel", "Abbrechen")) { model.showBatchChange = false }.buttonStyle(AquaButtonStyle())
                Button(model.L("Apply", "Anwenden")) {
                    var ch = BatchChange(); ch.mode = mode; ch.counterStart = start
                    if useName { ch.nameTemplate = nameTemplate }
                    for k in enabled { if let t = fields[k], !t.isEmpty { ch.fields[k] = t } }
                    ch.keywordsToAdd = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    ch.dateShiftSeconds = Double(shiftDays) * 86400 + Double(shiftHours) * 3600 + Double(shiftMinutes) * 60
                    model.runBatchChange(ch); for (k, t) in ch.fields { model.metaConfig.rememberAutofill(k, t) }; model.showBatchChange = false
                }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 560).background(Theme.chrome)
    }
}

struct AdjustDateSheet: View {
    @ObservedObject var model: AppModel
    @State private var date = Date()
    @State private var tzHours = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.L("Adjust Date and Time", "Datum und Uhrzeit anpassen")).font(Theme.font(14, bold: true))
            if let v = model.primaryVersion {
                Text(model.L("Original: ", "Original: ") + (v.originalImageDate ?? v.imageDate).formatted(date: .abbreviated, time: .standard)).font(Theme.tiny).foregroundColor(.gray)
                DatePicker(model.L("New date of the primary photo", "Neues Datum des primären Fotos"), selection: $date).datePickerStyle(.field)
                Stepper(model.L("Time zone shift: \(tzHours) h", "Zeitzonenverschiebung: \(tzHours) Std."), value: $tzHours, in: -14...14)
                Text(model.L("All selected photos are shifted by the same amount (their order and spacing stay the same). Originals keep their capture time; you can restore it.", "Alle gewählten Fotos werden um denselben Betrag verschoben (Reihenfolge und Abstände bleiben). Die Aufnahmezeit der Originale bleibt erhalten und lässt sich wiederherstellen.")).font(Theme.tiny).foregroundColor(.gray)
            }
            HStack { Button(model.L("Restore Original", "Original wiederherstellen")) { model.restoreOriginalDates(); model.showAdjustDate = false }.buttonStyle(AquaButtonStyle()); Spacer()
                Button(model.L("Cancel", "Abbrechen")) { model.showAdjustDate = false }.buttonStyle(AquaButtonStyle())
                Button(model.L("Adjust", "Anpassen")) {
                    if let v = model.primaryVersion { var ch = BatchChange(); ch.dateShiftSeconds = date.timeIntervalSince(v.imageDate) + Double(tzHours) * 3600; model.runBatchChange(ch) }
                    model.showAdjustDate = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 440).background(Theme.chrome)
        .onAppear { date = model.primaryVersion?.imageDate ?? Date() }
    }
}

struct KeywordNode: Identifiable { let id: String; let name: String; var children: [KeywordNode]? }

struct KeywordManagerSheet: View {
    @ObservedObject var model: AppModel
    @State private var selected: String?
    @State private var newName = ""
    @State private var renameTo = ""
    @State private var setIndex = 0
    @State private var slotText: [String] = Array(repeating: "", count: 9)
    var tree: [KeywordNode] {
        var root: [String: Any] = [:]
        func insert(_ parts: ArraySlice<String>, into d: inout [String: Any]) { guard let f = parts.first else { return }; var sub = (d[f] as? [String: Any]) ?? [:]; insert(parts.dropFirst(), into: &sub); d[f] = sub }
        for k in model.store.allKeywords { insert(k.split(separator: "/").map(String.init)[...], into: &root) }
        func build(_ d: [String: Any], prefix: String) -> [KeywordNode] {
            d.keys.sorted().map { k in let p = prefix.isEmpty ? k : prefix + "/" + k; let ch = build(d[k] as! [String: Any], prefix: p); return KeywordNode(id: p, name: k, children: ch.isEmpty ? nil : ch) }
        }
        return build(root, prefix: "")
    }
    func count(_ path: String) -> Int { model.store.versions.values.filter { !$0.trashed && $0.keywords.contains { $0 == path || $0.hasPrefix(path + "/") } }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.L("Keywords", "Schlagwörter")).font(Theme.font(14, bold: true))
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading) {
                    List(tree, children: \.children, selection: $selected) { n in HStack { Text(n.name).font(Theme.small); Spacer(); Text("\(count(n.id))").font(Theme.tiny).foregroundColor(.gray) } }.frame(width: 250, height: 250)
                    HStack { TextField(model.L("New keyword", "Neues Schlagwort"), text: $newName).textFieldStyle(.roundedBorder)
                        Button("+") { guard !newName.isEmpty else { return }; model.newKeyword(newName, parent: selected); newName = "" }.buttonStyle(AquaButtonStyle()).help(model.L("Adds the keyword to the selected photos (under the selected keyword)", "Fügt das Schlagwort den gewählten Fotos hinzu (unter dem gewählten Schlagwort)")) }
                    HStack { TextField(model.L("Rename to", "Umbenennen in"), text: $renameTo).textFieldStyle(.roundedBorder)
                        Button(model.L("Rename", "Umbenennen")) { if let s = selected, !renameTo.isEmpty { let parent = s.split(separator: "/").dropLast().joined(separator: "/"); try? model.store.renameKeyword(s, to: parent.isEmpty ? renameTo : parent + "/" + renameTo); selected = nil; renameTo = "" } }.buttonStyle(AquaButtonStyle()) }
                    HStack { Button(model.L("Assign", "Zuweisen")) { if let s = selected { model.addKeyword(s) } }.buttonStyle(AquaButtonStyle()).disabled(selected == nil || model.selection.isEmpty)
                        Button(model.L("Remove from Selection", "Von Auswahl entfernen")) { if let s = selected { model.removeKeyword(s) } }.buttonStyle(AquaButtonStyle()).disabled(selected == nil)
                        Button(model.L("Delete Everywhere", "Überall löschen")) { if let s = selected { try? model.store.deleteKeyword(s); selected = nil } }.buttonStyle(AquaButtonStyle()).disabled(selected == nil) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.L("Keyword Sets (⌥1 – ⌥9)", "Schlagwortsets (⌥1 – ⌥9)")).font(Theme.font(11, bold: true))
                    HStack { Picker("", selection: $setIndex) { ForEach(Array(model.metaConfig.keywordSets.enumerated()), id: \.offset) { Text($1.name).tag($0) } }.labelsHidden().frame(width: 150)
                        Button("+") { var s = model.metaConfig.keywordSets; s.append(KeywordSet(name: model.L("Set ", "Set ") + "\(s.count + 1)", keywords: [])); model.metaConfig.keywordSets = s; setIndex = s.count - 1; load() }.buttonStyle(AquaButtonStyle())
                        Button("−") { var s = model.metaConfig.keywordSets; if s.count > 1 { s.remove(at: setIndex); model.metaConfig.keywordSets = s; setIndex = 0; load() } }.buttonStyle(AquaButtonStyle()) }
                    ForEach(0..<9, id: \.self) { i in HStack { Text("⌥\(i + 1)").font(Theme.tiny).frame(width: 26)
                        TextField("", text: $slotText[i], onCommit: save).textFieldStyle(.roundedBorder).font(Theme.small)
                        Button { if let s = selected { slotText[i] = s; save() } } label: { Image(systemName: "arrow.left") }.buttonStyle(.plain).help(model.L("Use selected keyword", "Gewähltes Schlagwort verwenden")) } }
                }.frame(width: 250)
            }
            HStack { Spacer(); Button("OK") { save(); model.showKeywordManager = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 560).background(Theme.chrome)
        .onAppear { setIndex = model.metaConfig.activeKeywordSet; load() }.onChange(of: setIndex) { _ in load(); model.metaConfig.activeKeywordSet = setIndex }
    }
    func load() { let k = model.metaConfig.keywordSets[min(setIndex, model.metaConfig.keywordSets.count - 1)].keywords; slotText = (0..<9).map { $0 < k.count ? k[$0] : "" } }
    func save() { var s = model.metaConfig.keywordSets; guard setIndex < s.count else { return }; s[setIndex].keywords = slotText; model.metaConfig.keywordSets = s; model.configChanged() }
}

struct MetaViewEditorSheet: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var fields: Set<String> = []
    var body: some View {
        SheetFrame(title: model.L("Customize Metadata Views", "Metadatenansichten anpassen"), width: 560, done: { model.showMetaViewEditor = false }) {
            HStack(alignment: .top, spacing: 12) {
                List(model.metaConfig.views, id: \.name) { v in HStack { Text(v.name).font(Theme.small); Spacer(); if !v.factory { Image(systemName: "person").font(.system(size: 9)) } }.contentShape(Rectangle())
                    .onTapGesture { name = v.factory ? v.name + " 2" : v.name; fields = Set(v.fields) } }.frame(width: 180, height: 300)
                VStack(alignment: .leading) {
                    TextField(model.L("View name", "Name der Ansicht"), text: $name).textFieldStyle(.roundedBorder)
                    ScrollView { VStack(alignment: .leading, spacing: 2) { ForEach(MetadataField.all) { f in Toggle(model.lang == "de" ? f.de : f.en, isOn: Binding(get: { fields.contains(f.id) }, set: { if $0 { fields.insert(f.id) } else { fields.remove(f.id) } })).toggleStyle(.checkbox).font(Theme.tiny) } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 240)
                    HStack { Button(model.L("Save View", "Ansicht sichern")) { guard !name.isEmpty else { return }; let order = MetadataField.all.map(\.id).filter { fields.contains($0) }; model.metaConfig.addView(MetadataView(name: name, fields: order)); model.metaViewName = name; model.configChanged() }.buttonStyle(AquaButtonStyle())
                        Button(model.L("Delete", "Löschen")) { model.metaConfig.removeView(name); if model.metaViewName == name { model.metaViewName = "Photo Info" }; model.configChanged() }.buttonStyle(AquaButtonStyle()) }
                }
            }
        }
    }
}

struct MetaPresetEditorSheet: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var fields: [String: String] = [:]
    var body: some View {
        SheetFrame(title: model.L("Metadata Presets", "Metadaten-Voreinstellungen"), width: 560, done: { model.showMetaPresetEditor = false }) {
            HStack(alignment: .top, spacing: 12) {
                List(model.metaConfig.presets) { p in Text(p.name).font(Theme.small).contentShape(Rectangle()).onTapGesture { name = p.name; fields = p.fields } }.frame(width: 160, height: 300)
                VStack(alignment: .leading) {
                    TextField(model.L("Preset name", "Name"), text: $name).textFieldStyle(.roundedBorder)
                    ScrollView { VStack(spacing: 3) { ForEach([MetadataField.field("caption")!] + MetadataField.editableIPTC, id: \.id) { f in
                        HStack { Text(model.lang == "de" ? f.de : f.en).font(Theme.tiny).frame(width: 110, alignment: .trailing); TextField("", text: Binding(get: { fields[f.id] ?? "" }, set: { fields[f.id] = $0 })).textFieldStyle(.roundedBorder).font(Theme.small) } } } }.frame(height: 240)
                    HStack { Button(model.L("Save Preset", "Voreinstellung sichern")) { guard !name.isEmpty else { return }; model.metaConfig.addPreset(MetadataPreset(name: name, fields: fields.filter { !$0.value.isEmpty })); model.configChanged() }.buttonStyle(AquaButtonStyle())
                        Button(model.L("Delete", "Löschen")) { if let p = model.metaConfig.presets.first(where: { $0.name == name }) { model.metaConfig.removePreset(p.id); name = ""; fields = [:]; model.configChanged() } }.buttonStyle(AquaButtonStyle())
                        Button(model.L("Apply to Selection", "Auf Auswahl anwenden")) { model.applyMetadataPreset(MetadataPreset(name: name, fields: fields.filter { !$0.value.isEmpty })) }.buttonStyle(AquaButtonStyle()).disabled(model.selection.isEmpty) }
                }
            }
        }
    }
}

struct AutofillEditorSheet: View {
    @ObservedObject var model: AppModel
    @State private var field = "iptc.creator"
    @State private var text = ""
    var body: some View {
        SheetFrame(title: model.L("Edit AutoFill List", "AutoFill-Liste bearbeiten"), width: 420, done: { model.metaConfig.setAutofill(field, lines()); model.showAutofillEditor = false; model.configChanged() }) {
            Picker(model.L("Field", "Feld"), selection: $field) { ForEach([MetadataField.field("caption")!] + MetadataField.editableIPTC, id: \.id) { Text(model.lang == "de" ? $0.de : $0.en).tag($0.id) } }
            TextEditor(text: $text).font(Theme.small).frame(height: 160).border(Color.black.opacity(0.3))
            Text(model.L("One entry per line. Used as suggestions in the Metadata inspector.", "Ein Eintrag pro Zeile. Wird als Vorschlag im Metadaten-Reiter angeboten.")).font(Theme.tiny).foregroundColor(.gray)
        }
        .onAppear { text = model.metaConfig.autofill(field).joined(separator: "\n") }
        .onChange(of: field) { f in text = model.metaConfig.autofill(f).joined(separator: "\n") }
    }
    func lines() -> [String] { text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}

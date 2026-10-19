import SwiftUI
import UniformTypeIdentifiers
import AppKit
import RetroluxCore

/// Export panel: Export Preset, Subfolder Format, Name Format, example, alert checkbox.
struct ExportSheet: View {
    @ObservedObject var model: AppModel
    @State private var preset = ExportPreset.all.first { $0.name == UserDefaults.standard.string(forKey: "exportPresetName") } ?? ExportPreset.factory[6]
    @State private var naming = NamingPolicy.versionName
    @State private var subfolder = SubfolderPolicy.none
    @State private var folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Retrolux Export")
    @State private var original = false
    @State private var opts: ExportOptions = { var o = ExportOptions(); let d = UserDefaults.standard; o.includeLocation = d.object(forKey: "exportIncludeLocation") as? Bool ?? true; o.includePeople = d.bool(forKey: "exportIncludeFaces"); return o }()
    @State private var watermarkText = ""
    @State private var wmPosition = 8
    @State private var wmOpacity = 0.5
    @State private var custom = "Image"
    @State private var customFolder = "Folder"
    @State private var showAlert = false
    @State private var details = false
    static let wmPositions: [(String, String, Int)] = [("Top Left", "Oben links", 0), ("Top Right", "Oben rechts", 2), ("Lower Left", "Unten links", 6), ("Lower Right", "Unten rechts", 8), ("Center", "Mitte", 4)]
    var example: String {
        guard let id = model.selection.first ?? model.primary, let v = model.store.versions[id] else { return "" }
        return naming.fileName(version: v, index: 1, count: max(1, model.selection.count), custom: custom) + "." + (original ? "…" : preset.fileExtension)
    }
    func row<C: View>(_ en: String, _ de: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(model.L(en, de)).font(Theme.small).frame(width: 130, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    var body: some View {
        let n = model.selection.count
        VStack(alignment: .leading, spacing: 10) {
            Text(model.L("Export \(n) Versions", "\(n) Versionen exportieren")).font(Theme.font(14, bold: true))
            row("Where:", "Ablageort:") {
                HStack { Text(folder.path).font(Theme.tiny).lineLimit(1).truncationMode(.middle)
                    Button(model.L("Choose…", "Wählen …")) { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; if p.runModal() == .OK, let u = p.url { folder = u } }.buttonStyle(AquaButtonStyle()) }
            }
            Divider()
            row("Export Preset:", "Export-Voreinstellung:") { HStack { Picker("", selection: $preset) { ForEach(ExportPreset.all) { Text($0.name).tag($0) } }.labelsHidden().frame(width: 260).disabled(original); Button(model.L("Edit…", "Bearbeiten …")) { model.showExportPresetEditor = true }.buttonStyle(AquaButtonStyle()) } }
            row("Subfolder Format:", "Unterordnerformat:") { Picker("", selection: $subfolder) { ForEach(SubfolderPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 260) }
            if subfolder.needsCustomName { row("Custom Subfolder Name:", "Eigener Unterordnername:") { TextField("", text: $customFolder).textFieldStyle(.roundedBorder).frame(width: 200) } }
            row("Name Format:", "Namensformat:") { Picker("", selection: $naming) { ForEach(NamingPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 260).disabled(original) }
            if naming.needsCustomName { row("Custom Name:", "Eigener Name:") { TextField("", text: $custom).textFieldStyle(.roundedBorder).frame(width: 200) } }
            row("File Name Example:", "Dateinamenbeispiel:") { Text(example).font(Theme.small).foregroundColor(.gray).lineLimit(1) }
            row("", "") { Toggle(model.L("Show alert when finished", "Hinweis nach Abschluss anzeigen"), isOn: $showAlert).toggleStyle(.checkbox).font(Theme.small) }
            DisclosureGroup(model.L("Export Options", "Exportoptionen"), isExpanded: $details) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(model.L("Export original files (unchanged bytes)", "Originaldateien exportieren (unverändert)"), isOn: $original)
                    if preset.substitutes && !original { Text(model.L("PSD is written as 16-bit TIFF in this release.", "PSD wird in dieser Version als 16-Bit-TIFF geschrieben.")).font(Theme.tiny).foregroundColor(.orange) }
                    Picker(model.L("Color Profile:", "Farbprofil:"), selection: $opts.profile) { ForEach(ColorProfiles.builtin.filter { !$0.name.contains("proof only") }, id: \.name) { Text($0.name).tag($0.name) }; if opts.profile.hasPrefix("icc:") { Text(URL(fileURLWithPath: String(opts.profile.dropFirst(4))).lastPathComponent).tag(opts.profile) } }.disabled(original)
                    Button(model.L("Use ICC Profile…", "ICC-Profil verwenden …")) { let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]; if p.runModal() == .OK, let u = p.url { opts.profile = "icc:" + u.path } }.buttonStyle(AquaButtonStyle()).disabled(original)
                    GroupBox(model.L("Metadata", "Metadaten")) {
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(model.L("Keywords", "Schlagwörter"), isOn: $opts.includeKeywords); Toggle(model.L("Caption", "Beschriftung"), isOn: $opts.includeCaption)
                            Toggle(model.L("Credits (creator, copyright …)", "Urheberangaben (Urheber, Copyright …)"), isOn: $opts.includeCreditFields)
                            Toggle(model.L("Location (GPS)", "Ort (GPS)"), isOn: $opts.includeLocation); Toggle(model.L("People (names from Faces, off by default)", "Personen (Namen aus Gesichtern, standardmäßig aus)"), isOn: $opts.includePeople)
                            Toggle(model.L("Write .xmp sidecar next to each file", ".xmp-Sidecar neben jede Datei schreiben"), isOn: $opts.writeSidecar)
                        }.toggleStyle(.checkbox).font(Theme.tiny).frame(maxWidth: .infinity, alignment: .leading)
                    }.disabled(original)
                    GroupBox(model.L("Watermark", "Wasserzeichen")) {
                        VStack(alignment: .leading) {
                            TextField(model.L("Text (empty = none)", "Text (leer = keins)"), text: $watermarkText).textFieldStyle(.roundedBorder)
                            HStack { Picker(model.L("Position:", "Position:"), selection: $wmPosition) { ForEach(Self.wmPositions, id: \.2) { Text(model.L($0.0, $0.1)).tag($0.2) } }.frame(width: 190)
                                Text(model.L("Opacity:", "Deckkraft:")).font(Theme.tiny); Slider(value: $wmOpacity, in: 0.1...1).frame(width: 100) }
                        }.font(Theme.tiny)
                    }.disabled(original)
                    Text(model.L("Existing files are never overwritten.", "Vorhandene Dateien werden nie überschrieben.")).font(Theme.tiny).foregroundColor(.gray)
                }.padding(.top, 4)
            }.font(Theme.small)
            HStack { Spacer(); Button(model.L("Cancel", "Abbrechen")) { model.showExportSheet = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.cancelAction)
                Button(model.L("Export Versions", "Versionen exportieren")) {
                    var o = opts; if !watermarkText.isEmpty { var w = Watermark(text: watermarkText); w.opacity = wmOpacity; w.position = wmPosition; o.watermark = w }
                    UserDefaults.standard.set(preset.name, forKey: "exportPresetName")
                    model.showExportSheet = false
                    model.runExport(preset, folder: folder, naming: naming, original: original, options: o, custom: custom, subfolder: subfolder, customSubfolder: customFolder, showAlert: showAlert) }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 520).background(Theme.chrome)
        .onAppear { if model.exportOriginalsRequested { original = true; details = true; model.exportOriginalsRequested = false } }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    var themeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(model.L("Icon theme", "Icon-Theme"), selection: $iconTheme.current) {
                Text("Default").tag("")
                ForEach(IconTheme.available(), id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Button(model.L("Load Icon Set…", "Icon-Set laden …")) {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.message = model.L("Choose a theme folder containing theme.json", "Theme-Ordner mit theme.json wählen")
                    if p.runModal() == .OK, let u = p.url { do { iconTheme.current = try iconTheme.install(folder: u); themeNote = "" } catch { themeNote = error.localizedDescription } }
                }.buttonStyle(AquaButtonStyle())
                Button(model.L("Show Themes Folder", "Themes-Ordner zeigen")) { try? FileManager.default.createDirectory(at: IconTheme.root, withIntermediateDirectories: true); NSWorkspace.shared.open(IconTheme.root) }.buttonStyle(AquaButtonStyle())
            }
            if !themeNote.isEmpty { Text(themeNote).font(Theme.tiny).foregroundColor(.secondary) }
            Text(model.L("Icons are read from your own files; missing icons fall back to the built-in set.", "Icons werden aus Ihren eigenen Dateien gelesen; fehlende fallen auf den eingebauten Satz zurück.")).font(Theme.tiny).foregroundColor(.secondary)
        }
    }
    @State private var tab = ProcessInfo.processInfo.environment["RL_PREF_TAB"].flatMap(Int.init) ?? 0   // RL_PREF_TAB: snapshot aid
    @AppStorage("importManaged") private var importManaged = true
    @AppStorage("importSkipDupes") private var skipDupes = true
    @AppStorage("exportPresetName") private var exportPresetName = ExportPreset.factory[6].name
    @AppStorage("previewQuality") private var previewQuality = 0.8
    @AppStorage("scrollNavigates") private var scrollNavigates = false
    @AppStorage("fullScreenBrightness") private var fsBrightness = 0.0
    @AppStorage("hotThreshold") private var hotThreshold = 1.0
    @AppStorage("coldThreshold") private var coldThreshold = 1.0
    @AppStorage("clipMono") private var clipMono = 0
    @AppStorage("exportIncludeLocation") private var exportLocation = true
    @AppStorage("exportIncludeFaces") private var exportFaces = false
    @AppStorage("editorAppPath") private var editorApp = ""
    @AppStorage("editorDeep") private var editorDeep = true
    @AppStorage("editorDPI") private var editorDPI = 72
    @AppStorage("emailPresetName") private var emailPreset = ExportPreset.factory[1].name
    @AppStorage("webCopyright") private var webCopyright = ""
    @AppStorage("slideshowSecondary") private var slideshowSecondary = false
    @AppStorage("lookUpPlaces") private var lookUpPlaces = 0
    @AppStorage("newVersionOnAdjust") private var newVersionOnAdjust = false
    @ObservedObject private var iconTheme = IconTheme.shared
    @State private var themeNote = ""
    /// One labelled row; labels are right-aligned like in classic panes.
    func row<C: View>(_ en: String, _ de: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .center, spacing: 8) { Text(en.isEmpty ? "" : model.L(en, de)).frame(width: 210, alignment: .trailing); c() }
    }
    func pct(_ v: Double) -> some View { Text("\(Int(v * 100))%").frame(width: 40, alignment: .leading) }
    var body: some View {
        // panes: General, Appearance, Import, Export, Labels, Previews, Advanced
        VStack(spacing: 0) {
            Picker("", selection: $tab) { Text(model.L("General", "Allgemein")).tag(0); Text(model.L("Appearance", "Erscheinungsbild")).tag(1); Text(model.L("Import", "Import")).tag(2); Text(model.L("Export", "Export")).tag(3); Text(model.L("Labels", "Etiketten")).tag(4); Text(model.L("Previews", "Vorschauen")).tag(5); Text(model.L("Advanced", "Erweitert")).tag(6) }
                .pickerStyle(.segmented).labelsHidden().padding(10)
            Etched()
            ScrollView { Group {
                switch tab {
                case 0: VStack(alignment: .leading, spacing: 10) {
                    row("Library Location:", "Speicherort der Bibliothek:") { Text(model.store.root.path).font(Theme.tiny).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                    row("", "") { HStack { Button(model.L("Change…", "Ändern …")) { model.chooseLibrary() }.buttonStyle(AquaButtonStyle()); Button(model.L("Reveal…", "Zeigen …")) { NSWorkspace.shared.activateFileViewerSelecting([model.store.root]) }.buttonStyle(AquaButtonStyle()) } }
                    row("", "") { Toggle(model.L("Scroll to navigate photos in the Viewer", "Im Viewer mit Scrollen durch Fotos navigieren"), isOn: $scrollNavigates) }
                    row("", "") { Toggle(model.L("Enable Faces", "Gesichter aktivieren"), isOn: Binding(get: { model.facesEnabled }, set: { model.setFacesEnabled($0) })) }
                    if model.facesEnabled {
                        row("Suggestion strictness:", "Strenge der Vorschläge:") { Slider(value: Binding(get: { 1.2 - model.faceThreshold }, set: { model.setFaceThreshold(1.2 - $0) }), in: 0.2...0.9).frame(width: 180) }
                        row("", "") { HStack { Button(model.L("Re-run suggestions", "Vorschläge neu berechnen")) { model.resuggest() }.buttonStyle(AquaButtonStyle()); Button(model.L("Delete All Face Data…", "Alle Gesichtsdaten löschen …")) { model.deleteFaceData() }.buttonStyle(AquaButtonStyle()) } }
                        row("", "") { Text(model.L("Detection uses Apple's Vision framework on this Mac only; no image data is sent anywhere.", "Die Erkennung nutzt nur Apples Vision-Framework auf diesem Mac; es werden keine Bilddaten versendet.")).font(Theme.tiny).foregroundColor(.gray) }
                    }
                    Etched()
                    row("Language:", "Sprache:") { Picker("", selection: $model.lang) { Text("English").tag("en"); Text("Deutsch").tag("de") }.pickerStyle(.segmented).labelsHidden().frame(width: 200) }
                    row("", "") { Toggle(model.L("Edit commands apply to the primary photo only", "Befehle nur auf das primäre Foto anwenden"), isOn: $model.primaryOnly) }
                    Text("Retrolux is an independent fan project inspired by classic photo software. Not affiliated with or endorsed by Apple Inc.").font(Theme.tiny).foregroundColor(.gray).padding(.leading, 218) }
                case 1: VStack(alignment: .leading, spacing: 10) {
                    row("Viewer brightness:", "Viewer-Helligkeit:") { Slider(value: $model.viewerBrightness, in: 0...1) { _ in model.saveBrightness() }.frame(width: 190); pct(model.viewerBrightness) }
                    row("Full Screen Viewer brightness:", "Vollbild-Helligkeit:") { Slider(value: $fsBrightness, in: 0...1).frame(width: 190); pct(fsBrightness) }
                    row("Browser brightness:", "Browser-Helligkeit:") { Slider(value: $model.browserBrightness, in: 0...1) { _ in model.saveBrightness() }.frame(width: 190); pct(model.browserBrightness) }
                    row("Thumbnail size:", "Miniaturgröße:") { Slider(value: $model.thumbSize, in: 70...320).frame(width: 190) }
                    row("View Slideshows on:", "Diashows zeigen auf:") { Picker("", selection: $slideshowSecondary) { Text(model.L("Main Display", "Hauptbildschirm")).tag(false); Text(model.L("Secondary Display", "Zweiter Bildschirm")).tag(true) }.labelsHidden().frame(width: 180).disabled(NSScreen.screens.count < 2) }
                    row("", "") { Toggle(model.L("Show ratings and badges in the Browser", "Bewertungen und Symbole im Browser anzeigen"), isOn: $model.showMetaInBrowser) }
                    row("", "") { Toggle(model.L("Show tooltips on controls", "Kurzinfos zu Bedienelementen anzeigen"), isOn: $model.imageTooltips) }
                    Etched()
                    themeControls }
                case 2: VStack(alignment: .leading, spacing: 10) {
                    row("", "") { Toggle(model.L("Copy originals into the library by default", "Originale standardmäßig in die Bibliothek kopieren"), isOn: $importManaged) }
                    row("", "") { Toggle(model.L("Skip duplicates by default", "Duplikate standardmäßig überspringen"), isOn: $skipDupes) }
                    Text(model.L("Camera detection, default location and autosplit are chosen in the Import panel.", "Kameraerkennung, Standardziel und Aufteilen in Projekte wählst du im Importfenster.")).font(Theme.tiny).foregroundColor(.gray).padding(.leading, 218) }
                case 3: VStack(alignment: .leading, spacing: 10) {
                    row("Default export preset:", "Standard-Voreinstellung:") { Picker("", selection: $exportPresetName) { ForEach(ExportPreset.all) { Text($0.name).tag($0.name) } }.labelsHidden().frame(width: 280) }
                    row("", "") { Button(model.L("Edit Presets…", "Voreinstellungen bearbeiten …")) { model.showExportPresetEditor = true }.buttonStyle(AquaButtonStyle()) }
                    row("", "") { Toggle(model.L("Include location info in exported photos", "Ortsangaben in exportierte Fotos einschließen"), isOn: $exportLocation) }
                    row("", "") { Toggle(model.L("Include face info in exported photos", "Gesichtsangaben in exportierte Fotos einschließen"), isOn: $exportFaces) }
                    Etched()
                    row("External Photo Editor:", "Externer Foto-Editor:") { HStack { Text(editorApp.isEmpty ? model.L("System default", "Systemstandard") : URL(fileURLWithPath: editorApp).deletingPathExtension().lastPathComponent).lineLimit(1).frame(width: 150, alignment: .leading)
                        Button(model.L("Choose…", "Wählen …")) { let p = NSOpenPanel(); p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications"); if p.runModal() == .OK, let u = p.url { editorApp = u.path } }.buttonStyle(AquaButtonStyle())
                        if !editorApp.isEmpty { Button(model.L("Reset", "Zurücksetzen")) { editorApp = "" }.buttonStyle(AquaButtonStyle()) } } }
                    row("External Editor File Format:", "Dateiformat für externen Editor:") { HStack { Picker("", selection: $editorDeep) { Text("TIFF (8-bit)").tag(false); Text("TIFF (16-bit)").tag(true) }.labelsHidden().frame(width: 140)
                        TextField("", value: $editorDPI, format: .number).textFieldStyle(.roundedBorder).frame(width: 50); Text("dpi") } }
                    Text(model.L("Used by Photos ▸ Edit with External Editor…; the saved file comes back as a new version. PSD is not offered because this release cannot write PSD.", "Wird von Fotos ▸ Mit externem Editor bearbeiten … verwendet; die gesicherte Datei kommt als neue Version zurück. PSD wird nicht angeboten, weil diese Version kein PSD schreiben kann.")).font(Theme.tiny).foregroundColor(.gray).padding(.leading, 218)
                    Etched()
                    row("Email Photo Export preset:", "Export-Preset für E-Mail:") { Picker("", selection: $emailPreset) { ForEach(ExportPreset.all) { Text($0.name).tag($0.name) } }.labelsHidden().frame(width: 280) }
                    row("Web Copyright:", "Web-Copyright:") { TextField("", text: $webCopyright).textFieldStyle(.roundedBorder).frame(width: 280) } }
                case 4: VStack(alignment: .leading, spacing: 6) {
                    ForEach(1...7, id: \.self) { i in HStack { Spacer().frame(width: 150); Circle().fill(Theme.labelColors[i]).frame(width: 12, height: 12)
                        TextField("", text: Binding(get: { model.labelName(i) }, set: { model.setLabelName(i, $0) })).textFieldStyle(.roundedBorder).frame(width: 200) } } }
                case 5: VStack(alignment: .leading, spacing: 10) {
                    row("Photo Preview quality:", "Qualität der Fotovorschau:") { Slider(value: $previewQuality, in: 0.4...1).frame(width: 190); Text(String(format: "%.0f", previewQuality * 12)).frame(width: 30, alignment: .leading) }
                    row("", "") { Button(model.L("Regenerate All Thumbnails", "Alle Miniaturen neu erzeugen")) { model.regenerateThumbnails() }.buttonStyle(AquaButtonStyle()) }
                    Text(model.L("Previews let you view photos when the master file is offline.", "Vorschauen erlauben das Betrachten von Fotos, wenn das Original offline ist.")).font(Theme.tiny).foregroundColor(.gray).padding(.leading, 218) }
                default: VStack(alignment: .leading, spacing: 10) {
                    row("Hot Area threshold:", "Schwelle für Lichter:") { Slider(value: $hotThreshold, in: 0...1).frame(width: 190); pct(hotThreshold) }
                    row("Cold Area threshold:", "Schwelle für Tiefen:") { Slider(value: $coldThreshold, in: 0...1).frame(width: 190); pct(coldThreshold) }
                    row("Look up Places:", "Orte nachschlagen:") { Picker("", selection: $lookUpPlaces) { Text(model.L("Automatically", "Automatisch")).tag(0); Text(model.L("Never", "Nie")).tag(1) }.labelsHidden().frame(width: 180) }
                    row("", "") { Toggle(model.L("Create new versions when making adjustments", "Neue Versionen anlegen, wenn Anpassungen vorgenommen werden"), isOn: $newVersionOnAdjust) }
                    row("Clipping overlay:", "Beschnittanzeige:") { Picker("", selection: $clipMono) { Text(model.L("Color", "Farbe")).tag(0); Text(model.L("Monochrome", "Monochrom")).tag(1) }.labelsHidden().frame(width: 180) } }
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .topLeading).font(Theme.small) }
        }.frame(width: 720, height: 420).background(Theme.chrome)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.aperture").font(.system(size: 48)).foregroundColor(Theme.hex(0x4A4A4A))
            Text("Retrolux").font(Theme.font(16, bold: true))
            Text("Version 0.8").font(Theme.small)
            Text("Fan-Projekt: ein Nachbau, angelehnt an klassische Foto-Software.\nKein Apple-Produkt, nicht mit Apple verbunden.").font(Theme.tiny).multilineTextAlignment(.center).foregroundColor(.gray)
        }.padding(24).frame(width: 360).background(Theme.chrome)
    }
}

struct TetherSheet: View {
    @ObservedObject var model: AppModel
    @StateObject private var local = CameraManager()
    @State private var project = ""
    var cam: CameraManager { model.tether ?? local }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.L("Tethered Shooting", "Tethered Shooting")).font(Theme.font(14, bold: true))
            Text(model.L("Pictures taken with the connected camera are imported into the project as they arrive.", "Mit der angeschlossenen Kamera aufgenommene Bilder werden sofort ins Projekt importiert.")).font(Theme.tiny).foregroundColor(.gray)
            if cam.cameras.isEmpty { Text(model.L("No camera connected. Connect a PTP-capable camera and switch it on.", "Keine Kamera verbunden. Eine PTP-fähige Kamera anschließen und einschalten.")).font(Theme.small).foregroundColor(.orange) }
            ForEach(Array(cam.cameras.enumerated()), id: \.offset) { _, c in
                HStack { Image(systemName: "camera.fill"); Text(c.name ?? "Camera").font(Theme.small); Spacer(); Button(cam.connected === c ? model.L("Connected", "Verbunden") : model.L("Connect", "Verbinden")) { cam.connect(c) }.buttonStyle(AquaButtonStyle()) }
            }
            if cam.connected != nil { Text(cam.message).font(Theme.tiny).foregroundColor(.gray) }
            TextField(model.L("Project name", "Projektname"), text: $project).textFieldStyle(.roundedBorder)
            HStack {
                if !cam.tethering { Button(model.L("Start Session", "Sitzung starten")) { model.startTether(camera: cam, projectName: project) }.buttonStyle(AquaButtonStyle()).disabled(cam.connected == nil || !cam.ready) }
                else { Button(model.L("Stop Session", "Sitzung beenden")) { cam.stopTether() }.buttonStyle(AquaButtonStyle()) }
                Button(model.L("Capture", "Aufnehmen")) { cam.capture() }.buttonStyle(AquaButtonStyle()).disabled(!cam.tethering || !cam.canCapture)
                Text(model.L("\(cam.tetherCount) pictures", "\(cam.tetherCount) Bilder")).font(Theme.small); Spacer()
                Button("OK") { model.showTether = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction)
            }
            Text(model.L("Supported: every camera macOS exposes through Image Capture (PTP/MTP). Remote capture needs a camera that allows it. This feature needs a real camera and has not been exercised in tests.", "Unterstützt: jede Kamera, die macOS über Digitale Bilder (PTP/MTP) anbietet. Fernauslösung braucht eine Kamera, die das erlaubt. Diese Funktion braucht eine echte Kamera und wurde nicht in Tests ausgeführt.")).font(Theme.font(9)).foregroundColor(.gray)
        }.padding(16).frame(width: 480).background(Theme.chrome)
    }
}

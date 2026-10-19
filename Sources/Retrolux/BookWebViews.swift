import SwiftUI
import AppKit
import MapKit
import PDFKit
import UniformTypeIdentifiers
import RetroluxCore

// MARK: - Book editor
struct BookEditor: View {
    @ObservedObject var model: AppModel
    let container: Container
    @State private var doc = BookDoc()
    @State private var page = 0
    @State private var selectedItem: ID?
    @State private var pageImage: NSImage?
    @State private var report = ""
    @State private var exporting: Double?
    var t: BookType { BookType.type(doc.type) }
    func save(_ name: String? = nil, before: BookDoc? = nil) {
        try? model.store.saveDocument(container.id, doc)
        if let name, let before { let after = doc, cid = container.id; model.pushUndo(name, undo: { try? model.store.saveDocument(cid, before); doc = before; refresh() }, redo: { try? model.store.saveDocument(cid, after); doc = after; refresh() }) }
        refresh()
    }
    func refresh() {
        guard doc.pages.indices.contains(page) else { pageImage = nil; return }
        let d = doc, p = page, store = model.store
        DispatchQueue.global(qos: .userInitiated).async {
            let size = BookRenderer.pageSize(d); let scale: CGFloat = 900 / size.width
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.scaleBy(x: scale, y: scale); BookRenderer.draw(page: d.pages[p], number: p + 1, doc: d, store: store, in: ctx, size: size, pxPerInch: 110)
            if let cg = ctx.makeImage() { DispatchQueue.main.async { pageImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) } }
        }
    }
    @State private var thumbs: [ID: NSImage] = [:]
    @State private var showTheme = false
    @State private var editLayout = false
    var coverName: String { doc.cover == "soft" ? model.L("softcover", "Softcover") : model.L("hardcover", "Hardcover") }
    func renderThumbs() {
        let d = doc, store = model.store
        DispatchQueue.global(qos: .utility).async {
            var out: [ID: NSImage] = [:]
            for (i, p) in d.pages.prefix(80).enumerated() {
                let size = BookRenderer.pageSize(d), scale: CGFloat = 150 / size.width
                guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                ctx.scaleBy(x: scale, y: scale); BookRenderer.draw(page: p, number: i + 1, doc: d, store: store, in: ctx, size: size, pxPerInch: 40)
                if let cg = ctx.makeImage() { out[p.id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
            }
            DispatchQueue.main.async { thumbs = out }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
                HStack(spacing: 10) {
                    Button { showTheme.toggle() } label: { HStack(spacing: 4) { Image(systemName: "book.closed").font(.system(size: 10)); Text(model.L("Theme", "Thema")) } }.buttonStyle(AquaButtonStyle())
                        .popover(isPresented: $showTheme, arrowEdge: .bottom) { ScrollView { panel.padding(12) }.frame(width: 340, height: 560) }
                    Picker("", selection: Binding(get: { doc.cover ?? "hard" }, set: { doc.cover = $0; save() })) { Text("Hardcover").tag("hard"); Text("Softcover").tag("soft") }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                    Picker("", selection: $editLayout) { Text(model.L("Edit Content", "Inhalt bearbeiten")).tag(false); Text(model.L("Edit Layout", "Layout bearbeiten")).tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                    Menu { ForEach(BookLayouts.names, id: \.self) { n in Button(n) { addPage(layout: n) } } } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).frame(width: 34)
                    Spacer()
                    Button(model.L("Print…", "Drucken …")) { printBook() }.buttonStyle(AquaButtonStyle())
                    Button(model.L("Export PDF…", "PDF exportieren …")) { exportPDF() }.buttonStyle(AquaButtonStyle())
                }.padding(.horizontal, 10).frame(height: 32)
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text(model.L("Pages", "Seiten")).font(Theme.font(10, bold: true)).foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 3).background(Theme.hex(0x555555))
                    ScrollView { LazyVStack(spacing: 8) { ForEach(Array(doc.pages.enumerated()), id: \.element.id) { i, p in
                        HStack(alignment: .bottom, spacing: 4) {
                            ZStack { Color(white: 0.8); if let im = thumbs[p.id] { Image(nsImage: im).resizable().aspectRatio(contentMode: .fit) } }.frame(width: 96, height: 72).overlay(Rectangle().stroke(i == page ? Color.white : Color.black.opacity(0.4), lineWidth: i == page ? 2 : 0.5))
                            Text("\(i + 1)").font(Theme.font(9)).foregroundColor(.white)
                        }.onTapGesture { page = i; selectedItem = nil; refresh() }
                    } }.padding(8) }
                    Etched()
                    HStack(spacing: 4) { Button("+") { addPage() }.buttonStyle(AquaButtonStyle()); Button("−") { deletePage() }.buttonStyle(AquaButtonStyle()).disabled(doc.pages.isEmpty); Button("↑") { movePage(-1) }.buttonStyle(AquaButtonStyle()); Button("↓") { movePage(1) }.buttonStyle(AquaButtonStyle()) }.padding(6)
                }.frame(width: 150).background(Theme.hex(0x4A4A4A))
                Rectangle().fill(Color.black.opacity(0.5)).frame(width: 1)
                VStack(spacing: 0) {
                    ZStack {
                        Color(white: 0.3)
                        if let img = pageImage, doc.pages.indices.contains(page) {
                            GeometryReader { g in
                                let s = min((g.size.width - 30) / img.size.width, (g.size.height - 30) / img.size.height)
                                ZStack(alignment: .topLeading) {
                                    Image(nsImage: img).resizable().frame(width: img.size.width * s, height: img.size.height * s).shadow(radius: 8)
                                    ForEach(doc.pages[page].items) { it in
                                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                                            .overlay(Rectangle().stroke(selectedItem == it.id ? Theme.accent : (editLayout ? Theme.accent.opacity(0.7) : Color.clear), lineWidth: selectedItem == it.id ? 2 : 1))
                                            .frame(width: CGFloat(it.w) * img.size.width * s * pageInner(), height: CGFloat(it.h) * img.size.height * s * pageInner())
                                            .offset(x: img.size.width * s * (CGFloat(bleedFrac()) + CGFloat(it.x) * pageInner()), y: img.size.height * s * (CGFloat(bleedFrac()) + CGFloat(it.y) * pageInner()))
                                            .onTapGesture { selectedItem = it.id }
                                            .dropDestination(for: String.self) { ids, _ in assign(ids.first, to: it.id); return true }
                                    }
                                }.frame(width: img.size.width * s, height: img.size.height * s).position(x: g.size.width / 2, y: g.size.height / 2)
                            }
                        } else { Text(model.L("Add a page", "Seite hinzufügen")).foregroundColor(.gray) }
                    }.overlay(alignment: .topTrailing) {
                        if let sel = selectedItem, doc.pages.indices.contains(page), let it = doc.pages[page].items.first(where: { $0.id == sel }), it.kind == .map, it.mapPlaces != nil {
                            MapOptionsHUD(model: model, item: it,
                                          setZoom: { z in updateMap(sel, model.L("Map Zoom", "Kartenzoom")) { $0.zoom = z } },
                                          setTitle: { t in updateMap(sel, model.L("Map Title", "Kartentitel")) { $0.mapTitle = t } },
                                          add: { addSelectedPlaces(sel) },
                                          remove: { pid in updateMap(sel, model.L("Remove Place", "Ort entfernen")) { $0.mapPlaces?.removeAll { $0.id == pid } } },
                                          close: { selectedItem = nil }).padding(12)
                        }
                    }
                    if !report.isEmpty { Text(report).font(Theme.tiny).padding(6).frame(maxWidth: .infinity, alignment: .leading).background(Color.yellow.opacity(0.25)) }
                    AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
                        HStack(spacing: 8) {
                            Button { page = max(0, page - 1); refresh() } label: { Image(systemName: "chevron.left") }.buttonStyle(AquaButtonStyle()).disabled(page == 0)
                            Button { page = min(doc.pages.count - 1, page + 1); refresh() } label: { Image(systemName: "chevron.right") }.buttonStyle(AquaButtonStyle()).disabled(page >= doc.pages.count - 1)
                            Spacer()
                            Text("\(doc.theme), \(model.L(t.en, t.de).replacingOccurrences(of: "Softcover", with: "").replacingOccurrences(of: "Hardcover", with: "").trimmingCharacters(in: .whitespaces).lowercased()) \(coverName) (\(String(format: "%.4g", t.widthIn))\" × \(String(format: "%.4g", t.heightIn))\")  ·  \(doc.pages.count) \(model.L("pages", "Seiten"))").font(Theme.tiny)
                            Spacer()
                        }.padding(.horizontal, 10).frame(height: 28)
                    }
                }
            }
        }
        .onAppear { load(); model.browserMode = .filmstrip; renderThumbs() }.onChange(of: container.id) { _ in load(); renderThumbs() }
        .onChange(of: doc) { _ in renderThumbs() }
    }
    func bleedFrac() -> Double { doc.bleed ? (9 / BookRenderer.pageSize(doc).width) : 0 }
    func pageInner() -> CGFloat { doc.bleed ? 1 - 2 * CGFloat(bleedFrac()) : 1 }
    func load() { doc = model.store.document(container.id, as: BookDoc.self) ?? BookDoc(); page = 0; selectedItem = nil; report = ""; refresh() }

    func addPage(layout: String = "Two Up") { let b = doc; let theme = BookTheme.theme(doc.theme); let ids = model.selection.prefix(BookLayouts.slots(layout)).map { Optional($0) }
        doc.pages.insert(BookPage(layout: layout, items: BookLayouts.items(layout: layout, theme: theme, versions: Array(ids) + Array(repeating: nil, count: max(0, BookLayouts.slots(layout) - ids.count)))), at: min(doc.pages.count, page + 1)); page = min(doc.pages.count - 1, page + 1); save(model.L("Add Page", "Seite hinzufügen"), before: b) }
    func deletePage() { guard doc.pages.indices.contains(page) else { return }; let b = doc; doc.pages.remove(at: page); page = max(0, min(page, doc.pages.count - 1)); save(model.L("Delete Page", "Seite löschen"), before: b) }
    func movePage(_ d: Int) { let j = page + d; guard doc.pages.indices.contains(page), doc.pages.indices.contains(j) else { return }; let b = doc; doc.pages.swapAt(page, j); page = j; save(model.L("Move Page", "Seite verschieben"), before: b) }
    func assign(_ vid: ID?, to item: ID) { guard let vid, model.store.versions[vid] != nil, doc.pages.indices.contains(page), let k = doc.pages[page].items.firstIndex(where: { $0.id == item }), doc.pages[page].items[k].kind == .image else { return }
        let b = doc; doc.pages[page].items[k].versionID = vid; save(model.L("Place Photo", "Foto platzieren"), before: b) }
    func relayout(_ name: String) {
        guard doc.pages.indices.contains(page) else { return }; let b = doc; let theme = BookTheme.theme(doc.theme)
        let imgs = doc.pages[page].items.filter { $0.kind == .image }.map(\.versionID); let caps = doc.pages[page].items.filter { $0.kind == .text }.map(\.text)
        let need = BookLayouts.slots(name); var vs = imgs; while vs.count < need { vs.append(nil) }
        doc.pages[page] = BookPage(layout: name, items: BookLayouts.items(layout: name, theme: theme, versions: Array(vs.prefix(need)), caption: caps)); save(model.L("Change Layout", "Layout ändern"), before: b)
    }
    func retheme(_ n: String) { let b = doc; doc.theme = n; let theme = BookTheme.theme(n)
        for i in doc.pages.indices { let old = doc.pages[i]; let vs = old.items.filter { $0.kind == .image }.map(\.versionID); let caps = old.items.filter { $0.kind == .text }.map(\.text)
            doc.pages[i] = BookPage(layout: old.layout, items: BookLayouts.items(layout: old.layout, theme: theme, versions: vs, caption: caps)) }
        save(model.L("Change Theme", "Thema ändern"), before: b) }
    func autoflow() { let b = doc; let ids = model.documentVersions(model.store.containers[container.id] ?? container); doc.pages = BookLayouts.autoflow(ids, theme: doc.theme, captions: Dictionary(uniqueKeysWithValues: ids.compactMap { id in model.store.versions[id].map { (id, $0.caption) } })); page = 0; save(model.L("Autoflow", "Automatisch füllen"), before: b) }
    func addMapPage() {
        let pts = model.documentVersions(model.store.containers[container.id] ?? container).compactMap { model.store.versions[$0] }.filter { $0.latitude != nil }
        guard !pts.isEmpty else { model.alert = (model.L("Map page", "Kartenseite"), model.L("None of the photos in this book has a location.", "Kein Foto in diesem Buch hat einen Ort.")); return }
        let places = pts.map { MapPlace(name: $0.name, latitude: $0.latitude!, longitude: $0.longitude!) }
        MapPageMaker.make(places: places, title: "", zoom: 1, dir: model.store.attachmentsDir) { url in
            guard let url else { model.alert = (model.L("Map page", "Kartenseite"), model.L("The map could not be loaded (offline?). Map data © Apple Maps.", "Die Karte konnte nicht geladen werden (offline?). Kartendaten © Apple Karten.")); return }
            let b = doc; let th = BookTheme.theme(doc.theme); var m = BookItem(kind: .map, x: th.margin, y: th.margin, w: 1 - 2 * th.margin, h: (1 - 2 * th.margin) * 0.85); m.text = url.path; m.mapPlaces = places; m.mapTitle = ""
            var cap = BookItem(kind: .text, x: th.margin, y: th.margin + (1 - 2 * th.margin) * 0.88, w: 1 - 2 * th.margin, h: 0.08, text: "Map data © Apple Maps"); cap.fontSize = 9
            doc.pages.append(BookPage(layout: "Map", items: [m, cap])); page = doc.pages.count - 1; save(model.L("Add Map Page", "Kartenseite hinzufügen"), before: b)
        }
    }
    /// Map Options HUD changes: apply, rebuild the map picture, save (undoable).
    func updateMap(_ id: ID, _ name: String, _ change: @escaping (inout BookItem) -> Void) {
        guard doc.pages.indices.contains(page), let k = doc.pages[page].items.firstIndex(where: { $0.id == id }) else { return }
        let before = doc; var it = doc.pages[page].items[k]; change(&it)
        MapPageMaker.make(places: it.mapPlaces ?? [], title: it.mapTitle ?? "", zoom: it.zoom, dir: model.store.attachmentsDir) { url in
            guard let url, doc.pages.indices.contains(page), let k2 = doc.pages[page].items.firstIndex(where: { $0.id == id }) else { return }
            it.text = url.path; doc.pages[page].items[k2] = it; save(name, before: before)
        }
    }
    func addSelectedPlaces(_ id: ID) {
        let add = model.selection.compactMap { model.store.versions[$0] }.filter { $0.latitude != nil }.map { MapPlace(name: $0.name, latitude: $0.latitude!, longitude: $0.longitude!) }
        guard !add.isEmpty else { model.status = model.L("Select photos with a location to add them as places", "Fotos mit Ort wählen, um sie als Orte hinzuzufügen"); return }
        updateMap(id, model.L("Add Places", "Orte hinzufügen")) { $0.mapPlaces = ($0.mapPlaces ?? []) + add }
    }
    func exportPDF() {
        let p = NSSavePanel(); p.allowedContentTypes = [.pdf]; p.nameFieldStringValue = container.name + ".pdf"; guard p.runModal() == .OK, let u = p.url else { return }
        exporting = 0; let d = doc, store = model.store
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try BookRenderer.pdf(d, store: store, to: u) { i, n in DispatchQueue.main.async { exporting = Double(i) / Double(max(1, n)) } } }
            DispatchQueue.main.async { exporting = nil; switch r { case .success(let rep): report = rep.ok ? model.L("PDF written – no problems found.", "PDF geschrieben – keine Probleme gefunden.") : rep.text; NSWorkspace.shared.activateFileViewerSelecting([u]); case .failure(let e): model.alert = ("Book", e.localizedDescription) } }
        }
    }
    func printBook() {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("rl-book-\(UUID().uuidString).pdf"); let d = doc, store = model.store
        DispatchQueue.global(qos: .userInitiated).async { _ = try? BookRenderer.pdf(d, store: store, to: u); DispatchQueue.main.async { if let pd = PDFDocument(url: u) { PDFDocumentLoader.printDocument(pd, window: NSApp.keyWindow) } } }
    }
    var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(model.L("Book type", "Buchtyp"), selection: Binding(get: { doc.type }, set: { let b = doc; doc.type = $0; save("Book Type", before: b) })) { ForEach(BookType.all, id: \.key) { Text(model.lang == "de" ? $0.de : $0.en).tag($0.key) } }
            Text(String(format: "%.1f × %.1f in – ", t.widthIn, t.heightIn) + model.L("page size is approximate", "Seitengröße ist angenähert")).font(Theme.font(9)).foregroundColor(.gray)
            Picker(model.L("Theme", "Thema"), selection: Binding(get: { doc.theme }, set: { retheme($0) })) { ForEach(BookTheme.all, id: \.name) { Text($0.name).tag($0.name) } }
            Toggle(model.L("Page numbers", "Seitenzahlen"), isOn: Binding(get: { doc.showPageNumbers }, set: { doc.showPageNumbers = $0; save() })); Toggle(model.L("Bleed (extra 0.125 in per edge)", "Beschnitt (0,125 in zusätzlich)"), isOn: Binding(get: { doc.bleed }, set: { doc.bleed = $0; save() }))
            Etched()
            if doc.pages.indices.contains(page) {
                Picker(model.L("Page layout", "Seitenlayout"), selection: Binding(get: { doc.pages[page].layout }, set: { relayout($0) })) { ForEach(BookLayouts.names, id: \.self) { Text($0).tag($0) }; if doc.pages[page].layout == "Map" { Text("Map").tag("Map") } }
                if let sel = selectedItem, let k = doc.pages[page].items.firstIndex(where: { $0.id == sel }) {
                    let it = doc.pages[page].items[k]
                    if it.kind == .text { TextEditor(text: Binding(get: { doc.pages[page].items[k].text }, set: { doc.pages[page].items[k].text = $0 })).font(Theme.small).frame(height: 90).border(Color.black.opacity(0.3))
                        Stepper(model.L("Font size \(Int(it.fontSize))", "Schriftgröße \(Int(it.fontSize))"), value: Binding(get: { doc.pages[page].items[k].fontSize }, set: { doc.pages[page].items[k].fontSize = $0 }), in: 6...72)
                        Picker("", selection: Binding(get: { doc.pages[page].items[k].align }, set: { doc.pages[page].items[k].align = $0 })) { Text("◀").tag("left"); Text("■").tag("center"); Text("▶").tag("right") }.pickerStyle(.segmented).labelsHidden()
                        Button(model.L("Apply Text", "Text übernehmen")) { save() }.buttonStyle(AquaButtonStyle()) }
                    else { Text(it.versionID.flatMap { model.store.versions[$0]?.name } ?? model.L("Empty slot – drag a photo here or use the button", "Leerer Platz – Foto hierher ziehen oder Button nutzen")).font(Theme.tiny)
                        Button(model.L("Use Selected Photo", "Gewähltes Foto verwenden")) { assign(model.primary, to: sel) }.buttonStyle(AquaButtonStyle()).disabled(model.primary == nil)
                        Stepper("Zoom " + String(format: "%.1f", it.zoom), value: Binding(get: { doc.pages[page].items[k].zoom }, set: { doc.pages[page].items[k].zoom = $0 }), in: 1...4, step: 0.1) }
                    if it.kind == .image { HStack { Text(model.L("Crop", "Ausschnitt")).font(Theme.tiny); Slider(value: Binding(get: { doc.pages[page].items[k].cropX }, set: { doc.pages[page].items[k].cropX = $0 }), in: 0...1, onEditingChanged: { if !$0 { save() } }).frame(width: 70); Slider(value: Binding(get: { doc.pages[page].items[k].cropY }, set: { doc.pages[page].items[k].cropY = $0 }), in: 0...1, onEditingChanged: { if !$0 { save() } }).frame(width: 70) } }
                } else { Text(model.L("Click a photo or text box on the page to edit it.", "Foto oder Textfeld auf der Seite anklicken, um es zu bearbeiten.")).font(Theme.tiny).foregroundColor(.gray) }
            }
            Etched()
            HStack { Button(model.L("Autoflow", "Automatisch füllen")) { autoflow() }.buttonStyle(AquaButtonStyle()); Button(model.L("Map Page", "Kartenseite")) { addMapPage() }.buttonStyle(AquaButtonStyle()) }
            HStack { Button(model.L("Check Book", "Buch prüfen")) { report = BookRenderer.check(doc, store: model.store).text + (doc.pages.count < t.minPages ? "\n" + model.L("Fewer than \(t.minPages) pages (minimum for this type).", "Weniger als \(t.minPages) Seiten (Minimum für diesen Typ).") : "") }.buttonStyle(AquaButtonStyle())
                Button(model.L("Export PDF…", "PDF exportieren …")) { exportPDF() }.buttonStyle(AquaButtonStyle()); Button(model.L("Print…", "Drucken …")) { printBook() }.buttonStyle(AquaButtonStyle()) }
            if let e = exporting { ProgressView(value: e) }
            Button(model.L("Order Book…", "Buch bestellen …")) { model.showServices = true }.buttonStyle(AquaButtonStyle())
        }.font(Theme.small)
    }
}

// MARK: - Web journal / gallery editor
struct WebEditor: View {
    @ObservedObject var model: AppModel
    let container: Container
    @State private var d = WebDoc()
    @State private var note = ""
    func save() { try? model.store.saveDocument(container.id, d) }
    var ids: [ID] { model.documentVersions(model.store.containers[container.id] ?? container) }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) { HStack { Text(container.name).font(Theme.font(12, bold: true)); Spacer(); Text(d.blocks.isEmpty ? model.L("Gallery: \(ids.count) photos", "Galerie: \(ids.count) Fotos") : model.L("Journal: \(d.blocks.count) blocks", "Journal: \(d.blocks.count) Blöcke")).font(Theme.tiny) }.padding(.horizontal, 8).frame(height: 28) }
                List {
                    ForEach($d.blocks) { $b in
                        HStack { Image(systemName: b.kind == .heading ? "textformat.size" : (b.kind == .text ? "text.alignleft" : "photo")).frame(width: 20)
                            if b.kind == .image { TileThumb(model: model, id: b.versionID ?? "").frame(width: 60, height: 40); Text(b.versionID.flatMap { model.store.versions[$0]?.name } ?? "").font(Theme.tiny) }
                            else { TextField("", text: $b.text, axis: .vertical).textFieldStyle(.roundedBorder).font(Theme.small).onSubmit(save) } }
                    }.onMove { d.blocks.move(fromOffsets: $0, toOffset: $1); save() }.onDelete { d.blocks.remove(atOffsets: $0); save() }
                    if d.blocks.isEmpty { Text(model.L("Gallery mode: all photos of this document are shown as a thumbnail page. Add blocks to write a journal instead.", "Galerie-Modus: Alle Fotos dieses Dokuments erscheinen als Vorschauseite. Füge Blöcke hinzu, um stattdessen ein Journal zu schreiben.")).font(Theme.tiny).foregroundColor(.gray) }
                }
                HStack { Button(model.L("+ Heading", "+ Überschrift")) { d.blocks.append(WebBlock(kind: .heading, text: model.L("Heading", "Überschrift"))); save() }.buttonStyle(AquaButtonStyle())
                    Button(model.L("+ Text", "+ Text")) { d.blocks.append(WebBlock(kind: .text, text: "")); save() }.buttonStyle(AquaButtonStyle())
                    Button(model.L("+ Selected Photos", "+ Gewählte Fotos")) { for id in model.selection { d.blocks.append(WebBlock(kind: .image, versionID: id)) }; save() }.buttonStyle(AquaButtonStyle()).disabled(model.selection.isEmpty); Spacer() }.padding(6)
            }.frame(minWidth: 360)
            ScrollView { VStack(alignment: .leading, spacing: 8) {
                TextField(model.L("Title", "Titel"), text: Binding(get: { d.title }, set: { d.title = $0; save() })).textFieldStyle(.roundedBorder)
                Picker(model.L("Theme", "Thema"), selection: Binding(get: { d.theme }, set: { d.theme = $0; save() })) { ForEach(WebDoc.themes, id: \.self) { Text($0).tag($0) } }
                Stepper(model.L("Columns: \(d.columns)", "Spalten: \(d.columns)"), value: Binding(get: { d.columns }, set: { d.columns = $0; save() }), in: 1...8)
                Picker(model.L("Images", "Bilder"), selection: Binding(get: { d.imagePreset }, set: { d.imagePreset = $0; save() })) { ForEach(WebDoc.presets.filter { !$0.0.contains("Thumb") }, id: \.0) { Text($0.0).tag($0.0) } }
                Picker(model.L("Thumbnails", "Vorschaubilder"), selection: Binding(get: { d.thumbPreset }, set: { d.thumbPreset = $0; save() })) { ForEach(WebDoc.presets.filter { $0.0.contains("Thumb") }, id: \.0) { Text($0.0).tag($0.0) } }
                Toggle(model.L("Show captions", "Beschriftungen zeigen"), isOn: Binding(get: { d.showCaptions }, set: { d.showCaptions = $0; save() })); Toggle(model.L("Show EXIF", "EXIF zeigen"), isOn: Binding(get: { d.showMetadata }, set: { d.showMetadata = $0; save() }))
                Text(model.L("Output is a local folder of HTML files. Upload it to any web space you control; nothing is published by this app.", "Die Ausgabe ist ein lokaler Ordner mit HTML-Dateien. Lade ihn auf einen Webspace deiner Wahl hoch; diese App veröffentlicht nichts.")).font(Theme.font(9)).foregroundColor(.gray)
                HStack { Button(model.L("Preview in Browser", "Vorschau im Browser")) { preview() }.buttonStyle(AquaButtonStyle()); Button(model.L("Export Folder…", "Ordner exportieren …")) { export() }.buttonStyle(AquaButtonStyle()) }
                if !note.isEmpty { Text(note).font(Theme.tiny).foregroundColor(.gray) }
            }.padding(12).font(Theme.small) }.frame(minWidth: 280, idealWidth: 300)
        }
        .onAppear { load() }.onChange(of: container.id) { _ in load() }
    }
    func load() { d = model.store.document(container.id, as: WebDoc.self) ?? { var x = WebDoc(); x.title = container.name; return x }() }
    func run(to dir: URL, open: Bool) {
        let doc = d, list = ids, store = model.store; note = model.L("Exporting…", "Exportiere …")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try WebExporter.export(doc, versions: list, store: store, to: dir) }
            DispatchQueue.main.async { switch r { case .success(let x): note = model.L("\(x.images) images written to \(dir.lastPathComponent)", "\(x.images) Bilder nach \(dir.lastPathComponent) geschrieben") + (x.skipped.isEmpty ? "" : "; " + model.L("skipped: ", "übersprungen: ") + x.skipped.joined(separator: ", ")); if open { NSWorkspace.shared.open(x.index) } else { NSWorkspace.shared.activateFileViewerSelecting([x.index]) }
                case .failure(let e): note = e.localizedDescription } }
        }
    }
    func preview() { run(to: FileManager.default.temporaryDirectory.appendingPathComponent("rl-web-\(container.id)"), open: true) }
    func export() { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; if p.runModal() == .OK, let u = p.url { run(to: u.appendingPathComponent(container.name.replacingOccurrences(of: "/", with: "-")), open: false) } }
}

typealias TileThumbAlias = TileThumb
struct TileThumbShim {}


/// Builds the map picture of a book map page: Apple Maps snapshot with red pins and an optional title band.
enum MapPageMaker {
    static func make(places: [MapPlace], title: String, zoom: Double, dir: URL, completion: @escaping (URL?) -> Void) {
        guard !places.isEmpty else { completion(nil); return }
        let opt = MKMapSnapshotter.Options(); opt.size = CGSize(width: 1200, height: 800)
        let las = places.map(\.latitude), los = places.map(\.longitude)
        let z = max(0.25, min(4, zoom))
        opt.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (las.min()! + las.max()!) / 2, longitude: (los.min()! + los.max()!) / 2),
                                        span: MKCoordinateSpan(latitudeDelta: min(170, max(0.05, (las.max()! - las.min()!) * 1.5) / z), longitudeDelta: min(350, max(0.05, (los.max()! - los.min()!) * 1.5) / z)))
        MKMapSnapshotter(options: opt).start { snap, _ in
            guard let snap else { DispatchQueue.main.async { completion(nil) }; return }
            let img = NSImage(size: snap.image.size); img.lockFocus(); snap.image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
            for p in places { let pt = snap.point(for: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)); NSColor.red.setFill(); NSBezierPath(ovalIn: CGRect(x: pt.x - 6, y: pt.y - 6, width: 12, height: 12)).fill() }
            if !title.isEmpty {
                let band = NSRect(x: 0, y: img.size.height - 64, width: img.size.width, height: 64); NSColor.black.withAlphaComponent(0.55).setFill(); band.fill()
                (title as NSString).draw(in: band.insetBy(dx: 18, dy: 12), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.white])
            }
            img.unlockFocus()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); let url = dir.appendingPathComponent("map-\(newID()).png")
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else { DispatchQueue.main.async { completion(nil) }; return }
            DispatchQueue.main.async { completion(url) }
        }
    }
}

/// "Map Options" HUD for a selected book map (layout: Zoom, Title, Places list with + / −).
struct MapOptionsHUD: View {
    @ObservedObject var model: AppModel
    let item: BookItem
    var setZoom: (Double) -> Void, setTitle: (String) -> Void, add: () -> Void, remove: (ID) -> Void, close: () -> Void
    @State private var title = ""
    @State private var zoom = 1.0
    @State private var selected: ID?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(model.L("Map Options", "Karteneinstellungen")).font(Theme.font(11, bold: true)); Spacer(); Button { close() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            HStack { Text(model.L("Zoom :", "Zoom:")).frame(width: 52, alignment: .trailing); Image(systemName: "minus").font(.system(size: 8))
                Slider(value: $zoom, in: 0.25...4, onEditingChanged: { if !$0 { setZoom(zoom) } }); Image(systemName: "plus").font(.system(size: 8)) }
            HStack { Text(model.L("Title :", "Titel:")).frame(width: 52, alignment: .trailing); TextField("", text: $title, onCommit: { setTitle(title) }).textFieldStyle(.roundedBorder).foregroundColor(.black) }
            HStack(alignment: .top) { Text(model.L("Places :", "Orte:")).frame(width: 52, alignment: .trailing)
                VStack(spacing: 4) {
                    List(selection: $selected) { ForEach(item.mapPlaces ?? []) { p in Text(p.name).font(Theme.small).tag(p.id as ID?) } }.frame(height: 150).scrollContentBackground(.hidden).background(Color.black.opacity(0.35))
                    HStack(spacing: 4) { Button("+") { add() }.buttonStyle(AquaButtonStyle()).help(model.L("Add the selected photos' locations", "Orte der gewählten Fotos hinzufügen"))
                        Button("−") { if let s = selected { remove(s); selected = nil } }.buttonStyle(AquaButtonStyle()).disabled(selected == nil); Spacer() } } }
        }.font(Theme.small).foregroundColor(.white).padding(10).frame(width: 276)
            .background(Color.black.opacity(0.82)).cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2)))
            .environment(\.hudDark, true)
            .onAppear { title = item.mapTitle ?? ""; zoom = item.zoom }
            .onChange(of: item.id) { _ in title = item.mapTitle ?? ""; zoom = item.zoom }
    }
}

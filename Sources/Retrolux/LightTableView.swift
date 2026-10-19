import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RetroluxCore

struct LTImage: View {
    @ObservedObject var model: AppModel
    let id: ID
    let px: Int
    @State private var img: NSImage?
    var body: some View {
        Group { if let img { Image(nsImage: img).resizable().interpolation(.high) } else { Rectangle().fill(Color.black.opacity(0.3)) } }
            .task(id: "\(id)\(px)\(model.thumbRevision[id] ?? 0)") { if let v = model.store.versions[id] { img = await ThumbnailProvider.shared.image(for: v, store: model.store, px: min(1600, max(300, px))) } }
    }
}

struct LightTableView: View {
    @ObservedObject var model: AppModel
    let container: Container
    @State private var doc = LightTableDoc()
    @State private var selected: Set<ID> = []
    @State private var zoom = 0.6
    @State private var dragStart: [ID: CGPoint] = [:]
    @State private var loaded: ID?
    let table = CGSize(width: 2400, height: 1600)

    func save(_ undoName: String? = nil, before: LightTableDoc? = nil) {
        try? model.store.saveDocument(container.id, doc)
        if let name = undoName, let before { let after = doc; let cid = container.id
            model.pushUndo(name, undo: { try? model.store.saveDocument(cid, before); if loaded == cid { doc = before } }, redo: { try? model.store.saveDocument(cid, after); if loaded == cid { doc = after } }) }
    }
    func idx(_ id: ID) -> Int? { doc.items.firstIndex { $0.id == id } }
    func snap(_ v: Double) -> Double { doc.snapToGrid ? (v / doc.grid).rounded() * doc.grid : v }
    func addPhotos(_ ids: [ID], at p: CGPoint? = nil) {
        let before = doc; var x = p?.x ?? 200, y = p?.y ?? 180
        for id in ids where model.store.versions[id] != nil { let a = model.store.aspect(id); let w = 240.0; doc.items.append(LightTableItem(versionID: id, x: Double(x), y: Double(y), width: w, height: w / a, z: (doc.items.map(\.z).max() ?? 0) + 1)); x += 30; y += 30 }
        save(model.L("Add to Light Table", "Zum Leuchttisch hinzufügen"), before: before)
    }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        let base = 0.16 + 0.3 * doc.background
                        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: base)))
                        var g = Path(); var x: CGFloat = 0
                        while x <= size.width { g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: size.height)); x += CGFloat(doc.grid) }
                        var y: CGFloat = 0
                        while y <= size.height { g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: size.width, y: y)); y += CGFloat(doc.grid) }
                        ctx.stroke(g, with: .color(Color(white: base + 0.05)), lineWidth: 1)
                    }.frame(width: table.width, height: table.height).onTapGesture { selected = [] }
                    ForEach(doc.items) { it in item(it) }
                }
                .frame(width: table.width, height: table.height).scaleEffect(zoom, anchor: .topLeading).frame(width: table.width * zoom, height: table.height * zoom, alignment: .topLeading)
                .dropDestination(for: String.self) { ids, loc in addPhotos(ids, at: CGPoint(x: loc.x / zoom, y: loc.y / zoom)); return true }
            }.background(Color(white: 0.16 + 0.3 * doc.background))
            .overlay(alignment: .bottomLeading) { toolStrip }
        }
        .onAppear { load(); model.browserMode = .filmstrip }.onChange(of: container.id) { _ in load() }
    }
    func load() { doc = model.store.document(container.id, as: LightTableDoc.self) ?? LightTableDoc(); loaded = container.id; selected = [] }

    @ViewBuilder func item(_ it: LightTableItem) -> some View {
        let sel = selected.contains(it.id)
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 2) {
                LTImage(model: model, id: it.versionID, px: Int(it.width * zoom * 2)).frame(width: it.width, height: it.height)
                    .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(sel ? Color.white : Color.clear, lineWidth: 5).padding(-6))
                if doc.showLabels, let v = model.store.versions[it.versionID] { Text(v.name).font(Theme.tiny).foregroundColor(.white).shadow(radius: 1) }
            }
            if sel { Circle().fill(Theme.accent).frame(width: 14, height: 14).overlay(Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 7)).foregroundColor(.white)).offset(x: 6, y: 6)
                .gesture(DragGesture().onChanged { g in if let i = idx(it.id) { let a = model.store.aspect(it.versionID); let w = max(60, doc.items[i].width + Double(g.translation.width) / Double(zoom) * 0.2); doc.items[i].width = w; doc.items[i].height = w / a } }.onEnded { _ in save() }) }
        }
        .rotationEffect(.degrees(it.rotation)).position(x: it.x, y: it.y).zIndex(Double(it.z))
        .gesture(DragGesture(minimumDistance: 2).onChanged { g in
            if dragStart.isEmpty { for s in (selected.contains(it.id) ? selected : [it.id]) { if let i = idx(s) { dragStart[s] = CGPoint(x: doc.items[i].x, y: doc.items[i].y) } }; if !selected.contains(it.id) { selected = [it.id] } }
            for (s, p) in dragStart { if let i = idx(s) { doc.items[i].x = snap(Double(p.x + g.translation.width / zoom)); doc.items[i].y = snap(Double(p.y + g.translation.height / zoom)) } }
        }.onEnded { _ in dragStart = [:]; save() })
        .onTapGesture(count: 2) { model.click(it.versionID, extend: false, toggle: false); model.viewMode = .viewer; model.source = .container(model.store.versions[it.versionID]?.projectID ?? container.id) }
        .onTapGesture { if NSEvent.modifierFlags.contains(.shift) { if sel { selected.remove(it.id) } else { selected.insert(it.id) } } else { selected = [it.id]; if let i = idx(it.id) { doc.items[i].z = (doc.items.map(\.z).max() ?? 0) + 1 } } }
    }

    var toolStrip: some View {
        HStack(spacing: 4) {
            Image(systemName: "cursorarrow").frame(width: 26, height: 20).background(Theme.hex(0x8A8F9A)).cornerRadius(3)
            Button { rotate(-15) } label: { Image(systemName: "rotate.left").frame(width: 26, height: 20) }.buttonStyle(.plain).disabled(selected.isEmpty)
            Button { rotate(15) } label: { Image(systemName: "rotate.right").frame(width: 26, height: 20) }.buttonStyle(.plain).disabled(selected.isEmpty)
        }.padding(4).background(LinearGradient(colors: [Theme.hex(0xD6D6D6), Theme.hex(0xB2B2B2)], startPoint: .top, endPoint: .bottom)).cornerRadius(4).padding(8).foregroundColor(.black)
    }
    var toolbar: some View {
        AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
            ZStack {
                Text(container.name).font(Theme.font(11)).foregroundColor(Color(white: 0.2))
                HStack(spacing: 6) {
                    Button { addPhotos(model.selection) } label: { Image(systemName: "plus.rectangle.on.rectangle").frame(width: 26, height: 20) }.buttonStyle(AquaButtonStyle()).disabled(model.selection.isEmpty).help(model.L("Add Selected", "Auswahl hinzufügen"))
                    Menu { Button(model.L("Grid", "Raster")) { let b = doc; LightTableLayout.grid(&doc.items, aspect: { model.store.aspect($0) }, bounds: CGSize(width: 1400, height: 900)); save("Arrange", before: b) }
                        Button(model.L("Pile", "Stapel")) { let b = doc; LightTableLayout.pile(&doc.items, center: CGPoint(x: 700, y: 450)); save("Arrange", before: b) } } label: { Image(systemName: "square.grid.3x1.below.line.grid.1x2").frame(width: 26, height: 20) }.menuStyle(.borderlessButton).frame(width: 40).help(model.L("Arrange", "Anordnen"))
                    Menu {
                        ForEach(LightTableLayout.Align.allCases, id: \.self) { a in Button(model.L("Align ", "Ausrichten ") + a.rawValue) { let b = doc; LightTableLayout.align(&doc.items, ids: selected, a); save(model.L("Align", "Ausrichten"), before: b) } }
                        Button(model.L("Distribute Horizontally", "Horizontal verteilen")) { let b = doc; LightTableLayout.distribute(&doc.items, ids: selected, horizontal: true); save("Distribute", before: b) }
                        Button(model.L("Distribute Vertically", "Vertikal verteilen")) { let b = doc; LightTableLayout.distribute(&doc.items, ids: selected, horizontal: false); save("Distribute", before: b) }
                        Divider()
                        Button(model.L("Remove from Light Table", "Vom Leuchttisch entfernen")) { let b = doc; doc.items.removeAll { selected.contains($0.id) }; selected = []; save("Remove", before: b) }.disabled(selected.isEmpty)
                        Toggle(model.L("Labels", "Etiketten"), isOn: Binding(get: { doc.showLabels }, set: { doc.showLabels = $0; save() }))
                        Toggle(model.L("Snap to Grid", "Am Raster ausrichten"), isOn: Binding(get: { doc.snapToGrid }, set: { doc.snapToGrid = $0; save() }))
                        Divider()
                        Button("PNG…") { exportTable(pdf: false) }; Button("PDF…") { exportTable(pdf: true) }
                    } label: { Image(systemName: "gearshape.fill").frame(width: 26, height: 20) }.menuStyle(.borderlessButton).frame(width: 40)
                    Spacer()
                    Slider(value: Binding(get: { doc.background }, set: { doc.background = $0 }), in: 0...1, onEditingChanged: { if !$0 { save() } }).frame(width: 50).controlSize(.mini).help(model.L("Table brightness", "Tischhelligkeit"))
                    Image(systemName: "minus.magnifyingglass").font(.system(size: 9)); Slider(value: $zoom, in: 0.2...1.5).frame(width: 90).controlSize(.mini); Image(systemName: "plus.magnifyingglass").font(.system(size: 9))
                }
            }.padding(.horizontal, 8).frame(height: 30)
        }
    }
    func rotate(_ d: Double) { let b = doc; for i in doc.items.indices where selected.contains(doc.items[i].id) { doc.items[i].rotation += d }; save("Rotate", before: b) }
    func exportTable(pdf: Bool) {
        let p = NSSavePanel(); p.allowedContentTypes = [pdf ? .pdf : .png]; p.nameFieldStringValue = container.name + (pdf ? ".pdf" : ".png")
        guard p.runModal() == .OK, let u = p.url else { return }
        let d = doc, store = model.store, size = table
        DispatchQueue.global(qos: .userInitiated).async {
            if pdf { _ = LightTableRenderer.render(d, store: store, size: size, pdf: u) }
            else if let cg = LightTableRenderer.render(d, store: store, size: size, scale: 1), let dst = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil) { CGImageDestinationAddImage(dst, cg, nil); CGImageDestinationFinalize(dst) }
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        }
    }
}

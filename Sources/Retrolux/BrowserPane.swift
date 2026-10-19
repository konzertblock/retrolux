import SwiftUI
import AppKit
import RetroluxCore

struct ThumbView: View {
    @ObservedObject var model: AppModel
    let v: Version
    let size: CGFloat
    @State private var image: NSImage?
    var body: some View {
        let px = Int(size * 2)
        ZStack {
            if let image { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
            else { Rectangle().fill(Color.black.opacity(0.25)).overlay(Image(systemName: "photo").foregroundColor(Theme.wellTextDim)) }
        }
        .frame(width: size, height: size * 0.75)
        .task(id: "\(v.id)|\(v.rotation)|\(model.thumbRevision[v.id] ?? 0)|\(px / 128)|\(v.hasAdjustments)") {
            if let m = model.store.masters[v.masterID], m.kind == .audio { image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil); return }
            image = await ThumbnailProvider.shared.image(for: v, store: model.store, px: max(128, px))
        }
    }
}

struct Cell: View {
    @ObservedObject var model: AppModel
    let v: Version
    var body: some View {
        let sel = model.selection.contains(v.id), isPrimary = model.primary == v.id
        let s = CGFloat(model.thumbSize)
        VStack(spacing: 2) {
            ZStack(alignment: .bottomLeading) {
                ThumbView(model: model, v: v, size: s - 10)
                    .overlay(alignment: .top) { if model.placesView && v.latitude != nil { Image(nsImage: PinView.image(false)).resizable().frame(width: 10, height: 19).offset(y: -10) } }
                    .overlay(Rectangle().stroke(isPrimary ? Color.white : (sel ? Theme.hex(0xBBBBBB) : Color.clear), lineWidth: isPrimary ? 2 : 1))
                if let b = model.slideBadges[v.id] { Text(b).font(Theme.font(9, bold: true)).foregroundColor(.white).padding(.horizontal, 4).padding(.vertical, 1).background(Color.black.opacity(0.75)).cornerRadius(3).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(3) }
                if model.showMetaInBrowser {
                    HStack(spacing: 2) { StarsView(rating: v.rating); Spacer()
                        if v.flagged { Image(systemName: "flag.fill").font(.system(size: 8)).foregroundColor(.orange) }
                        if v.audioAttachment != nil { Image(systemName: "speaker.wave.2.fill").font(.system(size: 8)).foregroundColor(.white) }
                        if model.store.masters[v.masterID]?.kind == .video { Image(systemName: "film").font(.system(size: 8)).foregroundColor(.white) }
                        if v.hasAdjustments { Image(systemName: "slider.horizontal.3").font(.system(size: 8)).foregroundColor(.white) }
                    }.padding(3)
                }
                if v.stackID != nil {
                    HStack(spacing: 2) { Image(systemName: model.openStacks.contains(v.stackID!) ? "square.stack.3d.up.fill" : "square.stack.3d.up").font(.system(size: 9)); Text("\(model.stackCount(v))").font(Theme.font(9, bold: true)) }
                        .foregroundColor(.white).padding(.horizontal, 4).padding(.vertical, 1).background(Color.black.opacity(0.65)).cornerRadius(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(3)
                        .onTapGesture { model.click(v.id, extend: false, toggle: false); model.toggleStack() }
                }
            }
            Text(v.name).font(Theme.tiny).foregroundColor(.white).lineLimit(1)
                .padding(.horizontal, 4).frame(width: s - 10)
                .background(v.colorLabel > 0 ? Theme.labelColors[v.colorLabel] : (sel ? Theme.selectedBar : Color.clear)).cornerRadius(3)
        }
        .frame(width: s, height: s * 0.75 + 26).contentShape(Rectangle())
        .overlay(alignment: .topTrailing) { if model.store.masters[v.masterID].map({ model.store.isMissing($0) }) == true { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor(.yellow).padding(4) } }
        .onTapGesture(count: 2) { model.click(v.id, extend: false, toggle: false); model.viewMode = .viewer }
        .onTapGesture { let f = NSEvent.modifierFlags; model.click(v.id, extend: f.contains(.shift), toggle: f.contains(.command)) }
        .onContinuousHover { phase in
            guard model.loupe else { return }
            switch phase {
            case .active(let p):
                let m = model.store.masters[v.masterID]; var w = Double(m?.width ?? 4), h = Double(m?.height ?? 3); if v.rotation % 180 != 0 { swap(&w, &h) }
                let r = CGFloat(w / max(h, 1)), fw = s - 10, fh = s * 0.75, dw = min(fw, fh * r), dh = dw / r
                let x0 = (s - dw) / 2, y0 = (fh - dh) / 2
                model.bLoupe = .init(id: v.id, frac: CGPoint(x: min(1, max(0, (p.x - x0) / dw)), y: min(1, max(0, (p.y - y0) / dh))))
                if model.bLoupeImgID != v.id { model.bLoupeImgID = v.id; Task { let img = await ThumbnailProvider.shared.image(for: v, store: model.store, px: 1400); if model.bLoupeImgID == v.id { model.bLoupeImg = img } } }
            case .ended: if model.bLoupe?.id == v.id { model.bLoupe = nil }
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(v.name + (v.rating > 0 ? ", \(v.rating) " + model.L("stars", "Sterne") : "") + (v.flagged ? ", " + model.L("flagged", "markiert") : "")).accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
        .draggable(v.id)
        .help(model.imageTooltips ? "\(v.name)\n\(v.imageDate.formatted(date: .abbreviated, time: .shortened))" : "")
        .contextMenu { CellMenu(model: model, v: v) }
    }
}

struct CellMenu: View {
    @ObservedObject var model: AppModel
    let v: Version
    func ensureSelected() { if !model.selection.contains(v.id) { model.click(v.id, extend: false, toggle: false) } }
    var body: some View {
        Menu(model.L("Rating", "Bewertung")) {
            ForEach((0...5).reversed(), id: \.self) { r in Button(r == 0 ? model.L("Unrated", "Unbewertet") : String(repeating: "★", count: r)) { ensureSelected(); model.setRating(r) } }
            Button(model.L("Rejected", "Abgelehnt")) { ensureSelected(); model.setRating(-1) }
        }
        Menu(model.L("Label", "Etikett")) { ForEach(1...7, id: \.self) { i in Button(model.labelName(i)) { ensureSelected(); model.setLabel(i) } } }
        Button(model.L("Flag", "Markieren")) { ensureSelected(); model.toggleFlag() }
        Divider()
        Button(model.L("Rotate Clockwise", "Im Uhrzeigersinn drehen")) { ensureSelected(); model.rotate(90) }
        Button(model.L("Rotate Counterclockwise", "Gegen den Uhrzeigersinn drehen")) { ensureSelected(); model.rotate(-90) }
        Divider()
        Button(model.L("Duplicate Version", "Version duplizieren")) { model.click(v.id, extend: false, toggle: false); model.duplicateVersion(fromMaster: false) }
        Button(model.L("New Version from Master", "Neue Version vom Original")) { model.click(v.id, extend: false, toggle: false); model.duplicateVersion(fromMaster: true) }
        Button(model.L("Lift Adjustments", "Anpassungen aufnehmen")) { model.click(v.id, extend: false, toggle: false); model.lift(meta: true, adj: true) }
        Button(model.L("Stamp", "Stempeln")) { ensureSelected(); model.stamp() }.disabled(model.liftedAdjustments == nil && model.liftedMeta == nil)
        Button(model.L("Reset All Adjustments", "Alle Anpassungen zurücksetzen")) { ensureSelected(); model.resetAllAdjustments() }
        Divider()
        Button(model.L("Stack", "Stapeln")) { ensureSelected(); model.stackSelection() }.disabled(model.selection.count < 2)
        if v.stackID != nil { Button(model.L("Unstack", "Stapel auflösen")) { ensureSelected(); model.unstackSelection() }; Button(model.L("Open/Close Stack", "Stapel öffnen/schließen")) { model.click(v.id, extend: false, toggle: false); model.toggleStack() }; Button(model.L("Pick", "Auswahlbild")) { model.click(v.id, extend: false, toggle: false); model.setPick() } }
        Divider()
        Button(model.L("Set Compare Item", "Vergleichsobjekt festlegen")) { model.click(v.id, extend: false, toggle: false); model.setCompare() }
        Button(model.L("Export…", "Exportieren …")) { ensureSelected(); model.showExportSheet = true }
        Button(model.L("Reveal Original in Finder", "Original im Finder zeigen")) { if let m = model.store.masters[v.masterID] { NSWorkspace.shared.activateFileViewerSelecting([model.store.masterURL(m)]) } }
        Divider()
        Button(model.L("Move to Trash", "In den Papierkorb")) { ensureSelected(); model.moveToTrash() }
    }
}

struct BrowserPane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            BrowserControls(model: model)
            Group {
                switch model.browserMode {
                case .grid: GridBrowser(model: model)
                case .filmstrip: FilmstripBrowser(model: model)
                case .list: ListBrowser(model: model)
                }
            }
            .background(model.wellColor(viewer: false))
            .modifier(BrowserLoupeLayer(model: model))
        }
        .frame(minHeight: model.viewMode == .split ? 190 : 0, idealHeight: model.viewMode == .split ? 260 : nil, maxHeight: model.viewMode == .split ? 340 : .infinity)
    }
}

/// Loupe over the Browser: magnifies the thumbnail under the pointer using a larger preview.
struct BrowserLoupeLayer: ViewModifier {
    @ObservedObject var model: AppModel
    @State private var pos: CGPoint?
    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in if case .active(let p) = phase { pos = p } else { pos = nil; model.bLoupe = nil } }
            .overlay {
                if model.loupe, let pos, let l = model.bLoupe, l.id == model.bLoupeImgID, let img = model.bLoupeImg, img.size.height > 0 {
                    let d = CGFloat(model.loupeDiameter) * 0.7, r = img.size.width / img.size.height
                    let W = CGFloat(model.thumbSize) * CGFloat(model.loupeZoom) * 2.2, H = W / r
                    ZStack { Color.black
                        Image(nsImage: img).resizable().frame(width: W, height: H).offset(x: (0.5 - l.frac.x) * W, y: (0.5 - l.frac.y) * H) }
                        .frame(width: d, height: d).clipShape(Circle()).overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 3)).shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                        .position(pos).allowsHitTesting(false)
                }
            }
    }
}

struct GridBrowser: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: CGFloat(model.thumbSize), maximum: CGFloat(model.thumbSize)), spacing: 4)], spacing: 6) {
                    ForEach(model.shown) { v in Cell(model: model, v: v).id(v.id) }
                }.padding(8)
            }
            .onChange(of: model.primary) { id in if let id { withAnimation(.none) { proxy.scrollTo(id) } } }
        }
        .overlay { if model.shown.isEmpty { Text(model.L("Drop photos here or choose File ▸ Import", "Fotos hierher ziehen oder Ablage ▸ Importieren")).font(Theme.body).foregroundColor(Theme.wellTextDim) } }
    }
}

struct FilmstripBrowser: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) { LazyHStack(spacing: 4) { ForEach(model.shown) { v in Cell(model: model, v: v).id(v.id) } }.padding(8) }
                .onChange(of: model.primary) { id in if let id { proxy.scrollTo(id) } }
        }
    }
}

struct ListBrowser: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack { Text(model.L("Name", "Name")).frame(maxWidth: .infinity, alignment: .leading); Text(model.L("Date", "Datum")).frame(width: 150, alignment: .leading); Text(model.L("Rating", "Bewertung")).frame(width: 70, alignment: .leading); Text("Size").frame(width: 80, alignment: .leading); Text("Type").frame(width: 60, alignment: .leading) }
                    .font(Theme.tiny).foregroundColor(Theme.wellTextDim).padding(.horizontal, 10).padding(.vertical, 3)
                ForEach(model.shown) { v in
                    let m = model.store.masters[v.masterID]
                    HStack {
                        HStack(spacing: 6) { Rectangle().fill(v.colorLabel > 0 ? Theme.labelColors[v.colorLabel] : Color.clear).frame(width: 4, height: 12); Text(v.name) }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(v.imageDate.formatted(date: .abbreviated, time: .shortened)).frame(width: 150, alignment: .leading)
                        HStack(spacing: 0) { StarsView(rating: v.rating); if v.flagged { Text("⚑").foregroundColor(.orange) } }.frame(width: 70, alignment: .leading)
                        Text(m.map { "\($0.width)×\($0.height)" } ?? "").frame(width: 80, alignment: .leading)
                        Text(m.map { $0.isRaw ? "RAW" : $0.kind == .image ? "JPEG" : $0.kind.rawValue } ?? "").frame(width: 60, alignment: .leading)
                    }
                    .font(Theme.small).foregroundColor(.white).padding(.horizontal, 10).padding(.vertical, 3)
                    .background(model.selection.contains(v.id) ? Theme.accent.opacity(0.7) : Color.clear).contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.click(v.id, extend: false, toggle: false); model.viewMode = .viewer }
                    .onTapGesture { let f = NSEvent.modifierFlags; model.click(v.id, extend: f.contains(.shift), toggle: f.contains(.command)) }
                }
            }
        }
    }
}

struct BrowserControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
            HStack(spacing: 6) {
                Picker("", selection: $model.sortKey) {
                    Text(model.L("Manual", "Manuell")).tag(SortKey.manual); Text(model.L("Name", "Name")).tag(SortKey.name); Text(model.L("Image Date", "Aufnahmedatum")).tag(SortKey.imageDate)
                    Text(model.L("Import Date", "Importdatum")).tag(SortKey.importDate); Text(model.L("Rating", "Bewertung")).tag(SortKey.rating); Text(model.L("File Name", "Dateiname")).tag(SortKey.fileName); Text(model.L("Label", "Etikett")).tag(SortKey.label)
                }.labelsHidden().controlSize(.small).frame(width: 130)
                Button { model.sortAscending.toggle() } label: { Image(systemName: model.sortAscending ? "arrow.up" : "arrow.down").font(.system(size: 9)) }.buttonStyle(.plain)
                Picker("", selection: $model.browserMode) {
                    Image(systemName: "rectangle.split.3x1").tag(BrowserMode.filmstrip); Image(systemName: "square.grid.2x2").tag(BrowserMode.grid); Image(systemName: "list.bullet").tag(BrowserMode.list)
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 90)
                Spacer()
                Button { model.showFilterHUD.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 13)) }.buttonStyle(.plain)
                    .popover(isPresented: $model.showFilterHUD) { FilterHUD(model: model) }
                HStack(spacing: 3) { Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundColor(.gray)
                    TextField(model.L("Unrated or Better", "Unbewertet oder besser"), text: $model.searchText).textFieldStyle(.plain).font(Theme.tiny).frame(width: 130) }
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.white).cornerRadius(9).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.4)))
            }.padding(.horizontal, 8).frame(height: 26)
        }
    }
}

struct FilterHUD: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.L("Filter", "Filter")).font(Theme.title)
            HStack { Text(model.L("Rating", "Bewertung")).frame(width: 70, alignment: .leading)
                Picker("", selection: $model.minRating) { Text(model.L("Any", "Beliebig")).tag(-2); Text(model.L("Rejected", "Abgelehnt")).tag(-1); ForEach(1...5, id: \.self) { Text("★ \($0)+").tag($0) } }.labelsHidden().frame(width: 110) }
            HStack { Text(model.L("Label", "Etikett")).frame(width: 70, alignment: .leading)
                Picker("", selection: $model.filterLabel) { Text(model.L("Any", "Beliebig")).tag(-1); ForEach(1...7, id: \.self) { Text(model.labelName($0)).tag($0) } }.labelsHidden().frame(width: 110) }
            Toggle(model.L("Flagged only", "Nur markierte"), isOn: $model.filterFlagged)
            HStack { Text(model.L("Thumbnail size", "Miniaturgröße")); Slider(value: $model.thumbSize, in: 70...320).frame(width: 110) }
            Button(model.L("Reset", "Zurücksetzen")) { model.minRating = -2; model.filterLabel = -1; model.filterFlagged = false; model.searchText = "" }.buttonStyle(AquaButtonStyle())
        }.padding(12).frame(width: 260).background(Theme.chrome)
    }
}

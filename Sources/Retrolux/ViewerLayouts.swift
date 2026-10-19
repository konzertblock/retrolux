import SwiftUI
import AppKit
import RetroluxCore

/// Tiles for Show Multiple / Three Up / Compare / Stack (rendered previews, not live edits).
struct TileView: View {
    @ObservedObject var model: AppModel
    let id: ID
    var label: String = ""
    @State private var image: NSImage?
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.25))
            if let image { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(6) }
            if !label.isEmpty { Text(label).font(Theme.tiny).foregroundColor(.white).padding(4).background(Color.black.opacity(0.6)).cornerRadius(3).padding(6) }
            if let v = model.store.versions[id] { VStack { Spacer(); HStack { Text(v.name).font(Theme.tiny).foregroundColor(.white); Spacer(); StarsView(rating: v.rating) }.padding(6) } }
        }
        .overlay(Rectangle().stroke(model.primary == id ? Color.white : Color.clear, lineWidth: 2))
        .contentShape(Rectangle()).onTapGesture { model.click(id, extend: false, toggle: false) }
        .task(id: "\(id)|\(model.thumbRevision[id] ?? 0)") { if let v = model.store.versions[id] { image = await ThumbnailProvider.shared.image(for: v, store: model.store, px: 1200) } }
    }
}

struct MultiViewer: View {
    @ObservedObject var model: AppModel
    var ids: [ID] {
        switch model.viewerLayout {
        case .multiple: return Array(model.selection.prefix(9))
        case .threeUp:
            guard let p = model.primary, let i = model.shown.firstIndex(where: { $0.id == p }) else { return [] }
            return [i - 1, i, i + 1].filter { $0 >= 0 && $0 < model.shown.count }.map { model.shown[$0].id }
        case .compare: return [model.compare, model.primary].compactMap { $0 }
        case .stack:
            guard let p = model.primaryVersion, let sid = p.stackID else { return [p0] }
            return model.store.versions.values.filter { $0.stackID == sid && !$0.trashed }.sorted { $0.imageDate < $1.imageDate }.map(\.id)
        case .one: return []
        }
    }
    var p0: ID { model.primary ?? "" }
    var body: some View {
        let list = ids
        let cols = model.viewerLayout == .multiple ? (list.count <= 1 ? 1 : (list.count <= 4 ? 2 : 3)) : max(1, list.count)
        if list.isEmpty { Text(model.L("Nothing to show", "Nichts anzuzeigen")).font(Theme.body).foregroundColor(Theme.wellTextDim) }
        else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: cols), spacing: 4) {
                ForEach(list, id: \.self) { id in
                    TileView(model: model, id: id, label: model.viewerLayout == .compare ? (id == model.compare ? model.L("Compare Item", "Vergleichsobjekt") : model.L("Selected", "Ausgewählt")) : "")
                        .frame(minHeight: 160)
                }
            }.padding(4)
        }
    }
}

struct HUDPanel<Content: View>: View {
    let title: String
    var close: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var offset = CGSize.zero
    @State private var drag = CGSize.zero
    var body: some View {
        VStack(spacing: 0) {
            HStack { Button(action: close) { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundColor(.white.opacity(0.7)) }.buttonStyle(.plain)
                Text(title).font(Theme.font(11, bold: true)).foregroundColor(.white); Spacer() }
                .padding(.horizontal, 8).frame(height: 22).background(Color.black.opacity(0.35))
            content().padding(8)
        }
        .background(Color.black.opacity(0.78)).cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25)))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
        .offset(x: offset.width + drag.width, y: offset.height + drag.height)
        .gesture(DragGesture().onChanged { drag = $0.translation }.onEnded { offset.width += $0.translation.width; offset.height += $0.translation.height; drag = .zero })
        .environment(\.colorScheme, .dark).environment(\.hudDark, true)
    }
}

struct KeywordHUD: View {
    @ObservedObject var model: AppModel
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { TextField(model.L("Keyword", "Schlagwort"), text: $text, onCommit: { model.addKeyword(text); text = "" }).textFieldStyle(.roundedBorder).frame(width: 170)
                Button("+") { model.addKeyword(text); text = "" }.buttonStyle(AquaButtonStyle(dark: true)) }
            let all = model.store.allKeywords
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), alignment: .leading)], spacing: 4) {
                ForEach(all, id: \.self) { k in
                    let on = model.selectedVersions.allSatisfy { $0.keywords.contains(k) } && !model.selection.isEmpty
                    Button { on ? model.removeKeyword(k) : model.addKeyword(k) } label: { Text(k.split(separator: "/").last.map(String.init) ?? k).font(Theme.tiny).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 2).background(on ? Theme.accent : Color.white.opacity(0.18)).cornerRadius(8).foregroundColor(.white) }.buttonStyle(.plain)
                } } }.frame(width: 260, height: 160)
        }
    }
}

struct LiftStampHUD: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.liftedSetPublic == nil && model.liftedMetaPublic == nil { Text(model.L("Nothing lifted yet. Use Lift (⇧⌘C).", "Noch nichts aufgenommen. „Aufnehmen“ (⇧⌘C) verwenden.")).font(Theme.tiny).foregroundColor(.white) }
            if let s = model.liftedSetPublic {
                Text(model.L("Adjustments", "Anpassungen")).font(Theme.font(10, bold: true)).foregroundColor(.white.opacity(0.7))
                ForEach(s.items, id: \.id) { a in
                    Toggle(isOn: Binding(get: { model.stampOptions.ops.contains(a.id) }, set: { if $0 { model.stampOptions.ops.insert(a.id) } else { model.stampOptions.ops.remove(a.id) } })) {
                        Text(Catalog.spec(a.id).map { model.lang == "de" ? $0.de : $0.en } ?? a.id).font(Theme.tiny).foregroundColor(.white) }.toggleStyle(.checkbox)
                }
                if !s.brushes.isEmpty { Toggle(model.L("Brush adjustments", "Pinselanpassungen"), isOn: $model.stampOptions.brushes).toggleStyle(.checkbox).font(Theme.tiny).foregroundColor(.white) }
            }
            if model.liftedMetaPublic != nil {
                Text(model.L("Metadata", "Metadaten")).font(Theme.font(10, bold: true)).foregroundColor(.white.opacity(0.7))
                Toggle(model.L("Rating", "Bewertung"), isOn: $model.stampOptions.rating).toggleStyle(.checkbox).font(Theme.tiny).foregroundColor(.white)
                Toggle(model.L("Label", "Etikett"), isOn: $model.stampOptions.label).toggleStyle(.checkbox).font(Theme.tiny).foregroundColor(.white)
                Toggle(model.L("Flag", "Markierung"), isOn: $model.stampOptions.flag).toggleStyle(.checkbox).font(Theme.tiny).foregroundColor(.white)
                Toggle(model.L("Keywords", "Schlagwörter"), isOn: $model.stampOptions.keywords).toggleStyle(.checkbox).font(Theme.tiny).foregroundColor(.white)
                Toggle(model.L("Caption", "Beschriftung"), isOn: $model.stampOptions.caption).toggleStyle(.checkbox).font(Theme.tiny).foregroundColor(.white)
            }
            HStack { Button(model.L("Stamp Selected", "Auf Auswahl stempeln")) { model.stampSelective() }.buttonStyle(AquaButtonStyle(dark: true)).disabled(!model.canStamp) }
        }.frame(width: 230)
    }
}

/// Floating HUD layer (Window menu: Inspector HUD, Keyword HUD, Lift & Stamp HUD).
struct HUDLayer: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear.allowsHitTesting(false)
            VStack(alignment: .trailing, spacing: 10) {
                if model.huds.contains(.inspector) { HUDPanel(title: model.L("Adjustments", "Anpassungen"), close: { model.huds.remove(.inspector) }) { AdjustmentsTab(model: model).frame(width: 292, height: 520).background(Color(white: 0.13)).cornerRadius(4) } }
                if model.huds.contains(.keyword) { HUDPanel(title: model.L("Keywords", "Schlagwörter"), close: { model.huds.remove(.keyword) }) { KeywordHUD(model: model) } }
                if model.huds.contains(.liftStamp) { HUDPanel(title: "Lift & Stamp", close: { model.huds.remove(.liftStamp) }) { LiftStampHUD(model: model) } }
            }.padding(12)
        }
    }
}

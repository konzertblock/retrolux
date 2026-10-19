import SwiftUI
import AppKit
import RetroluxCore

struct AutoStackSheet: View {
    @ObservedObject var model: AppModel
    @State private var gap = 60.0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.L("Auto-Stack", "Auto-Stapel")).font(Theme.font(14, bold: true))
            Text(model.L("Photos taken within this time of each other are stacked.", "Fotos, die innerhalb dieser Zeit nacheinander aufgenommen wurden, werden gestapelt.")).font(Theme.small)
            HStack { Slider(value: $gap, in: 1...900).frame(width: 260); Text(gap < 120 ? "\(Int(gap)) s" : String(format: "%.1f min", gap / 60)).font(Theme.small).frame(width: 64) }
            Text(model.L("\(model.autoStackPreview(gap: gap)) stacks would be created from \(model.selection.count > 1 ? model.selection.count : model.shown.count) photos", "Es würden \(model.autoStackPreview(gap: gap)) Stapel aus \(model.selection.count > 1 ? model.selection.count : model.shown.count) Fotos entstehen")).font(Theme.tiny).foregroundColor(.gray)
            HStack { Spacer(); Button(model.L("Cancel", "Abbrechen")) { model.showAutoStack = false }.buttonStyle(AquaButtonStyle())
                Button(model.L("Stack", "Stapeln")) { model.runAutoStack(gap: gap); model.showAutoStack = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 420).background(Theme.chrome)
    }
}

struct VaultsSheet: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let _ = model.configTick
        VStack(alignment: .leading, spacing: 10) {
            Text(model.L("Vaults", "Vaults")).font(Theme.font(14, bold: true))
            Text(model.L("A vault is an incremental backup of the library database and all managed originals. Referenced originals (stored outside the library) are NOT part of a vault – back them up separately.", "Ein Vault ist eine inkrementelle Sicherung der Bibliotheksdatenbank und aller verwalteten Originale. Referenzierte Originale (außerhalb der Bibliothek) gehören NICHT dazu und müssen separat gesichert werden.")).font(Theme.tiny).foregroundColor(.gray)
            let refs = model.store.masters.values.filter(\.isReference).count
            if refs > 0 { Text(model.L("\(refs) referenced originals are not covered by vaults.", "\(refs) referenzierte Originale sind von Vaults nicht abgedeckt.")).font(Theme.tiny).foregroundColor(.orange) }
            List(model.vaultManager.vaults) { v in
                let ok = model.vaultManager.isAvailable(v)
                HStack(spacing: 8) {
                    Image(systemName: ok ? "externaldrive.fill" : "externaldrive.badge.xmark").foregroundColor(ok ? .green : .red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.name).font(Theme.small); Text(v.path).font(Theme.tiny).foregroundColor(.gray).lineLimit(1).truncationMode(.middle)
                        Text(ok ? (v.lastUpdate.map { model.L("Updated ", "Aktualisiert ") + $0.formatted(date: .abbreviated, time: .shortened) } ?? model.L("Never updated", "Noch nie aktualisiert")) : model.L("Drive not connected", "Laufwerk nicht verbunden")).font(Theme.tiny).foregroundColor(ok ? .gray : .red)
                        if !v.lastResult.isEmpty { Text(v.lastResult).font(Theme.font(9)).foregroundColor(.gray).lineLimit(2) }
                    }
                    Spacer()
                    Button(model.L("Update", "Aktualisieren")) { update(v) }.buttonStyle(AquaButtonStyle()).disabled(!ok)
                    Button(model.L("Path…", "Pfad …")) { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; if p.runModal() == .OK, let u = p.url { model.vaultManager.setPath(v.id, u.path); model.configChanged() } }.buttonStyle(AquaButtonStyle())
                    Button(model.L("Remove", "Entfernen")) { model.vaultManager.remove(v.id); model.configChanged() }.buttonStyle(AquaButtonStyle())
                }.padding(.vertical, 2)
            }.frame(height: 220)
            HStack { Button(model.L("Add Vault…", "Vault hinzufügen …")) { model.addVault() }.buttonStyle(AquaButtonStyle())
                Button(model.L("Update All", "Alle aktualisieren")) { model.updateAllVaults() }.buttonStyle(AquaButtonStyle())
                Button(model.L("Restore Library…", "Bibliothek wiederherstellen …")) { model.restoreLibrary() }.buttonStyle(AquaButtonStyle()); Spacer()
                Button("OK") { model.showVaults = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
            if let p = model.progress { ProgressView(value: p) }
        }.padding(16).frame(width: 600).background(Theme.chrome)
    }
    func update(_ v: Vault) {
        model.progress = 0
        DispatchQueue.global(qos: .utility).async {
            let r = Result { try model.vaultManager.update(v.id, library: model.store) { i, n in DispatchQueue.main.async { model.progress = n > 0 ? Double(i) / Double(n) : 1 } } }
            DispatchQueue.main.async { model.progress = nil; model.configChanged(); if case .failure(let e) = r { model.alert = ("Vault", e.localizedDescription) } }
        }
    }
}

struct FirstAidSheet: View {
    @ObservedObject var model: AppModel
    @State private var report = ""
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.L("Library First Aid", "Bibliothek-Erste-Hilfe")).font(Theme.font(14, bold: true))
            Text(model.L("Check looks for orphaned items, broken folders, offline originals and (optionally) changed original files. Repair first saves a copy of the database next to the library, then removes orphans and rebuilds indexes and thumbnails.", "Prüfen sucht nach verwaisten Objekten, defekten Ordnern, fehlenden Originalen und (optional) veränderten Originaldateien. Reparieren legt zuerst eine Kopie der Datenbank neben der Bibliothek ab und entfernt dann Verwaistes, baut Indizes und Miniaturen neu auf.")).font(Theme.tiny).foregroundColor(.gray)
            ScrollView { Text(report.isEmpty ? model.L("No report yet.", "Noch kein Bericht.") : report).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(width: 540, height: 200).background(Color.white).overlay(Rectangle().stroke(Color.black.opacity(0.4)))
            HStack {
                Button(model.L("Check", "Prüfen")) { run { model.store.checkIntegrity().text } }.buttonStyle(AquaButtonStyle())
                Button(model.L("Check + Verify Originals", "Prüfen + Originale verifizieren")) { run { model.store.checkIntegrity(verifyChecksums: true).text } }.buttonStyle(AquaButtonStyle())
                Button(model.L("Repair", "Reparieren")) { run { (try? model.store.repair().text) ?? "Repair failed" } }.buttonStyle(AquaButtonStyle())
                Button(model.L("Rebuild Thumbnails", "Miniaturen neu aufbauen")) { model.regenerateThumbnails(); report += "\nThumbnail cache cleared." }.buttonStyle(AquaButtonStyle())
                Spacer(); if busy { ProgressView().controlSize(.small) }
                Button("OK") { model.showFirstAid = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 580).background(Theme.chrome)
    }
    func run(_ f: @escaping () -> String) { busy = true; DispatchQueue.global().async { let t = f(); DispatchQueue.main.async { report = t; busy = false; model.reloadVersions(); model.log("First Aid: " + (t.split(separator: "\n").first.map(String.init) ?? "")) } } }
}

struct MergeProjectsSheet: View {
    @ObservedObject var model: AppModel
    @State private var sources: Set<ID> = []
    @State private var target: ID?
    var projects: [Container] { model.store.containers.values.filter { $0.kind == .project }.sorted { $0.name < $1.name } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.L("Merge Projects", "Projekte zusammenführen")).font(Theme.font(14, bold: true))
            Picker(model.L("Merge into", "Zusammenführen in"), selection: $target) { Text("—").tag(ID?.none); ForEach(projects) { Text($0.name).tag(ID?.some($0.id)) } }
            Text(model.L("Projects to merge (they disappear afterwards):", "Zu verschmelzende Projekte (verschwinden danach):")).font(Theme.tiny)
            List(projects) { p in Toggle(p.name, isOn: Binding(get: { sources.contains(p.id) }, set: { if $0 { sources.insert(p.id) } else { sources.remove(p.id) } })).toggleStyle(.checkbox).font(Theme.small).disabled(p.id == target) }.frame(height: 200)
            HStack { Spacer(); Button(model.L("Cancel", "Abbrechen")) { model.showMergeProjects = false }.buttonStyle(AquaButtonStyle())
                Button(model.L("Merge", "Zusammenführen")) { if let t = target { try? LibraryMerge.mergeProjects(Array(sources), into: t, store: model.store); model.source = .container(t) }; model.showMergeProjects = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction).disabled(target == nil || sources.isEmpty) }
        }.padding(16).frame(width: 420).background(Theme.chrome)
        .onAppear { if case .container(let id) = model.source, model.store.containers[id]?.kind == .project { sources = [id] } }
    }
}

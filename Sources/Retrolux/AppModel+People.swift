import SwiftUI
import AppKit
import MapKit
import CoreLocation
import RetroluxCore

extension AppModel {
    var analyzer: FaceAnalyzer { let a = FaceAnalyzer(store: store); a.threshold = faceThreshold; return a }
    var peopleList: [Person] { _ = facesTick; return store.people() }
    func faceTick() { facesTick += 1; objectWillChange.send() }

    // MARK: background analysis (local, low priority, pausable –)
    func startFaceAnalysis() {
        guard facesEnabled, !facesPaused, !facesAnalyzing else { return }
        let todo = store.mastersNeedingFaceAnalysis().compactMap { m in store.versions.values.first { $0.masterID == m.id && !$0.trashed }?.id }
        guard !todo.isEmpty else { return }
        facesAnalyzing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var n = 0
            for vid in todo {
                if !self.facesEnabled || self.facesPaused { break }
                _ = try? self.analyzer.analyze(version: vid); n += 1
                if n % 10 == 0 { DispatchQueue.main.async { self.status = self.L("Analyzing faces… \(n)/\(todo.count)", "Analysiere Gesichter … \(n)/\(todo.count)"); self.faceTick() } }
            }
            _ = try? self.analyzer.suggestAll()
            DispatchQueue.main.async { self.facesAnalyzing = false; self.faceTick(); self.log("Face analysis: \(n) photos") }
        }
    }
    func setFacesEnabled(_ on: Bool) { facesEnabled = on; UserDefaults.standard.set(on, forKey: "facesEnabled"); if on { startFaceAnalysis() } }
    func detectMissingFaces() {
        let ids = selection.isEmpty ? shown.map(\.id) : selection
        facesAnalyzing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var n = 0; for id in ids { n += (try? self.analyzer.analyze(version: id)) ?? 0 }
            _ = try? self.analyzer.suggestAll()
            DispatchQueue.main.async { self.facesAnalyzing = false; self.faceTick(); self.status = self.L("\(n) new faces found", "\(n) neue Gesichter gefunden") }
        }
    }
    func deleteFaceData() {
        let a = NSAlert(); a.alertStyle = .warning; a.messageText = L("Delete all face data?", "Alle Gesichtsdaten löschen?")
        a.informativeText = L("People, names and detected faces are removed from this library. Photos are not touched.", "Personen, Namen und erkannte Gesichter werden aus dieser Bibliothek entfernt. Die Fotos bleiben unverändert.")
        a.addButton(withTitle: L("Delete", "Löschen")).hasDestructiveAction = true; a.addButton(withTitle: L("Cancel", "Abbrechen"))
        if a.runModal() == .alertFirstButtonReturn { try? store.deleteAllFaceData(); if case .person = source { source = .all }; faceTick(); status = L("Face data deleted", "Gesichtsdaten gelöscht") }
    }
    func setFaceThreshold(_ t: Double) { faceThreshold = t; UserDefaults.standard.set(t, forKey: "faceThreshold") }
    func resuggest() { _ = try? analyzer.suggestAll(); faceTick() }

    func nameFace(_ face: ID, as name: String) {
        let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty, let p = try? store.createPerson(n) else { return }
        try? store.nameFace(face, person: p.id); resuggest(); namingFace = nil
    }
    func nameFaces(_ ids: [ID], as name: String) { for i in ids { nameFace(i, as: name) } }

    /// Face rectangle (fractions of the rotated, uncropped image) → fractions of what the viewer shows (cropped).
    func faceRectInView(_ f: Face) -> CGRect? {
        guard let m = primaryMaster else { return f.rect }
        var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let c = adjustments.item(Catalog.crop), c.enabled, m.width > 0 {
            crop = displayRect(master: CGRect(x: c.value("inputXOrigin") / Double(m.width), y: c.value("inputYOrigin") / Double(m.height), width: c.value("inputWidth") / Double(m.width), height: c.value("inputHeight") / Double(m.height)))
        }
        let r = CGRect(x: (f.rect.minX - crop.minX) / crop.width, y: (f.rect.minY - crop.minY) / crop.height, width: f.rect.width / crop.width, height: f.rect.height / crop.height)
        return r.intersects(CGRect(x: 0, y: 0, width: 1, height: 1)) ? r : nil
    }
    func rectFromView(_ r: CGRect) -> CGRect {
        guard let m = primaryMaster else { return r }
        var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let c = adjustments.item(Catalog.crop), c.enabled, m.width > 0 { crop = displayRect(master: CGRect(x: c.value("inputXOrigin") / Double(m.width), y: c.value("inputYOrigin") / Double(m.height), width: c.value("inputWidth") / Double(m.width), height: c.value("inputHeight") / Double(m.height))) }
        return CGRect(x: crop.minX + r.minX * crop.width, y: crop.minY + r.minY * crop.height, width: r.width * crop.width, height: r.height * crop.height)
    }
    func addManualFace(viewRect: CGRect) {
        guard let id = primary else { return }
        let r = rectFromView(viewRect)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let f = try? self.analyzer.addManualFace(version: id, rect: r)
            DispatchQueue.main.async { self.faceTick(); if let f { self.namingFace = f.id } }
        }
    }
    func faceBoxes() -> [FaceBox] {
        guard namingMode, let id = primary else { return [] }
        _ = facesTick
        let people = Dictionary(uniqueKeysWithValues: store.people().map { ($0.id, $0.name) })
        return store.faces(of: id).compactMap { f in
            guard let r = faceRectInView(f) else { return nil }
            let label = f.personID.flatMap { people[$0] } ?? f.suggestedID.flatMap { people[$0].map { "\($0)?" } } ?? ""
            return FaceBox(id: f.id, rect: r, label: label, confirmed: f.confirmed, suggested: f.suggestedID != nil && !f.confirmed)
        }
    }

    // MARK: places
    var tracksDir: URL { store.root.appendingPathComponent("Tracks", isDirectory: true) }
    func loadTracks() {
        guard gpsTracks.isEmpty, let files = try? FileManager.default.contentsOfDirectory(at: tracksDir, includingPropertiesForKeys: nil) else { return }
        gpsTracks = files.filter { $0.pathExtension == "gpx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { u in (try? Data(contentsOf: u)).map { GPSTrack(name: u.deletingPathExtension().lastPathComponent, points: GPX.parse($0)) } }.filter { !$0.points.isEmpty }
    }
    func addTrack(name: String, data: Data) {
        try? FileManager.default.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        try? data.write(to: tracksDir.appendingPathComponent(name.hasSuffix(".gpx") ? name : name + ".gpx"))
        let pts = GPX.parse(data); if !pts.isEmpty { gpsTracks.append(GPSTrack(name: name, points: pts)) }
    }
    func moveLocation(of id: ID, lat: Double, lon: Double) {
        guard let before = store.versions[id] else { return }
        try? store.assignLocation([id], lat: lat, lon: lon)
        pushUndo(L("Move Pin", "Pin bewegen"), undo: { [weak self] in try? self?.store.update([id]) { $0 = before } }, redo: { [weak self] in try? self?.store.assignLocation([id], lat: lat, lon: lon) })
    }
    func assignLocation(lat: Double, lon: Double, names: [String: String] = [:]) {
        let ids = selection; guard !ids.isEmpty else { return }
        let before = ids.compactMap { store.versions[$0] }
        try? store.assignLocation(ids, lat: lat, lon: lon, names: names)
        pushUndo(L("Assign Location", "Ort zuweisen"), undo: { [weak self] in let m = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) }); try? self?.store.update(Array(m.keys)) { $0 = m[$0.id] ?? $0 } }, redo: { [weak self] in try? self?.store.assignLocation(ids, lat: lat, lon: lon, names: names) })
        status = L("Location assigned to \(ids.count) photos", "Ort \(ids.count) Fotos zugewiesen")
        if names.isEmpty && looksUpPlacesAutomatically { updatePlaceNames(ids: ids, quiet: true) }
    }
    func removeLocations() {
        let ids = selection; guard !ids.isEmpty else { return }
        let before = ids.compactMap { store.versions[$0] }
        try? store.removeLocations(ids)
        pushUndo(L("Remove Locations", "Orte entfernen"), undo: { [weak self] in let m = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) }); try? self?.store.update(Array(m.keys)) { $0 = m[$0.id] ?? $0 } }, redo: { [weak self] in try? self?.store.removeLocations(ids) })
    }
    func useLocationOfPrimary() { if let v = primaryVersion, let la = v.latitude, let lo = v.longitude { assignLocation(lat: la, lon: lo, names: ["place.country": v.meta["place.country"] ?? "", "place.state": v.meta["place.state"] ?? "", "place.city": v.meta["place.city"] ?? "", "place.name": v.meta["place.name"] ?? ""]) } }
    /// Reverse geocoding (network). A failure only means "no name"; coordinates are never changed or deleted.
    /// Preferences ▸ Advanced ▸ Look up Places: Automatically (default) or Never.
    var looksUpPlacesAutomatically: Bool { UserDefaults.standard.integer(forKey: "lookUpPlaces") == 0 }
    func updatePlaceNames(ids: [ID]? = nil, quiet: Bool = false) {
        let vs = (ids ?? (selection.isEmpty ? shown.map(\.id) : selection)).compactMap { store.versions[$0] }.filter { $0.latitude != nil && $0.meta["place.country"] == nil }
        guard !vs.isEmpty else { if !quiet { status = L("All selected photos already have place names", "Alle gewählten Fotos haben schon Ortsnamen") }; return }
        progress = 0
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var cache: [String: [String: String]] = [:]; var ok = 0, fail = 0
            for (i, v) in vs.enumerated() {
                let key = String(format: "%.2f,%.2f", v.latitude!, v.longitude!)
                var names = cache[key]
                if names == nil {
                    let sem = DispatchSemaphore(value: 0)
                    CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: v.latitude!, longitude: v.longitude!)) { marks, _ in
                        if let p = marks?.first { names = ["place.country": p.country ?? "", "place.state": p.administrativeArea ?? "", "place.city": p.locality ?? "", "place.name": p.name ?? ""] }
                        sem.signal()
                    }
                    _ = sem.wait(timeout: .now() + 10); Thread.sleep(forTimeInterval: 1.1)      // geocoder rate limit
                    if let n = names { cache[key] = n }
                }
                if let n = names { try? self.store.update([v.id]) { for (k, x) in n where !x.isEmpty { $0.meta[k] = x } }; ok += 1 } else { fail += 1 }
                DispatchQueue.main.async { self.progress = Double(i + 1) / Double(vs.count) }
            }
            DispatchQueue.main.async { self.progress = nil; self.status = self.L("Place names: \(ok) found, \(fail) unavailable (offline or no result – coordinates unchanged)", "Ortsnamen: \(ok) gefunden, \(fail) nicht verfügbar (offline oder ohne Ergebnis – Koordinaten unverändert)") }
        }
    }
}

struct FaceBox: Identifiable { let id: ID; let rect: CGRect; let label: String; let confirmed: Bool; let suggested: Bool }

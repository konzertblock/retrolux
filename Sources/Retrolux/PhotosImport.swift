import Foundation
import Photos
import RetroluxCore

/// Imports the Apple Photos library through PhotoKit (the supported way; the .photoslibrary package is protected).
/// Originals are copied into the Retrolux library (managed). Favorites become flags; user albums become albums.
final class PhotosImporter {
    let store: LibraryStore
    var cancelled = false
    init(store: LibraryStore) { self.store = store }

    static func authorize(_ done: @escaping (Bool) -> Void) {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if s == .authorized || s == .limited { done(true); return }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { done($0 == .authorized || $0 == .limited) }
    }

    struct Result { var imported = 0; var failed: [String] = []; var albums = 0; var total = 0; var projectID: ID? }

    func run(progress: @escaping (Int, Int) -> Void) throws -> Result {
        var res = Result()
        let opts = PHFetchOptions(); opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: .image, options: opts)
        res.total = assets.count
        let project = try store.addContainer(Container(kind: .project, name: "Photos Library", parentID: nil))
        res.projectID = project.id
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rl-photos-\(getpid())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var idMap: [String: ID] = [:]                  // PHAsset.localIdentifier → version id
        var o = ImportOptions(); o.projectID = project.id; o.managed = true; o.skipDuplicates = true
        for i in 0..<assets.count {
            if cancelled { break }
            progress(i, assets.count)
            let a = assets.object(at: i)
            let resources = PHAssetResource.assetResources(for: a)
            guard let r = resources.first(where: { $0.type == .photo }) ?? resources.first(where: { $0.type == .alternatePhoto }) ?? resources.first else { res.failed.append(a.localIdentifier); continue }
            let dst = tmp.appendingPathComponent(r.originalFilename)
            try? FileManager.default.removeItem(at: dst)
            let sem = DispatchSemaphore(value: 0); var err: Error?
            let ro = PHAssetResourceRequestOptions(); ro.isNetworkAccessAllowed = false
            PHAssetResourceManager.default().writeData(for: r, toFile: dst, options: ro) { e in err = e; sem.signal() }
            sem.wait()
            if let err { res.failed.append("\(r.originalFilename): \(err.localizedDescription)"); continue }
            let imp = Importer(store: store)
            let rep = try imp.importFiles([dst], options: o)
            try? FileManager.default.removeItem(at: dst)
            guard let vid = imp.importedVersions.first else { if !rep.duplicates.isEmpty { continue }; res.failed.append(r.originalFilename); continue }
            idMap[a.localIdentifier] = vid
            let fav = a.isFavorite, date = a.creationDate, loc = a.location?.coordinate, hidden = a.isHidden
            try store.update([vid]) { v in
                if fav { v.flagged = true; v.rating = max(v.rating, 0) }
                if let date { v.imageDate = date }
                if let loc { v.latitude = loc.latitude; v.longitude = loc.longitude }
                v.hidden = hidden
            }
            res.imported += 1
        }
        progress(assets.count, assets.count)
        // user albums
        let cols = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        cols.enumerateObjects { c, _, _ in
            let members = PHAsset.fetchAssets(in: c, options: nil)
            var ids: [ID] = []
            members.enumerateObjects { a, _, _ in if let v = idMap[a.localIdentifier] { ids.append(v) } }
            guard !ids.isEmpty, let album = try? self.store.addContainer(Container(kind: .album, name: c.localizedTitle ?? "Album", parentID: nil)) else { return }
            try? self.store.addToAlbum(album.id, ids); res.albums += 1
        }
        return res
    }
}

extension AppModel {
    func runPhotosImport() {
        progress = 0; status = L("Requesting access to the Photos library…", "Zugriff auf die Fotos-Mediathek wird angefragt …")
        PhotosImporter.authorize { [weak self] ok in
            guard let self else { return }
            guard ok else {
                DispatchQueue.main.async {
                    self.progress = nil
                    self.alert = (self.L("Photos library", "Fotos-Mediathek"), self.L("Access was not granted. Allow Retrolux under System Settings ▸ Privacy & Security ▸ Photos, then try again.", "Zugriff wurde nicht erlaubt. Erlaube Retrolux unter Systemeinstellungen ▸ Datenschutz & Sicherheit ▸ Fotos und versuche es erneut."))
                }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let r = try PhotosImporter(store: self.store).run { i, n in DispatchQueue.main.async { self.progress = n > 0 ? Double(i) / Double(n) : 1; self.status = self.L("Importing Photos library \(i)/\(n)…", "Importiere Fotos-Mediathek \(i)/\(n) …") } }
                    DispatchQueue.main.async {
                        self.progress = nil
                        self.status = self.L("\(r.imported) of \(r.total) photos imported, \(r.albums) albums", "\(r.imported) von \(r.total) Fotos importiert, \(r.albums) Alben")
                        if let p = r.projectID { self.source = .container(p) }
                        if !r.failed.isEmpty { self.alert = (self.L("Photos library", "Fotos-Mediathek"), r.failed.prefix(10).joined(separator: "\n")) }
                    }
                } catch { DispatchQueue.main.async { self.progress = nil; self.alert = ("Photos", error.localizedDescription) } }
            }
        }
    }
}

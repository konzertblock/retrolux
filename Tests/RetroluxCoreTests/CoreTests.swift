import XCTest
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import PDFKit
@testable import RetroluxCore

final class CoreTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rl-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    @discardableResult func makeJPEG(_ name: String, w: Int = 120, h: Int = 80, gray: CGFloat = 0.4) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [gray, gray * 0.9, gray * 0.8, 1])!); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.9, 0.2, 0.2, 1])!); ctx.fill(CGRect(x: 10, y: 10, width: 30, height: 30))
        let url = tmp.appendingPathComponent(name)
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(d))
        return url
    }
    func store() throws -> LibraryStore { try LibraryStore(root: tmp.appendingPathComponent("Lib.retrolux")) }
    func mean(_ cg: CGImage) -> Double {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var s = 0.0; for i in stride(from: 0, to: px.count, by: 4) { s += Double(px[i]) + Double(px[i+1]) + Double(px[i+2]) }
        return s / Double(w * h * 3)
    }

    // MARK: catalog 
    func testCatalogRanges() {
        let e = Catalog.spec(Catalog.exposure)!
        XCTAssertEqual(e.param("inputEV")?.min, -9.99); XCTAssertEqual(e.param("inputRecoveryEV")?.max, 1.5); XCTAssertEqual(e.param("inputBias")?.max, 50)
        XCTAssertEqual(Catalog.spec(Catalog.enhance)?.param("inputSaturation")?.def, 1)
        XCTAssertEqual(Catalog.brushes.count, 14)           // + Retouch = 15 Quick Brushes
        XCTAssertEqual(Catalog.canonicalID("sepiaTone"), Catalog.sepia)
    }

    // MARK: store
    func testStoreRoundTripAndAdjustments() throws {
        let s = try store()
        let p = try s.addContainer(Container(kind: .project, name: "P", parentID: nil))
        let m = Master(projectID: p.id, path: "/x.jpg", isReference: true, isRaw: false, originalName: "x.jpg")
        var v = Version(masterID: m.id, projectID: p.id, name: "x"); v.rating = 4; v.keywords = ["a/b"]
        try s.insert(master: m, version: v)
        var set = AdjustmentSet(); set.upsert(Adjustment(id: Catalog.exposure, params: ["inputEV": 1.5]))
        set.brushes.append(BrushAdjustment(op: "dodge", strokes: [Stroke(points: [[5, 5]], radius: 9)]))
        try s.setAdjustments(v.id, set)
        let s2 = try LibraryStore(root: s.root)
        XCTAssertEqual(s2.versions[v.id]?.rating, 4); XCTAssertEqual(s2.versions[v.id]?.keywords, ["a/b"]); XCTAssertTrue(s2.versions[v.id]?.hasAdjustments ?? false)
        XCTAssertEqual(s2.adjustments(for: v.id).item(Catalog.exposure)?.params["inputEV"], 1.5)
        XCTAssertEqual(s2.adjustments(for: v.id).brushes.first?.strokes.first?.radius, 9)
    }
    func testTrashAndSmartAlbum() throws {
        let s = try store()
        let p = try s.addContainer(Container(kind: .project, name: "P", parentID: nil))
        var items: [(Master, Version)] = []
        for i in 0..<5 { let m = Master(projectID: p.id, path: "/\(i).jpg", isReference: true, isRaw: false, originalName: "\(i).jpg"); var v = Version(masterID: m.id, projectID: p.id, name: "n\(i)"); v.rating = i; items.append((m, v)) }
        try s.insertBatch(items)
        let smart = try s.addContainer(Container(kind: .smartAlbum, name: "4+", parentID: nil, query: SmartQuery(rules: [SmartRule(.rating, .atLeast, "3")])))
        XCTAssertEqual(s.versions(in: smart.id).count, 2)
        try s.trash([items[4].1.id]); XCTAssertEqual(s.versions(in: smart.id).count, 1)
        try s.emptyTrash(); XCTAssertNil(s.versions[items[4].1.id]); XCTAssertNil(s.masters[items[4].0.id])
        XCTAssertEqual(s.versions(in: p.id).count, 4)
    }
    func testNoContainerCycles() throws {
        let s = try store()
        let a = try s.addContainer(Container(kind: .folder, name: "a", parentID: nil)), b = try s.addContainer(Container(kind: .folder, name: "b", parentID: a.id))
        try s.moveContainer(a.id, to: b.id); XCTAssertNil(s.containers[a.id]?.parentID)
    }

    // MARK: import ( originals unchanged)
    func testManagedImportKeepsChecksumAndSkipsDuplicates() throws {
        let src = tmp.appendingPathComponent("src"); try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let a = try makeJPEG("src/a.jpg"), _ = try makeJPEG("src/b.jpg", gray: 0.5)
        try FileManager.default.copyItem(at: a, to: src.appendingPathComponent("a-copy.jpg"))
        let before = try Importer.sha256(of: a)
        let s = try store(); let imp = Importer(store: s)
        let rep = try imp.importFiles([src], options: ImportOptions())
        XCTAssertEqual(rep.imported, 2); XCTAssertEqual(rep.duplicates.count, 1)
        XCTAssertEqual(try Importer.sha256(of: a), before)
        for m in s.masters.values { XCTAssertEqual(try Importer.sha256(of: s.masterURL(m)), m.checksum); XCTAssertFalse(m.isReference); XCTAssertEqual(m.width, 120) }
    }
    func testRawJPEGCompanionKeepsOtherFileOfPair() throws {
        let src = tmp.appendingPathComponent("pc"); try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try makeJPEG("pc/z.jpg"); try Data(repeating: 7, count: 100).write(to: src.appendingPathComponent("z.nef"))
        var o = ImportOptions(); o.rawJPEG = .bothJPEGMaster
        let s = try store(); let rep = try Importer(store: s).importFiles([src], options: o)
        XCTAssertEqual(rep.imported, 1)
        let v = try XCTUnwrap(s.versions.values.first); let m = try XCTUnwrap(s.masters[v.masterID])
        XCTAssertFalse(m.isRaw)
        let c = try XCTUnwrap(s.companionURL(for: v)); XCTAssertEqual(c.pathExtension, "nef"); XCTAssertTrue(FileManager.default.fileExists(atPath: c.path))
        let out = tmp.appendingPathComponent("orig-out"); let res = try Exporter(store: s).exportOriginals([v.id], to: out)
        XCTAssertEqual(res.written.count, 2)
    }
    func testRawJPEGModes() throws {
        let src = tmp.appendingPathComponent("p"); try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try makeJPEG("p/x.jpg"); try Data(repeating: 1, count: 100).write(to: src.appendingPathComponent("x.nef")); try makeJPEG("p/y.jpg", gray: 0.7)
        var o = ImportOptions(); o.rawJPEG = .jpegOnly; o.managed = false
        let s = try store(); let rep = try Importer(store: s).importFiles([src], options: o)
        XCTAssertEqual(rep.imported, 2)    // x.jpg + y.jpg; x.nef dropped
    }

    // MARK: render
    func testExposureDoublesBrightness() throws {
        let u = try makeJPEG("e.jpg", gray: 0.2)
        var set = AdjustmentSet(); set.upsert(Adjustment(id: Catalog.exposure, params: ["inputEV": 0]))
        let base = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: CGSize(width: 120, height: 80)))!
        set.upsert(Adjustment(id: Catalog.exposure, params: ["inputEV": 1]))
        let bright = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: CGSize(width: 120, height: 80), adjustments: set))!
        XCTAssertGreaterThan(mean(bright), mean(base) + 8)  // evScale is calibrated (0.6) against reference renderings, so +1 EV is < one full stop
    }
    func testDefaultAdjustmentsAreIdentity() throws {
        let u = try makeJPEG("d.jpg"); var set = AdjustmentSet()
        for op in Catalog.ops where op.kind == .global && !op.alwaysApplies && op.id != Catalog.crop && op.id != Catalog.wb { set.upsert(Adjustment(id: op.id, params: op.defaults)) }
        let a = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: CGSize(width: 120, height: 80)))!
        let b = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: CGSize(width: 120, height: 80), adjustments: set))!
        XCTAssertEqual(mean(a), mean(b), accuracy: 0.6)
    }
    func testCropRotateAndBlackWhite() throws {
        let u = try makeJPEG("c.jpg")
        var set = AdjustmentSet(); set.upsert(Adjustment(id: Catalog.crop, params: ["inputXOrigin": 10, "inputYOrigin": 10, "inputWidth": 60, "inputHeight": 40]))
        let cg = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: CGSize(width: 120, height: 80), rotation: 90, adjustments: set))!
        XCTAssertEqual(cg.width, 40); XCTAssertEqual(cg.height, 60)
        var bw = AdjustmentSet(); bw.upsert(Adjustment(id: Catalog.mono, params: Catalog.spec(Catalog.mono)!.defaults))
        let g = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: CGSize(width: 120, height: 80), adjustments: bw))!
        var px = [UInt8](repeating: 0, count: 4)
        CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(g, in: CGRect(x: -60, y: -40, width: 120, height: 80))
        XCTAssertEqual(Int(px[0]), Int(px[1]), accuracy: 3)
    }
    func testBrushOnlyAffectsStrokedArea() throws {
        let u = try makeJPEG("b.jpg", gray: 0.3)
        var set = AdjustmentSet(); set.brushes.append(BrushAdjustment(op: "dodge", params: ["inputExposure": 1], strokes: [Stroke(points: [[100, 40]], radius: 8, softness: 0.1)]))
        let size = CGSize(width: 120, height: 80)
        let base = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: size))!
        let out = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: size, adjustments: set))!
        func px(_ g: CGImage, _ x: Int, _ y: Int) -> Int {   // y from top
            var p = [UInt8](repeating: 0, count: 4)
            CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(g, in: CGRect(x: -x, y: -(g.height - 1 - y), width: g.width, height: g.height)); return Int(p[0])
        }
        XCTAssertGreaterThan(px(out, 100, 40), px(base, 100, 40) + 20)
        XCTAssertEqual(px(out, 20, 70), px(base, 20, 70), accuracy: 2)
    }
    func testLevelsLUT() {
        var a = Adjustment(id: Catalog.levels, params: ["inputBlackSrcRGB": 0.2])
        a.enabled = true
        let f = ColorLUT.levelsFunc(a, channel: "RGB")!
        XCTAssertEqual(f(0.1), 0, accuracy: 1e-9); XCTAssertEqual(f(1), 1, accuracy: 1e-9)
        XCTAssertNotNil(ColorLUT.cube(levels: a, curves: nil, color: nil))
        XCTAssertNil(ColorLUT.cube(levels: nil, curves: nil, color: nil))
    }
    func testCurveInterpolation() {
        let f = ColorLUT.curveFunc([CurvePoint(x: 0, y: 0, editable: false), CurvePoint(x: 0, y: 0, editable: false), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1, editable: false), CurvePoint(x: 5, y: 1, editable: false)])!
        XCTAssertEqual(f(0.5), 0.7, accuracy: 1e-9); XCTAssertEqual(f(0), 0, accuracy: 1e-9); XCTAssertGreaterThan(f(0.25), 0.25)
    }

    // MARK: export
    func testPresetBoxSizeAndCoding() throws {
        var p = ExportPreset(name: "t", format: .tiff, size: .box(width: 8, height: 4, unit: .inches), deep: true); p.dpi = 300
        XCTAssertEqual(p.maxPixel(for: CGSize(width: 6000, height: 4000)), 1800)   // box 2400×1200 px: height limits (0.3 × 6000)
        XCTAssertNil(ExportPreset.factory[6].maxPixel(for: CGSize(width: 10, height: 10)))
        let back = try JSONDecoder().decode(ExportPreset.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }
    func testBookMapItemKeepsPlacesAndStaysBackwardCompatible() throws {
        var m = BookItem(kind: .map, x: 0, y: 0, w: 1, h: 1); m.mapTitle = "Berlin"; m.zoom = 2; m.mapPlaces = [MapPlace(name: "Tor", latitude: 52.5, longitude: 13.4)]
        let back = try JSONDecoder().decode(BookItem.self, from: JSONEncoder().encode(m)); XCTAssertEqual(back, m)
        let old = #"{"id":"a","kind":"map","x":0,"y":0,"w":1,"h":1,"text":"/x.png","fontSize":14,"align":"center","cropX":0.5,"cropY":0.5,"zoom":1}"#   // saved before the Map Options HUD
        let o = try JSONDecoder().decode(BookItem.self, from: Data(old.utf8)); XCTAssertNil(o.mapPlaces); XCTAssertNil(o.mapTitle)
    }
    func testNamingAndSubfolderPolicies() {
        var c = DateComponents(); c.year = 2010; c.month = 3; c.day = 24; c.hour = 15; c.minute = 39; c.second = 49
        let v = Version(masterID: "m", projectID: "p", name: "LA 031", imageDate: Calendar.current.date(from: c)!)
        XCTAssertEqual(NamingPolicy.versionNameSequence.fileName(version: v, index: 2, count: 3, custom: ""), "LA 031 2 of 3")
        XCTAssertEqual(NamingPolicy.customCounter.fileName(version: v, index: 7, count: 9, custom: "Trip"), "Trip 007")
        XCTAssertEqual(NamingPolicy.customIndexNoSpaces.fileName(version: v, index: 4, count: 9, custom: "LA"), "LA4")
        XCTAssertEqual(NamingPolicy.versionNameDate.fileName(version: v, index: 1, count: 1, custom: ""), "LA 031 - 2010-03-24 at 15.39.49")
        XCTAssertEqual(SubfolderPolicy.imageYearMonthDay.path(version: v, index: 1, custom: ""), "2010/03/24")
        XCTAssertNil(SubfolderPolicy.none.path(version: v, index: 1, custom: ""))
    }
    func testExportPresetCountAndNoOverwrite() throws {
        XCTAssertEqual(ExportPreset.factory.count, 17)
        let u = try makeJPEG("x.jpg"); let s = try store(); _ = try Importer(store: s).importFiles([u], options: { var o = ImportOptions(); o.managed = false; return o }())
        let ids = Array(s.versions.keys); let out = tmp.appendingPathComponent("out")
        let ex = Exporter(store: s)
        let r1 = try ex.export(ids, preset: ExportPreset.factory[6], to: out); let r2 = try ex.export(ids, preset: ExportPreset.factory[6], to: out)
        XCTAssertEqual(r1.written.count, 1); XCTAssertEqual(r2.written.count, 1); XCTAssertNotEqual(r1.written[0], r2.written[0])
        let t = try ex.export(ids, preset: ExportPreset.factory[14], to: out)      // TIFF fit 1024
        XCTAssertEqual(t.written.first?.pathExtension, "tif")
    }

    // MARK: legacy library migration (reads a synthetic mini library, never writes it)
    func testLegacyMigrationOnSyntheticLibrary() throws {
        let lib = tmp.appendingPathComponent("A.aplibrary"); try FileManager.default.createDirectory(at: lib.appendingPathComponent("Database"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("Masters/2010"), withIntermediateDirectories: true)
        let jpg = try makeJPEG("m.jpg"); try FileManager.default.copyItem(at: jpg, to: lib.appendingPathComponent("Masters/2010/m.jpg"))
        let db = try SQLiteDB(path: lib.appendingPathComponent("Database/Library.apdb").path)
        try db.exec("""
        CREATE TABLE RKFolder(modelId integer primary key, uuid varchar, folderType integer, name varchar, parentFolderUuid varchar, folderPath varchar);
        CREATE TABLE RKMaster(modelId integer primary key, uuid varchar, projectUuid varchar, imagePath varchar, fileIsReference integer, isTrulyRaw integer, type varchar, fileSize integer, fileName varchar, imageDate real);
        CREATE TABLE RKVersion(modelId integer primary key, uuid varchar, name varchar, masterUuid varchar, projectUuid varchar, imageDate real, mainRating integer, isFlagged integer, isHidden integer, colorLabelIndex integer, masterWidth integer, masterHeight integer, rotation integer, isInTrash integer, exifLatitude real, exifLongitude real, versionNumber integer);
        CREATE TABLE RKImageAdjustment(modelId integer primary key, versionUuid varchar, name varchar, isEnabled integer, data blob, maskUuid varchar, adjIndex integer);
        CREATE TABLE RKKeyword(modelId integer primary key, name varchar, parentId integer);
        CREATE TABLE RKKeywordForVersion(modelId integer primary key, versionId integer, keywordId integer);
        CREATE TABLE RKAlbum(modelId integer primary key, name varchar, albumType integer, albumSubclass integer, folderUuid varchar, isMagic integer, queryData blob);
        CREATE TABLE RKAlbumVersion(modelId integer primary key, versionId integer, albumId integer);
        INSERT INTO RKFolder VALUES(1,'root',1,'',NULL,'1/'),(2,'projs',1,'Projects','root','1/2/'),(3,'p1',2,'Trip','projs','1/2/3/');
        INSERT INTO RKMaster VALUES(1,'m1','p1','2010/m.jpg',0,0,'IMGT',1000,'m.jpg',250798920);
        INSERT INTO RKVersion VALUES(1,'v1','Pic','m1','p1',250798920,3,1,0,4,120,80,0,0,NULL,NULL,1);
        INSERT INTO RKKeyword VALUES(1,'Travel',0),(2,'Italy',1);
        INSERT INTO RKKeywordForVersion VALUES(1,1,2);
        """)
        let root: NSDictionary = ["DGOperationIdentifier": "exposure", "enabled": true, "inputKeys": ["inputEV": 1.25] as NSDictionary]
        let blob = try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
        try db.run("INSERT INTO RKImageAdjustment VALUES(1,'v1','RKExposureOperation',1,?,NULL,11000000)", [.blob(blob)])
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE")
        let before = try Importer.sha256(of: lib.appendingPathComponent("Database/Library.apdb"))
        let s = try store()
        let rep = try LegacyLibraryImporter.importLibrary(at: lib, into: s)
        XCTAssertEqual(rep.projects, 1); XCTAssertEqual(rep.versions, 1); XCTAssertEqual(rep.keywords, 1); XCTAssertTrue(rep.missingMasters.isEmpty)
        let v = s.versions["v1"]!; XCTAssertEqual(v.rating, 3); XCTAssertTrue(v.flagged); XCTAssertEqual(v.colorLabel, 4); XCTAssertEqual(v.keywords, ["Travel/Italy"])
        XCTAssertEqual(s.adjustments(for: "v1").item(Catalog.exposure)?.params["inputEV"], 1.25)
        XCTAssertEqual(try Importer.sha256(of: lib.appendingPathComponent("Database/Library.apdb")), before, "source library must stay byte-identical")
    }


    // MARK: step A engine additions
    func pixel(_ g: CGImage, _ x: Int, _ y: Int) -> [Int] {   // y from top
        var p = [UInt8](repeating: 0, count: 4)
        CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(g, in: CGRect(x: -x, y: -(g.height - 1 - y), width: g.width, height: g.height))
        return p.prefix(3).map(Int.init)
    }
    func testFlipMirrorsHorizontally() throws {
        let u = try makeJPEG("f.jpg"); let size = CGSize(width: 120, height: 80)
        var set = AdjustmentSet(); set.upsert(Adjustment(id: Catalog.flip, params: ["inputFlipType": 1]))
        let a = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: size))!
        let b = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: size, adjustments: set))!
        // red square sits at x 10..40 (bottom-left origin) → after flip it is at 80..110
        XCTAssertGreaterThan(pixel(a, 20, 60)[0], 200); XCTAssertGreaterThan(pixel(b, 100, 60)[0], 200); XCTAssertLessThan(pixel(b, 20, 60)[0], 150)
    }
    func testTintWheelsShiftColor() throws {
        let u = try makeJPEG("t.jpg", gray: 0.5); let size = CGSize(width: 120, height: 80)
        var set = AdjustmentSet(); set.upsert(Adjustment(id: Catalog.enhance, params: ["inputGrayUOffset": 1, "inputWhiteUOffset": 1, "inputBlackUOffset": 1]))
        let a = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: size))!
        let b = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: size, adjustments: set))!
        XCTAssertGreaterThan(pixel(b, 100, 20)[2], pixel(a, 100, 20)[2] + 10)       // U>0 pushes blue up
    }
    func testTonalRangeBrushOnlyAffectsShadows() throws {
        let u = try makeJPEG("tb.jpg", gray: 0.2); let size = CGSize(width: 120, height: 80)
        var br = BrushAdjustment(op: "dodge", params: ["inputExposure": 1], strokes: [Stroke(points: [[100, 40]], radius: 8, softness: 0.1), Stroke(points: [[25, 55]], radius: 8, softness: 0.1)])
        br.tonalRange = 3                                                           // highlights only: the dark gray area must stay, the bright red square may change
        var set = AdjustmentSet(); set.brushes.append(br)
        let a = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: size))!
        let b = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: size, adjustments: set))!
        XCTAssertEqual(pixel(a, 100, 40)[0], pixel(b, 100, 40)[0], accuracy: 3)
    }
    func testWhiteBalancePickerNeutralizesWarmCast() throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.62, 0.5, 0.36, 1])!); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))   // warm gray
        let u = tmp.appendingPathComponent("wb.png"); let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
        let size = CGSize(width: 100, height: 100)
        guard let r = RenderEngine.shared.solveWhiteBalance(url: u, isRaw: false, originalSize: size, adjustments: AdjustmentSet(), at: CGPoint(x: 0.5, y: 0.5), start: (5000, 0)) else { return XCTFail("solver failed") }
        var set = AdjustmentSet(); set.upsert(Adjustment(id: Catalog.wb, params: ["inputTemperature": r.temperature, "inputTint": r.tint, "inputIsDefaults": 0]))
        let out = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: size, adjustments: set))!
        let px = pixel(out, 50, 50)
        XCTAssertEqual(px[0], px[2], accuracy: 6, "R and B should match after picking: \(px) via \(r)")
        XCTAssertEqual(px[1], (px[0] + px[2]) / 2, accuracy: 6)
    }
    func testClippingOverlay() throws {
        let u = try makeJPEG("c2.jpg", gray: 1.0); let size = CGSize(width: 120, height: 80)
        let cg = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: size))!
        let o = RenderEngine.shared.clippingOverlay(cg)!
        XCTAssertEqual(pixel(o, 100, 20), [255, 0, 0])
    }

    // MARK: step B metadata
    func makeStoreWith(_ n: Int) throws -> (LibraryStore, [Version]) {
        let s = try store(); let p = try s.addContainer(Container(kind: .project, name: "P", parentID: nil))
        var items: [(Master, Version)] = []
        for i in 0..<n { let u = try makeJPEG("m\(i).jpg", gray: 0.3 + CGFloat(i) * 0.05)
            let m = Master(projectID: p.id, path: u.path, isReference: true, isRaw: false, width: 120, height: 80, checksum: try Importer.sha256(of: u), originalName: "m\(i).jpg")
            var v = Version(masterID: m.id, projectID: p.id, name: "n\(i)", imageDate: Date(timeIntervalSince1970: 1_000_000 + Double(i) * 60)); v.latitude = 48.1; v.longitude = 11.5; items.append((m, v)) }
        try s.insertBatch(items); return (s, items.map { $0.1 })
    }
    func testBatchChangeRenameDateAndMetadata() throws {
        let (s, vs) = try makeStoreWith(3); let ids = vs.map(\.id)
        var ch = BatchChange(); ch.nameTemplate = "Trip {nn}"; ch.fields = ["iptc.creator": "Alex", "caption": "Hello"]; ch.dateShiftSeconds = 3600; ch.keywordsToAdd = ["Travel/Italy"]
        try s.batchChange(ids, ch)
        let sorted = ids.compactMap { s.versions[$0] }
        XCTAssertEqual(sorted.map(\.name), ["Trip 01", "Trip 02", "Trip 03"]); XCTAssertEqual(sorted[0].meta["iptc.creator"], "Alex"); XCTAssertEqual(sorted[0].caption, "Hello")
        XCTAssertEqual(sorted[0].imageDate.timeIntervalSince1970, 1_003_600); XCTAssertEqual(sorted[0].originalImageDate?.timeIntervalSince1970, 1_000_000)
        try s.restoreOriginalDate(ids); XCTAssertEqual(s.versions[ids[0]]?.imageDate.timeIntervalSince1970, 1_000_000)
        var app = BatchChange(); app.fields = ["caption": "more"]; app.mode = .append; try s.batchChange(ids, app); XCTAssertEqual(s.versions[ids[0]]?.caption, "Hello more")
        let s2 = try LibraryStore(root: s.root); XCTAssertEqual(s2.versions[ids[1]]?.meta["iptc.creator"], "Alex")      // persisted (version_meta table)
    }
    func testKeywordRenameAndDelete() throws {
        let (s, vs) = try makeStoreWith(2); try s.update(vs.map(\.id)) { $0.keywords = ["Travel/Italy/Rome", "Family"] }
        try s.renameKeyword("Travel", to: "Trips"); XCTAssertEqual(Set(s.versions[vs[0].id]!.keywords), ["Trips/Italy/Rome", "Family"])
        try s.deleteKeyword("Trips/Italy"); XCTAssertEqual(s.versions[vs[0].id]!.keywords, ["Family"])
    }
    func testXMPAndIPTCWrite() throws {
        let (s, vs) = try makeStoreWith(1); var v = vs[0]; v.keywords = ["a", "b/c"]; v.caption = "Cap & <ok>"; v.rating = 4; v.meta["iptc.creator"] = "Me"; v.meta["iptc.copyright"] = "(c) Me"
        let x = MetadataWriter.xmp(for: v); XCTAssertTrue(x.contains("xmp:Rating=\"4\"")); XCTAssertTrue(x.contains("Cap &amp; &lt;ok&gt;")); XCTAssertTrue(x.contains("<rdf:li>b/c</rdf:li>")); XCTAssertTrue(x.contains("GPSLatitude"))
        XCTAssertFalse(MetadataWriter.xmp(for: v, includeLocation: false).contains("GPSLatitude"))
        let url = s.masterURL(s.masters[v.masterID]!); let before = try Importer.sha256(of: url)
        XCTAssertTrue(try MetadataWriter.writeIPTC(v, to: url))
        XCTAssertNotEqual(try Importer.sha256(of: url), before, "writing IPTC is the one deliberate original change")
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        let iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        XCTAssertEqual(Set((iptc?[kCGImagePropertyIPTCKeywords] as? [String]) ?? []), ["a", "b/c"]); XCTAssertEqual(iptc?[kCGImagePropertyIPTCCopyrightNotice] as? String, "(c) Me")
        XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 120, "image data unchanged")
        let raw = tmp.appendingPathComponent("x.nef"); try Data([1, 2, 3]).write(to: raw)
        XCTAssertFalse(try MetadataWriter.writeIPTC(v, to: raw)); XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("x.xmp").path))
        XCTAssertEqual(try Data(contentsOf: raw), Data([1, 2, 3]), "RAW originals stay untouched; a sidecar is written instead")
    }
    func testExportOptionsExcludeLocationAndWatermark() throws {
        let (s, vs) = try makeStoreWith(1); try s.update([vs[0].id]) { $0.keywords = ["k"]; $0.caption = "c" }
        var o = ExportOptions(); o.includeLocation = false; o.includeKeywords = false; o.writeSidecar = true
        let r = try Exporter(store: s).export([vs[0].id], preset: ExportPreset.factory[6], to: tmp.appendingPathComponent("o1"), options: o)
        let p = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(r.written[0] as CFURL, nil)!, 0, nil) as! [CFString: Any]
        XCTAssertNil(p[kCGImagePropertyGPSDictionary]); XCTAssertNil((p[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCKeywords])
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.written[0].deletingPathExtension().appendingPathExtension("xmp").path))
        var w = ExportOptions(); w.watermark = Watermark(text: "WWWWWWWW"); w.watermark?.sizeFraction = 0.3; w.watermark?.opacity = 1
        let r2 = try Exporter(store: s).export([vs[0].id], preset: ExportPreset.factory[10], to: tmp.appendingPathComponent("o2"), options: w)     // PNG original size
        let a = RenderEngine.shared.renderCG(RenderRequest(url: s.masterURL(s.masters[vs[0].masterID]!), isRaw: false, originalSize: CGSize(width: 120, height: 80)))!
        let b = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(r2.written[0] as CFURL, nil)!, 0, nil)!
        XCTAssertGreaterThan(mean(b), mean(a) + 2, "watermark text lightens the corner area")
    }
    func testMetadataConfigPersistsAndUpdateFromMaster() throws {
        let c = MetadataConfig(libraryRoot: tmp); c.addPreset(MetadataPreset(name: "Press", fields: ["iptc.credit": "Agency"])); c.rememberAutofill("iptc.city", "Berlin"); c.addView(MetadataView(name: "Mine", fields: ["name"]))
        c.keywordSets = [KeywordSet(name: "Set A", keywords: ["x", "y"])]
        let c2 = MetadataConfig(libraryRoot: tmp); XCTAssertEqual(c2.presets.first?.fields["iptc.credit"], "Agency"); XCTAssertEqual(c2.autofill("iptc.city"), ["Berlin"]); XCTAssertTrue(c2.views.contains { $0.name == "Mine" }); XCTAssertEqual(c2.keywordSets.first?.keywords, ["x", "y"])
        XCTAssertEqual(MetadataView.factoryViews.count, 10)
        let (s, vs) = try makeStoreWith(1); try s.update([vs[0].id]) { $0.latitude = nil; $0.longitude = nil }
        XCTAssertEqual(try s.updateFromMaster([vs[0].id]), 1)
        let ex = ExifReader.values(for: s.masterURL(s.masters[vs[0].masterID]!), master: s.masters[vs[0].masterID], isMissing: false, version: s.versions[vs[0].id])
        XCTAssertEqual(ex["file.dims"], "120 × 80 px"); XCTAssertEqual(ex["file.type"], "Image")
    }

    // MARK: step C/D stacks, libraries, vaults, repair
    func managedStore(_ n: Int, name: String = "Lib") throws -> (LibraryStore, [Version]) {
        let src = tmp.appendingPathComponent("src-\(name)"); try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0..<n { try FileManager.default.copyItem(at: try makeJPEG("\(name)\(i).jpg", gray: (name == "A" ? 0.2 : 0.5) + CGFloat(i) * 0.07), to: src.appendingPathComponent("\(name)\(i).jpg")) }
        let s = try LibraryStore(root: tmp.appendingPathComponent("\(name).retrolux"))
        var o = ImportOptions(); o.newProjectName = "Proj \(name)"; _ = try Importer(store: s).importFiles([src], options: o)
        return (s, s.versions.values.sorted { $0.name < $1.name })
    }
    func testStacks() throws {
        let (s, vs) = try managedStore(6); let ids = vs.map(\.id)
        let sid = try s.makeStack([ids[0], ids[1], ids[2]])!
        XCTAssertEqual(s.stackMembers(sid).map(\.id), [ids[0], ids[1], ids[2]])
        try s.setPick(ids[2]); XCTAssertEqual(s.stackMembers(sid).first?.id, ids[2])
        try s.move(inStack: ids[2], by: 1); XCTAssertEqual(s.stackMembers(sid)[1].id, ids[2])
        try s.makeStack([ids[3], ids[0]]); XCTAssertEqual(s.stackMembers(sid).count, 4, "stacking a member merges the stacks")
        try s.splitStack(at: s.stackMembers(sid)[2].id); XCTAssertEqual(s.stackIDs().count, 2)
        try s.extractFromStack([ids[3]]); XCTAssertNil(s.versions[ids[3]]?.stackID)
        try s.unstack([ids[0]]); XCTAssertTrue(s.stackIDs().isEmpty || s.stackIDs().allSatisfy { s.stackMembers($0).count >= 2 })
        let t = try LibraryStore(root: s.root); XCTAssertEqual(t.versions[ids[1]]?.stackPos, s.versions[ids[1]]?.stackPos, "stack positions persist")
    }
    func testAutoStackByTime() throws {
        let (s, vs) = try makeStoreWith(6)   // timestamps 60 s apart
        try s.update([vs[3].id, vs[4].id, vs[5].id]) { $0.imageDate = $0.imageDate.addingTimeInterval(10_000) }
        XCTAssertEqual(try s.autoStack(vs.map(\.id), gap: 120), 2)
        XCTAssertEqual(s.stackIDs().count, 2)
    }
    func testMergeLibrariesCopiesAndDeduplicates() throws {
        let (a, av) = try managedStore(3, name: "A"); try a.setAdjustments(av[0].id, AdjustmentSet(items: [Adjustment(id: Catalog.exposure, params: ["inputEV": 1])])); try a.update([av[1].id]) { $0.keywords = ["k"]; $0.rating = 5 }
        let (b, _) = try managedStore(1, name: "B")
        let r1 = try LibraryMerge.merge(from: a, into: b)
        XCTAssertEqual(r1.versions, 3); XCTAssertEqual(r1.mastersCopied, 3); XCTAssertEqual(b.versions.count, 4)
        let merged = b.versions.values.first { $0.name == av[0].name && $0.projectID != av[0].projectID }!
        XCTAssertEqual(b.adjustments(for: merged.id).item(Catalog.exposure)?.value("inputEV"), 1)
        for m in b.masters.values { XCTAssertEqual(try Importer.sha256(of: b.masterURL(m)), m.checksum) }
        let r2 = try LibraryMerge.merge(from: a, into: b); XCTAssertEqual(r2.duplicatesReused, 3); XCTAssertEqual(r2.mastersCopied, 0, "same originals are reused, not copied twice")
        // export one project as a new library
        let c = try LibraryStore(root: tmp.appendingPathComponent("Part.retrolux")); var mo = MergeOptions(); mo.containerIDs = [a.containers.values.first { $0.kind == .project }!.id]
        _ = try LibraryMerge.merge(from: a, into: c, options: mo); XCTAssertEqual(c.versions.count, 3)
    }
    func testDuplicateStructureAndMergeProjects() throws {
        let (s, _) = try managedStore(2); let proj = s.containers.values.first { $0.kind == .project }!
        let copy = try LibraryMerge.duplicateStructure(of: proj.id, in: s)!; XCTAssertEqual(s.versions(in: copy).count, 0); XCTAssertEqual(s.containers[copy]?.kind, .project)
        let before = s.versions.count; try LibraryMerge.mergeProjects([proj.id], into: copy, store: s); XCTAssertEqual(s.versions(in: copy).count, before); XCTAssertNil(s.containers[proj.id])
    }
    func testRelocateConsolidateLocate() throws {
        let (s, _) = try managedStore(2); let m = s.masters.values.first!
        let ext = tmp.appendingPathComponent("external")
        XCTAssertEqual(try s.relocate([m.id], to: ext).done, 1); let r = s.masters[m.id]!; XCTAssertTrue(r.isReference); XCTAssertTrue(FileManager.default.fileExists(atPath: r.path))
        let moved = tmp.appendingPathComponent("moved"); try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: r.path), to: moved.appendingPathComponent(r.originalName)); XCTAssertTrue(s.isMissing(s.masters[m.id]!))
        let loc = try s.locateReferenced(in: moved); XCTAssertEqual(loc.relinked, 1); XCTAssertFalse(s.isMissing(s.masters[m.id]!))
        XCTAssertEqual(try s.consolidate([m.id]).done, 1); XCTAssertFalse(s.masters[m.id]!.isReference); XCTAssertFalse(s.isMissing(s.masters[m.id]!))
    }
    func testVaultUpdateRestoreAndOffline() throws {
        let (s, vs) = try managedStore(3); try s.update([vs[0].id]) { $0.rating = 3 }
        let place = tmp.appendingPathComponent("vaultdrive"); try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let vm = VaultManager(libraryRoot: s.root); vm.add(Vault(name: "V", path: place.path)); let v = vm.vaults[0]
        let r = try vm.update(v.id, library: s); XCTAssertEqual(r.files, 3); XCTAssertEqual(try vm.update(v.id, library: s).files, 0, "second update is incremental")
        let bundle = vm.bundleURL(v, library: s)
        let dest = tmp.appendingPathComponent("Restored.retrolux"); let rr = try VaultManager.restore(vaultBundle: bundle, to: dest)
        XCTAssertEqual(rr.versions, 3); XCTAssertEqual(try LibraryStore(root: dest).versions[vs[0].id]?.rating, 3)
        XCTAssertThrowsError(try VaultManager.restore(vaultBundle: bundle, to: dest), "never overwrites an existing library")
        let vm2 = VaultManager(libraryRoot: s.root); XCTAssertEqual(vm2.vaults.count, 1, "vault list persists")
        vm.setPath(v.id, "/nonexistent/drive"); XCTAssertThrowsError(try vm.update(v.id, library: s)); XCTAssertFalse(vm.isAvailable(vm.vaults[0]))
    }
    func testIntegrityCheckAndRepair() throws {
        let (s, vs) = try managedStore(2)
        XCTAssertTrue(s.checkIntegrity(verifyChecksums: true).ok)
        try s.dbHandle.exec("DELETE FROM master WHERE id='\(vs[0].masterID)'"); s.reloadAll()
        let bad = s.checkIntegrity(); XCTAssertFalse(bad.ok); XCTAssertTrue(bad.text.contains("without master"))
        let fixed = try s.repair(); XCTAssertTrue(fixed.fixed.contains { $0.contains("pre-repair") })
        XCTAssertNil(s.versions[vs[0].id]); XCTAssertTrue(s.checkIntegrity().ok)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: s.root.path).contains { $0.hasPrefix("Library.sqlite.pre-repair") })
        let m = s.masters.values.first!; try Data([9]).write(to: s.masterURL(m)); XCTAssertTrue(s.checkIntegrity(verifyChecksums: true).text.contains("checksum"))
    }
    func testDeleteMasterAndAllVersions() throws {
        let (s, vs) = try managedStore(2); let d = try s.duplicateVersion(vs[0].id)!; let url = s.masterURL(s.masters[vs[0].masterID]!)
        try s.deleteMastersAndVersions(of: [d.id]); XCTAssertNil(s.versions[vs[0].id]); XCTAssertNil(s.versions[d.id]); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)); XCTAssertEqual(s.versions.count, 1)
    }

    // MARK: step E import extras, media
    func makeWAV(_ name: String, seconds: Double = 1) throws -> URL {
        let rate = 8000, n = Int(Double(rate) * seconds); var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }; func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + n * 2); d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(n * 2); for i in 0..<n { u16(Int(Int16(8000 * sin(Double(i) * 0.1))) & 0xFFFF) }
        let u = tmp.appendingPathComponent(name); try d.write(to: u); return u
    }
    func makeRatedJPEG(_ name: String, rating: Int, gray: CGFloat) throws -> URL {
        let src = try makeJPEG("tmp-" + name, gray: gray); let out = tmp.appendingPathComponent(name)
        let s = CGImageSourceCreateWithURL(src as CFURL, nil)!; let dst = CGImageDestinationCreateWithURL(out as CFURL, CGImageSourceGetType(s)!, 1, nil)!
        let md = CGImageMetadataCreateMutable(); CGImageMetadataRegisterNamespaceForPrefix(md, "http://ns.adobe.com/xap/1.0/" as CFString, "xmp" as CFString, nil)
        CGImageMetadataSetValueWithPath(md, nil, "xmp:Rating" as CFString, String(rating) as CFString)
        XCTAssertTrue(CGImageDestinationCopyImageSource(dst, s, [kCGImageDestinationMetadata: md, kCGImageDestinationMergeMetadata: true] as CFDictionary, nil)); return out
    }
    func testImportNamingFoldersAndMetadataPreset() throws {
        let src = tmp.appendingPathComponent("n"); try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0..<3 { try FileManager.default.copyItem(at: try makeJPEG("t\(i).jpg", gray: 0.2 + CGFloat(i) * 0.1), to: src.appendingPathComponent("t\(i).jpg")) }
        let s = try store(); var o = ImportOptions(); o.namePolicy = .customIndex; o.customName = "Trip"; o.renameFiles = true; o.folderPolicy = .byProject; o.newProjectName = "Alps"
        o.metadata = ["iptc.creator": "Me", "caption": "C"]; o.keywords = ["Imp/ort"]; o.adjustments = AdjustmentSet(items: [Adjustment(id: Catalog.exposure, params: ["inputEV": 0.5])])
        let r = try Importer(store: s).importFiles([src], options: o)
        let names = r.versionIDs.compactMap { s.versions[$0]?.name }.sorted(); XCTAssertEqual(names, ["Trip 1", "Trip 2", "Trip 3"])
        let v = s.versions[r.versionIDs[0]]!; XCTAssertEqual(v.meta["iptc.creator"], "Me"); XCTAssertEqual(v.caption, "C"); XCTAssertEqual(v.keywords, ["Imp/ort"]); XCTAssertEqual(s.adjustments(for: v.id).item(Catalog.exposure)?.value("inputEV"), 0.5)
        let m = s.masters[v.masterID]!; XCTAssertTrue(m.path.hasPrefix("Alps/Trip"), "folder policy + rename on disk: \(m.path)"); XCTAssertTrue(FileManager.default.fileExists(atPath: s.masterURL(m).path))
        for pol in ImportNamePolicy.allCases { XCTAssertFalse(Importer.versionName({ var x = ImportOptions(); x.namePolicy = pol; x.customName = "My Name"; return x }(), base: "IMG_1", date: Date(), index: 2, counter: 9).isEmpty) }
        XCTAssertEqual(Importer.versionName({ var x = ImportOptions(); x.namePolicy = .customIndexNoSpaces; x.customName = "My Name"; return x }(), base: "b", date: Date(), index: 2, counter: 1), "My_Name_2")
        XCTAssertEqual(ImportNamePolicy.allCases.count, 8)
    }
    func testImportSplitBackupRatingFilterAndKinds() throws {
        let src = tmp.appendingPathComponent("sp"); try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let a = try makeRatedJPEG("a.jpg", rating: 4, gray: 0.3), b = try makeRatedJPEG("b.jpg", rating: 1, gray: 0.4), c = try makeRatedJPEG("c.jpg", rating: 5, gray: 0.5)
        XCTAssertEqual(CameraMetadata.rating(a), 4)
        for (u, d) in [(a, 0.0), (b, 600.0), (c, 3600.0 * 10)] { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000 + d)], ofItemAtPath: u.path); try FileManager.default.copyItem(at: u, to: src.appendingPathComponent(u.lastPathComponent)) }
        let wav = try makeWAV("sound.wav"); try FileManager.default.copyItem(at: wav, to: src.appendingPathComponent("sound.wav"))
        let s = try store(); var o = ImportOptions(); o.splitGapHours = 2; o.newProjectName = "Day"; o.managed = false; o.minCameraRating = 2; o.kinds = [.image]
        var r = try Importer(store: s).importFiles([src], options: o)
        XCTAssertEqual(r.imported, 2, "rating filter drops b.jpg, kind filter drops the wav"); XCTAssertEqual(r.filtered.count, 2); XCTAssertEqual(r.projectIDs.count, 2, "10 h gap splits into two projects")
        XCTAssertEqual(s.versions.values.first { $0.name == "a" }?.rating, 4, "camera rating is mapped")
        // backup: success, then failure (backup folder is a file) must fail the import of that file
        let bk = tmp.appendingPathComponent("backup"); var o2 = ImportOptions(); o2.managed = false; o2.backupFolder = bk; o2.kinds = [.audio]
        let s2 = try store2("b2"); r = try Importer(store: s2).importFiles([src], options: o2); XCTAssertEqual(r.imported, 1); XCTAssertEqual(try Importer.sha256(of: bk.appendingPathComponent("sound.wav")), try Importer.sha256(of: wav))
        let blocker = tmp.appendingPathComponent("blocker"); try Data([1]).write(to: blocker); var o3 = o2; o3.backupFolder = blocker; let s3 = try store2("b3")
        r = try Importer(store: s3).importFiles([src], options: o3); XCTAssertEqual(r.imported, 0); XCTAssertEqual(r.backupFailed, ["sound.wav"]); XCTAssertTrue(s3.versions.isEmpty, "a failed backup is never reported as a successful import")
    }
    func store2(_ n: String) throws -> LibraryStore { try LibraryStore(root: tmp.appendingPathComponent(n + ".retrolux")) }
    func testAudioMediaAttachmentsAndPostScript() throws {
        let wav = try makeWAV("clip.wav", seconds: 2); let s = try store(); var o = ImportOptions(); o.managed = false
        let script = tmp.appendingPathComponent("post.sh"); let outFile = tmp.appendingPathComponent("post.out")
        try "#!/bin/sh\necho \"$@\" > '\(outFile.path)'\n".write(to: script, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path); o.postScript = script
        let r = try Importer(store: s).importFiles([wav], options: o)
        let m = s.masters.values.first!; XCTAssertEqual(m.kind, .audio); XCTAssertEqual(m.duration, 2, accuracy: 0.1)
        XCTAssertTrue(r.notes.contains { $0.contains("exit 0") }); XCTAssertTrue((try? String(contentsOf: outFile))?.contains("clip.wav") == true, "post-import script received the file path")
        let img = try makeJPEG("pic.jpg"); let ri = try Importer(store: s).importFiles([img], options: o); let id = ri.versionIDs[0]
        try s.attachAudio(wav, to: id); XCTAssertTrue(FileManager.default.fileExists(atPath: s.attachmentURL(s.versions[id]!)!.path))
        try s.setVideoTrim(id, inPoint: 1.5, outPoint: 4, poster: 2); XCTAssertEqual(s.versions[id]?.videoIn, 1.5); XCTAssertEqual(s.versions[id]?.videoOut, 4); XCTAssertEqual(s.versions[id]?.posterTime, 2)
        try s.removeAudio(from: id); XCTAssertNil(s.versions[id]?.audioAttachment)
        XCTAssertNotNil(MediaProbe.probe(wav))
    }
    func testImportPresetsAndIPhotoLibrary() throws {
        var o = ImportOptions(); o.namePolicy = .imageDate; o.backupFolder = tmp.appendingPathComponent("bk"); o.splitGapHours = 4
        let st = ImportPresetStore(libraryRoot: tmp); st.save(ImportPreset(name: "Card", options: o)); let st2 = ImportPresetStore(libraryRoot: tmp)
        XCTAssertEqual(st2.presets.first?.options.namePolicy, .imageDate); XCTAssertEqual(st2.presets.first?.options.splitGapHours, 4); XCTAssertEqual(st2.presets.first?.options.backupFolder?.lastPathComponent, "bk")
        let lib = tmp.appendingPathComponent("iPhoto Library"); try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let p1 = try makeJPEG("ip1.jpg"), p2 = try makeJPEG("ip2.jpg", gray: 0.6)
        let plist: [String: Any] = ["Master Image List": ["1": ["ImagePath": p1.path, "Caption": "Beach", "Rating": 3, "DateAsTimerInterval": 100_000_000.0, "Keywords": ["k1"]], "2": ["ImagePath": p2.path, "Comment": "hi", "Flagged": true, "Rotation": 90], "3": ["ImagePath": "/nope.jpg"]],
            "List of Rolls": [["RollName": "Summer", "KeyList": ["1", "2", "3"]]], "List of Albums": [["AlbumName": "Fav", "Album Type": "Regular", "KeyList": ["1"]], ["AlbumName": "Library", "Album Type": "Special", "KeyList": ["1", "2"]]], "List of Keywords": ["k1": "Holiday"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: lib.appendingPathComponent("AlbumData.xml"))
        let s = try store(); let rep = try IPhotoLibraryImporter.importLibrary(at: lib, into: s)
        XCTAssertEqual(rep.projects, 1); XCTAssertEqual(rep.versions, 2); XCTAssertEqual(rep.albums, 1); XCTAssertEqual(rep.missing.count, 1)
        let beach = s.versions.values.first { $0.name == "Beach" }!; XCTAssertEqual(beach.rating, 3); XCTAssertEqual(beach.keywords, ["Holiday"])
        let v2 = s.versions.values.first { $0.name == "ip2" }!; XCTAssertTrue(v2.flagged); XCTAssertEqual(v2.rotation, 90); XCTAssertEqual(v2.caption, "hi")
        XCTAssertThrowsError(try IPhotoLibraryImporter.importLibrary(at: tmp, into: s))
    }

    // MARK: step F faces + places
    struct FakeFaceEngine: FaceEngine { var out: [DetectedFace]; func analyze(_ image: CGImage) -> [DetectedFace] { out } }
    func vec(_ x: Float, _ y: Float) -> Data { var a: [Float] = [x, y, 0, 0]; return Data(bytes: &a, count: 16) }
    func testFacesNamingSuggestionsMergeAndDelete() throws {
        let (s, vs) = try makeStoreWith(4)
        // 4 photos, each one face: A, A', B, A''
        let embs: [Data] = [vec(0, 0), vec(0.1, 0), vec(5, 5), vec(0.05, 0.1)]
        for (i, v) in vs.enumerated() { _ = try s.insertFaces([DetectedFace(rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), embedding: embs[i])], version: v.id) }
        let an = FaceAnalyzer(store: s, engine: FakeFaceEngine(out: []))
        XCTAssertEqual(an.clusterUnnamed(maxDistance: 0.5).map(\.count).sorted(), [1, 3], "three similar faces cluster together")
        let anna = try s.createPerson("Anna"); XCTAssertEqual(try s.createPerson("anna").id, anna.id, "no duplicate persons")
        try s.nameFace(s.faces(of: vs[0].id)[0].id, person: anna.id)
        XCTAssertEqual(try an.suggestAll(), 2); let sug = s.faces(of: vs[1].id)[0]; XCTAssertEqual(sug.suggestedID, anna.id); XCTAssertNil(s.faces(of: vs[2].id)[0].suggestedID)
        try s.confirmSuggestion(sug.id); XCTAssertEqual(s.faces(of: vs[1].id)[0].personID, anna.id); XCTAssertTrue(s.faces(of: vs[1].id)[0].confirmed)
        try s.rejectSuggestion(s.faces(of: vs[3].id)[0].id); XCTAssertNil(s.faces(of: vs[3].id)[0].suggestedID)
        try an.suggestAll(); XCTAssertEqual(s.faces(of: vs[0].id)[0].personID, anna.id, "confirmed assignments survive re-suggestion")
        XCTAssertEqual(s.versions(of: anna.id, includeSuggested: false).count, 2); XCTAssertEqual(s.peopleNames(of: vs[0].id), ["Anna"]); XCTAssertEqual(s.peopleNames(of: vs[2].id), [])
        let dup = try s.createPerson("Anna K."); try s.nameFace(s.faces(of: vs[2].id)[0].id, person: dup.id)
        try s.mergePeople(dup.id, into: anna.id); XCTAssertEqual(s.people().count, 1); XCTAssertEqual(s.faces(of: vs[2].id)[0].personID, anna.id)
        try s.renamePerson(anna.id, "Anna Meier"); XCTAssertEqual(s.people()[0].name, "Anna Meier")
        try s.markNotAFace(s.faces(of: vs[3].id)[0].id); XCTAssertTrue(s.faces(of: vs[3].id).isEmpty)
        try s.deleteAllFaceData(); XCTAssertTrue(s.people().isEmpty && s.allFaces().isEmpty, "face data can be deleted completely")
    }
    func testFaceReanalysisKeepsConfirmedFaces() throws {
        let (s, vs) = try makeStoreWith(1); let det = DetectedFace(rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), embedding: vec(1, 1))
        let an = FaceAnalyzer(store: s, engine: FakeFaceEngine(out: [det])); XCTAssertEqual(try an.analyze(version: vs[0].id), 1)
        let p = try s.createPerson("Bo"); try s.nameFace(s.faces(of: vs[0].id)[0].id, person: p.id)
        XCTAssertEqual(try an.analyze(version: vs[0].id), 0, "same face is not duplicated"); XCTAssertEqual(s.faces(of: vs[0].id).count, 1); XCTAssertEqual(s.faces(of: vs[0].id)[0].personID, p.id)
        XCTAssertFalse(s.mastersNeedingFaceAnalysis().contains { $0.id == vs[0].masterID })
        let man = try an.addManualFace(version: vs[0].id, rect: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)); XCTAssertEqual(man?.manual, true); XCTAssertEqual(s.faces(of: vs[0].id).count, 2)
        XCTAssertEqual(try an.analyze(version: vs[0].id), 0); XCTAssertEqual(s.faces(of: vs[0].id).count, 2, "manual faces survive re-analysis")
    }
    func testGPXParseMatchAndPlaces() throws {
        let gpx = """
        <?xml version="1.0"?><gpx><trk><trkseg>
        <trkpt lat="48.0" lon="11.0"><ele>500</ele><time>2020-01-01T10:00:00Z</time></trkpt>
        <trkpt lat="48.1" lon="11.2"><time>2020-01-01T10:10:00Z</time></trkpt>
        <trkpt lat="50.0" lon="12.0"><time>2020-01-01T15:00:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """.data(using: .utf8)!
        let track = GPX.parse(gpx); XCTAssertEqual(track.count, 3); XCTAssertEqual(track[0].ele, 500)
        let base = ISO8601DateFormatter().date(from: "2020-01-01T10:05:00Z")!
        let (s, vs) = try makeStoreWith(3); try s.update([vs[0].id]) { $0.imageDate = base }
        try s.update([vs[1].id]) { $0.imageDate = base.addingTimeInterval(7200) }          // 2 h after the 10:10 point and long before 15:00 → no match
        try s.update([vs[2].id]) { $0.imageDate = base.addingTimeInterval(3600 * 5 + 60) }  // 15:06 → within tolerance of the last point only if offset applied
        let m = GPX.match(s.versions.values.sorted { $0.imageDate < $1.imageDate }, track: track)
        XCTAssertEqual(m.count, 2); let mid = m.first { $0.id == vs[0].id }!; XCTAssertEqual(mid.lat, 48.05, accuracy: 1e-6); XCTAssertEqual(mid.lon, 11.1, accuracy: 1e-6)
        XCTAssertNil(m.first { $0.id == vs[1].id })
        let shifted = GPX.match([s.versions[vs[0].id]!], track: track, cameraOffset: 120)      // camera clock 2 min ahead → real time 10:03
        XCTAssertEqual(shifted[0].lat, 48.03, accuracy: 1e-6)
        XCTAssertEqual(GPX.match([s.versions[vs[0].id]!], track: track, timeZoneShift: 1).count, 0, "1 h zone shift moves the photo out of the track")
        try s.assignLocation([vs[0].id], lat: 1, lon: 2, names: ["place.country": "Italy", "place.city": "Rome"]); XCTAssertEqual(s.locationTree()["Italy"]?[""]?["Rome"], 1); XCTAssertEqual(s.geotaggedCount, 3)
        try s.removeLocations([vs[0].id]); XCTAssertNil(s.versions[vs[0].id]?.latitude); XCTAssertNil(s.versions[vs[0].id]?.meta["place.city"])
        let ps = MyPlacesStore(libraryRoot: tmp); ps.add(MyPlace(name: "Home", latitude: 48.1374, longitude: 11.5755, radius: 200)); XCTAssertEqual(MyPlacesStore(libraryRoot: tmp).places.count, 1)
        XCTAssertEqual(ps.nearest(48.1380, 11.5760)?.name, "Home"); XCTAssertNil(ps.nearest(49, 12)); XCTAssertEqual(GeoMath.distance(48, 11, 48, 11), 0, accuracy: 1e-6); XCTAssertEqual(GeoMath.distance(0, 0, 0, 1), 111_195, accuracy: 300)
    }

    // MARK: step G light table, slideshow, books, print, web
    func pdfPageCount(_ u: URL) -> Int { CGPDFDocument(u as CFURL)?.numberOfPages ?? 0 }
    func testLightTableLayoutAndRender() throws {
        let (s, vs) = try makeStoreWith(4)
        var doc = LightTableDoc(); for (i, v) in vs.enumerated() { doc.items.append(LightTableItem(versionID: v.id, x: 100 + Double(i) * 130, y: 100 + Double(i) * 17, width: 120, height: 80, z: i)) }
        let all = Set(doc.items.map(\.id)); LightTableLayout.align(&doc.items, ids: all, .left); XCTAssertEqual(Set(doc.items.map { $0.x - $0.width / 2 }).count, 1)
        LightTableLayout.align(&doc.items, ids: all, .centerV); XCTAssertEqual(Set(doc.items.map(\.y)).count, 1)
        LightTableLayout.distribute(&doc.items, ids: all, horizontal: true)
        LightTableLayout.grid(&doc.items, aspect: { s.aspect($0) }, bounds: CGSize(width: 600, height: 400)); XCTAssertTrue(doc.items.allSatisfy { $0.x > 0 && $0.x < 600 && $0.y > 0 && $0.y < 400 })
        LightTableLayout.pile(&doc.items, center: CGPoint(x: 300, y: 200)); XCTAssertTrue(doc.items.contains { $0.rotation != 0 })
        try s.saveDocument(s.addContainer(Container(kind: .lightTable, name: "LT", parentID: nil)).id, doc)
        let img = LightTableRenderer.render(doc, store: s, size: CGSize(width: 600, height: 400), scale: 1)!; XCTAssertEqual(img.width, 600); XCTAssertGreaterThan(mean(img), 20)
        let pdf = tmp.appendingPathComponent("lt.pdf"); _ = LightTableRenderer.render(doc, store: s, size: CGSize(width: 600, height: 400), pdf: pdf); XCTAssertEqual(pdfPageCount(pdf), 1)
        let lt = s.containers.values.first { $0.kind == .lightTable }!; XCTAssertEqual(s.document(lt.id, as: LightTableDoc.self)?.items.count, 4); XCTAssertEqual(try LibraryStore(root: s.root).document(lt.id, as: LightTableDoc.self)?.items.count, 4)
    }
    func testBookAutoflowPdfAndChecks() throws {
        let (s, vs) = try makeStoreWith(7); let ids = vs.map(\.id)
        var doc = BookDoc(); doc.theme = "Photo Essay"; doc.type = "Small Softcover"; doc.title = "T"; doc.pages = BookLayouts.autoflow(ids, theme: doc.theme, captions: [ids[0]: "Hello"])
        let used = doc.pages.flatMap { $0.items }.compactMap(\.versionID); XCTAssertEqual(Set(used), Set(ids)); XCTAssertEqual(used.count, ids.count, "every photo is used exactly once")
        XCTAssertTrue(doc.pages.allSatisfy { p in p.items.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x + $0.w <= 1.0001 && $0.y + $0.h <= 1.0001 } }, "items stay inside the page")
        XCTAssertEqual(BookTheme.all.count, 12); XCTAssertEqual(BookType.all.count, 5)
        let url = tmp.appendingPathComponent("book.pdf"); let rep = try BookRenderer.pdf(doc, store: s, to: url); XCTAssertEqual(pdfPageCount(url), doc.pages.count); XCTAssertEqual(rep.pages, doc.pages.count)
        XCTAssertFalse(rep.lowRes.isEmpty, "120 px test images printed large are flagged as low resolution")
        var bad = doc; bad.pages.append(BookPage(layout: "Full Page", items: [BookItem(kind: .image, x: 0.1, y: 0.1, w: 0.8, h: 0.8)])); bad.pages.append(BookPage(layout: "Text Only", items: [BookItem(kind: .text, x: 0.1, y: 0.1, w: 0.8, h: 0.8)]))
        let c = BookRenderer.check(bad, store: s); XCTAssertEqual(c.emptySlots, 1); XCTAssertEqual(c.blankPages.count, 2); XCTAssertFalse(c.ok)
        let size = BookRenderer.pageSize(doc); XCTAssertEqual(size.width, (6 + 0.25) * 72)
    }
    func testPrintContactSheetPdf() throws {
        let (s, vs) = try makeStoreWith(12); var o = PrintOptions(); o.header = "Test"; o.showDate = true
        let fancy = PrintLayout.presets.first { $0.name == "FancyContactSheet" }!; XCTAssertEqual(PrintLayout.presets.count, 6)
        let u = tmp.appendingPathComponent("cs.pdf"); XCTAssertEqual(try PrintRenderer.pdf(layout: fancy, versions: vs.map(\.id), options: o, store: s, to: u), 1); XCTAssertEqual(pdfPageCount(u), 1)
        let three = PrintLayout.presets.first { $0.name == "3x2" }!; let u2 = tmp.appendingPathComponent("p.pdf"); XCTAssertEqual(try PrintRenderer.pdf(layout: three, versions: vs.map(\.id), options: o, store: s, to: u2), 2)
        let four = PrintLayout.presets.first { $0.name == "4x6" }!; XCTAssertEqual(try PrintRenderer.pdf(layout: four, versions: Array(vs.prefix(3).map(\.id)), options: o, store: s, to: tmp.appendingPathComponent("q.pdf")), 3)
    }
    func testWebGalleryAndJournalExport() throws {
        let (s, vs) = try makeStoreWith(3); try s.update([vs[0].id]) { $0.caption = "A <b> & \"c\"" }
        var doc = WebDoc(); doc.title = "Trip <1>"; doc.theme = "Special Occasion"; doc.columns = 2; doc.showMetadata = true
        let out = tmp.appendingPathComponent("web"); let r = try WebExporter.export(doc, versions: vs.map(\.id), store: s, to: out)
        XCTAssertEqual(r.images, 3); let idx = try String(contentsOf: r.index); XCTAssertTrue(idx.contains("Trip &lt;1&gt;")); XCTAssertTrue(idx.contains("A &lt;b&gt; &amp; &quot;c&quot;")); XCTAssertTrue(idx.contains("page1.html"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("page3.html").path)); XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("thumbs/0002.jpg").path)); XCTAssertFalse(idx.contains("http://") || idx.contains("https://"), "no external requests")
        let css = try String(contentsOf: out.appendingPathComponent("style.css")); XCTAssertTrue(css.contains("repeat(2,1fr)")); XCTAssertEqual(WebDoc.themes.count, 8); XCTAssertEqual(WebDoc.presets.count, 7)
        var j = WebDoc(); j.title = "Journal"; j.blocks = [WebBlock(kind: .heading, text: "Day 1"), WebBlock(kind: .text, text: "Line one\nLine two"), WebBlock(kind: .image, versionID: vs[1].id)]
        let r2 = try WebExporter.export(j, versions: [], store: s, to: tmp.appendingPathComponent("journal")); let h = try String(contentsOf: r2.index)
        XCTAssertTrue(h.contains("<h2>Day 1</h2>")); XCTAssertTrue(h.contains("<p>Line two</p>")); XCTAssertTrue(h.contains("images/0001.jpg")); XCTAssertEqual(r2.images, 1)
    }
    func testSlideshowMovieExportWithSoundtrack() throws {
        let (s, vs) = try makeStoreWith(3); var st = SlideshowSettings.presets.first { $0.0 == "kenBurns" }!.1; st.displayTime = 1; st.fadeTime = 0.4
        XCTAssertEqual(SlideshowSettings.presets.count, 12)
        let wav = try makeWAV("song.wav", seconds: 1); st.songs = [wav.path]
        let out = tmp.appendingPathComponent("show.mov"); let r = try SlideshowExporter.export(vs.map(\.id), settings: st, store: s, preset: SlideshowExporter.Preset.all[0], to: out)
        XCTAssertEqual(r.seconds, 3, accuracy: 0.01); let a = AVURLAsset(url: out); XCTAssertEqual(CMTimeGetSeconds(a.duration), 3, accuracy: 0.3)
        XCTAssertEqual(a.tracks(withMediaType: .video).first.map { Int($0.naturalSize.width) }, 854); XCTAssertFalse(a.tracks(withMediaType: .audio).isEmpty, "soundtrack is mixed in (looped to the movie length)")
        st.overrides[vs[0].id] = { var o = SlideOverride(); o.duration = 2; return o }(); XCTAssertEqual(st.duration(for: vs[0].id), 2); XCTAssertEqual(st.duration(for: vs[1].id), 1)
        XCTAssertTrue(SlideshowStyle.shatter.fixedTransition); XCTAssertFalse(SlideshowStyle.kenBurns.fixedTransition)
    }

    ///: synthetic library; 10k always, 100k with RL_PERF=1. Timings are printed for docs/PERFORMANCE.md.
    func testSyntheticLibraryScale() throws {
        let n = ProcessInfo.processInfo.environment["RL_PERF"] == "1" ? 100_000 : 10_000
        let s = try store()
        let p = try s.addContainer(Container(kind: .project, name: "P", parentID: nil))
        var t0 = Date()
        var items: [(Master, Version)] = []
        for i in 0..<n {
            let m = Master(projectID: p.id, path: "/x\(i).jpg", isReference: true, isRaw: false, originalName: "x\(i).jpg")
            var v = Version(masterID: m.id, projectID: p.id, name: "x\(i)"); v.rating = i % 6; v.keywords = ["k\(i % 50)"]
            items.append((m, v))
        }
        try s.insertBatch(items); let tInsert = Date().timeIntervalSince(t0)
        t0 = Date(); let s2 = try LibraryStore(root: s.root); let tOpen = Date().timeIntervalSince(t0)
        t0 = Date(); let hits = s2.versions.values.filter { $0.rating >= 4 && $0.keywords.contains("k7") }.count; let tFilter = Date().timeIntervalSince(t0)
        print("PERF n=\(n) insert=\(String(format: "%.2f", tInsert))s open=\(String(format: "%.2f", tOpen))s filter=\(String(format: "%.3f", tFilter))s hits=\(hits)")
        XCTAssertEqual(s2.versions.count, n)
        XCTAssertLessThan(tOpen, n >= 100_000 ? 60 : 8)
    }

    func testSoftProofChangesSaturatedColors() throws {
        let u = try makeJPEG("sp.jpg", gray: 0.5)
        let cg = RenderEngine.shared.renderCG(RenderRequest(url: u, isRaw: false, originalSize: CGSize(width: 120, height: 80)))!
        guard let proof = ColorProfiles.space(named: ColorProfiles.builtin.first { $0.name.contains("CMYK") }?.name ?? "") else { return XCTFail("no CMYK proof profile") }
        let p = try XCTUnwrap(RenderEngine.shared.softProof(cg, profile: proof))
        XCTAssertEqual(p.width, cg.width)
        XCTAssertNotEqual(mean(p), mean(cg))     // the saturated red square is pulled into the CMYK gamut
    }
    func testPrintLayoutsHavePublicInit() {
        let l = PrintLayout(name: "X", columns: 3, rows: 2, title: "X")
        XCTAssertEqual(l.columns * l.rows, 6)
    }
}

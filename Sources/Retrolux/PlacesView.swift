import SwiftUI
import MapKit
import AppKit
import UniformTypeIdentifiers
import RetroluxCore

final class PhotoPin: MKPointAnnotation { var versionID: ID = ""; var selected = false; var count = 1; var index = 1 }

/// Own-drawn glossy pin (red; blue while pins can be moved) with a black callout "Name / 1 of N Photos" when selected.
final class PinView: MKAnnotationView {
    static func image(_ blue: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 34), flipped: false) { r in
            NSColor(white: 0.45, alpha: 1).setStroke(); let needle = NSBezierPath(); needle.move(to: NSPoint(x: 9, y: 1)); needle.line(to: NSPoint(x: 9, y: 16)); needle.lineWidth = 1.6; needle.stroke()
            let ball = NSRect(x: 2, y: 15, width: 14, height: 14)
            NSGraphicsContext.current?.saveGraphicsState(); NSShadow().set(); let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.5); sh.shadowBlurRadius = 2; sh.shadowOffset = NSSize(width: 1, height: -1); sh.set()
            (blue ? NSColor(srgbRed: 0.35, green: 0.2, blue: 0.85, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.05, blue: 0.05, alpha: 1)).setFill(); NSBezierPath(ovalIn: ball).fill(); NSGraphicsContext.current?.restoreGraphicsState()
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.85), NSColor.white.withAlphaComponent(0)])?.draw(in: NSBezierPath(ovalIn: NSRect(x: 4.5, y: 21, width: 6, height: 6)), relativeCenterPosition: .zero)
            return true
        }
    }
    private let callout = NSTextField(labelWithString: "")
    override var annotation: MKAnnotation? { didSet { refresh() } }
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = NSRect(x: 0, y: 0, width: 18, height: 34); centerOffset = CGPoint(x: 0, y: 17)
        callout.isHidden = true; callout.alignment = .center; callout.maximumNumberOfLines = 2; callout.textColor = .white; callout.font = .boldSystemFont(ofSize: 11)
        callout.wantsLayer = true; callout.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor; callout.layer?.cornerRadius = 6; callout.drawsBackground = false
        addSubview(callout)
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        image = Self.image(false)
        if let p = annotation as? PhotoPin { callout.stringValue = (p.title ?? "") + "\n" + "\(p.index) of \(p.count) Photos" }
    }
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        callout.isHidden = !selected
        if selected { let sz = callout.sizeThatFits(NSSize(width: 220, height: 40)); callout.frame = NSRect(x: 9 - (sz.width + 20) / 2, y: 38, width: sz.width + 20, height: sz.height + 8) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { callout.isHidden ? super.hitTest(point) : (NSPointInRect(point, bounds) ? self : nil) }
}
final class TrackLine: MKPolyline {}

struct MapContainer: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeCoordinator() -> Coord { Coord(model) }
    func makeNSView(context: Context) -> MKMapView {
        let m = MKMapView(); m.delegate = context.coordinator; m.showsZoomControls = false; m.showsCompass = false
        model.mapRef = m; context.coordinator.map = m
        m.register(PinView.self, forAnnotationViewWithReuseIdentifier: "pin")
        model.loadTracks()
        m.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        return m
    }
    func updateNSView(_ m: MKMapView, context: Context) { context.coordinator.sync(model) }

    final class Coord: NSObject, MKMapViewDelegate {
        let model: AppModel; weak var map: MKMapView?; var lastKey = ""
        init(_ m: AppModel) { model = m }
        var trackKey = ""
        func sync(_ model: AppModel) {
            guard let map else { return }
            map.mapType = [MKMapType.standard, .satellite, .standard][min(2, model.mapKind)]
            if model.mapKind == 2 || model.mapKind == 0 { let c = MKStandardMapConfiguration(elevationStyle: model.mapKind == 2 ? .realistic : .flat); c.pointOfInterestFilter = model.showMapLabels ? .includingAll : .excludingAll; map.preferredConfiguration = c }
            let tk = model.gpsTracks.filter(\.visible).map { "\($0.id)\($0.points.count)" }.joined()
            if tk != trackKey {
                trackKey = tk; map.removeOverlays(map.overlays)
                for t in model.gpsTracks where t.visible { var c = t.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }; map.addOverlay(TrackLine(coordinates: &c, count: c.count)) }
            }
            let geo = model.shown.filter { $0.latitude != nil && $0.longitude != nil }
            let key = geo.map { "\($0.id)\($0.latitude!),\($0.longitude!)\($0.id == model.primary)\(model.selection.contains($0.id))" }.joined(separator: "|") + "|\(model.movePins)"
            guard key != lastKey else { return }; lastKey = key
            let first = map.annotations.isEmpty
            map.removeAnnotations(map.annotations)
            var groups: [String: [Version]] = [:]
            for v in geo { groups[String(format: "%.3f,%.3f", v.latitude!, v.longitude!), default: []].append(v) }
            let pins: [PhotoPin] = groups.values.map { g in
                let v = g.first(where: { model.selection.contains($0.id) }) ?? g[0]
                let p = PhotoPin(); p.coordinate = CLLocationCoordinate2D(latitude: v.latitude!, longitude: v.longitude!)
                p.title = v.meta["place.name"] ?? v.meta["place.city"] ?? v.name; p.count = g.count; p.index = (g.firstIndex(where: { $0.id == v.id }) ?? 0) + 1
                p.versionID = v.id; p.selected = g.contains { model.selection.contains($0.id) }; return p
            }
            map.addAnnotations(pins)
            if !pins.isEmpty, first { map.showAnnotations(pins, animated: false) }
            for p in pins where p.selected { map.selectAnnotation(p, animated: false) }
        }
        func mapView(_ mapView: MKMapView, viewFor a: MKAnnotation) -> MKAnnotationView? {
            guard a is PhotoPin else { return nil }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: "pin", for: a) as? PinView
            v?.image = PinView.image(model.movePins); v?.canShowCallout = false; v?.isDraggable = model.movePins
            return v
        }
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            let r = mapView.region, w = max(1, Double(mapView.bounds.width))
            let mpp = MKMetersPerMapPointAtLatitude(r.center.latitude) * mapView.visibleMapRect.size.width / w
            DispatchQueue.main.async { self.model.mapVisible = .init(lat: r.center.latitude, lon: r.center.longitude, spanLat: r.span.latitudeDelta, spanLon: r.span.longitudeDelta, metersPerPoint: mpp) }
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let rect = overlay as? MKPolygon { let pr = MKPolygonRenderer(polygon: rect); pr.strokeColor = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1); pr.lineWidth = 2; pr.fillColor = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 0.12); return pr }
            let r = MKPolylineRenderer(overlay: overlay); r.strokeColor = NSColor(srgbRed: 0.55, green: 0.2, blue: 0.9, alpha: 0.85); r.lineWidth = 3; return r
        }
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            if newState == .ending, let p = view.annotation as? PhotoPin { model.moveLocation(of: p.versionID, lat: p.coordinate.latitude, lon: p.coordinate.longitude); view.setDragState(.none, animated: true) }
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let p = view.annotation as? PhotoPin { model.click(p.versionID, extend: false, toggle: false) }
            else if let c = view.annotation as? MKClusterAnnotation { model.selection = c.memberAnnotations.compactMap { ($0 as? PhotoPin)?.versionID }; model.primary = model.selection.first }
        }
    }
}

struct PlacesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Breadcrumb(model: model)
            ZStack {
                MapContainer(model: model)
                    .dropDestination(for: String.self) { ids, loc in
                        guard let m = model.mapRef as? MKMapView else { return false }
                        let c = m.convert(CGPoint(x: loc.x, y: m.bounds.height - loc.y), toCoordinateFrom: m)
                        model.selection = ids; model.assignLocation(lat: c.latitude, lon: c.longitude); return true
                    }
                HStack(alignment: .top) { MapZoomSlider(model: model).padding(.leading, 10).padding(.top, 10); Spacer() }.frame(maxHeight: .infinity, alignment: .top)
                VStack { Spacer(); HStack(alignment: .bottom) {
                    MapScaleBar(model: model).padding(.leading, 6).padding(.bottom, 4)
                    Spacer()
                    if model.mapVisible.spanLon < 40 { OverviewMap(model: model).frame(width: 190, height: 150).overlay(Rectangle().stroke(Color.black.opacity(0.5), lineWidth: 1)) }
                } }
                if model.store.versions.values.allSatisfy({ $0.latitude == nil }) { PlacesIntro(model: model) }
                if model.movePins {
                    VStack { Spacer(); HStack(spacing: 14) {
                        Text(model.L("Move a pin to change its location. All Photos at the pin will be updated.", "Bewege eine Stecknadel, um den Ort zu ändern. Alle Fotos an der Nadel werden aktualisiert.")).font(Theme.font(11)).foregroundColor(.white)
                        Button(model.L("Done", "Fertig")) { model.movePins = false }.buttonStyle(AquaButtonStyle())
                    }.padding(.horizontal, 18).padding(.vertical, 8).background(Color.black.opacity(0.8)).cornerRadius(8).padding(.bottom, 40) }
                }
            }
            PlacesBottomBar(model: model)
        }
    }
}

/// Vertical zoom slider with +/- ends (log scale of the camera distance).
struct MapZoomSlider: View {
    @ObservedObject var model: AppModel
    var t: Double { let span = max(0.001, min(180, model.mapVisible.spanLon)); return 1 - (log(span) - log(0.001)) / (log(180) - log(0.001)) }
    func set(_ t: Double) {
        guard let m = model.mapRef as? MKMapView else { return }
        let span = exp(log(0.001) + (1 - min(1, max(0, t))) * (log(180) - log(0.001)))
        m.setRegion(MKCoordinateRegion(center: m.centerCoordinate, span: MKCoordinateSpan(latitudeDelta: span * 0.65, longitudeDelta: span)), animated: false)
    }
    var body: some View {
        VStack(spacing: 2) {
            Button { set(t + 0.08) } label: { Image(systemName: "plus").font(.system(size: 9, weight: .bold)).frame(width: 14, height: 14) }.buttonStyle(.plain)
            GeometryReader { g in
                ZStack(alignment: .top) {
                    Capsule().fill(LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.1)], startPoint: .leading, endPoint: .trailing)).frame(width: 5)
                    Circle().fill(RadialGradient(colors: [.white, Theme.hex(0xC4C4C4)], center: .init(x: 0.4, y: 0.3), startRadius: 0, endRadius: 8)).overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 0.75)).frame(width: 12, height: 12)
                        .offset(y: (1 - t) * (g.size.height - 12))
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in set(1 - Double(min(max(0, d.location.y - 6), g.size.height - 12) / (g.size.height - 12))) })
            }.frame(width: 18, height: 150)
            Button { set(t - 0.08) } label: { Image(systemName: "minus").font(.system(size: 9, weight: .bold)).frame(width: 14, height: 14) }.buttonStyle(.plain)
        }.padding(.vertical, 5).padding(.horizontal, 3).background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.85))).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.4), lineWidth: 0.7))
    }
}

/// "200 mi / 200 km" scale bar derived from the map's metres per point.
struct MapScaleBar: View {
    @ObservedObject var model: AppModel
    static func nice(_ v: Double) -> Double { let p = pow(10, floor(log10(v))); let f = v / p; return (f >= 5 ? 5 : f >= 2 ? 2 : 1) * p }
    var body: some View {
        let mpp = model.mapVisible.metersPerPoint
        if mpp > 0 {
            let km = Self.nice(mpp * 110 / 1000), mi = Self.nice(mpp * 110 / 1609.344)
            let kmLen = km * 1000 / mpp, miLen = mi * 1609.344 / mpp
            VStack(alignment: .leading, spacing: 0) {
                Text("\(mi < 1 ? String(format: "%.1f", mi) : String(Int(mi))) mi").font(Theme.font(10)).offset(x: 4)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.black).frame(width: max(kmLen, miLen), height: 1.5).offset(y: 5)
                    Rectangle().fill(Color.black).frame(width: 1.5, height: 11)
                    Rectangle().fill(Color.black).frame(width: 1.5, height: 6).offset(x: miLen, y: 0)
                    Rectangle().fill(Color.black).frame(width: 1.5, height: 6).offset(x: kmLen, y: 5)
                }.frame(height: 11)
                Text("\(km < 1 ? String(format: "%.1f", km) : String(Int(km))) km").font(Theme.font(10)).offset(x: 4)
            }.padding(4).background(Color.white.opacity(0.55)).cornerRadius(3)
        }
    }
}

/// Overview inset (bottom right while zoomed in) with a red rectangle for the visible area.
struct OverviewMap: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeNSView(context: Context) -> MKMapView { let m = MKMapView(); m.delegate = context.coordinator; m.isZoomEnabled = false; m.isScrollEnabled = false; m.isRotateEnabled = false; m.showsZoomControls = false; m.showsCompass = false; return m }
    func makeCoordinator() -> MapContainer.Coord { MapContainer.Coord(model) }
    func updateNSView(_ m: MKMapView, context: Context) {
        let v = model.mapVisible
        m.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: v.lat, longitude: v.lon), span: MKCoordinateSpan(latitudeDelta: min(170, v.spanLat * 7), longitudeDelta: min(350, v.spanLon * 7))), animated: false)
        m.removeOverlays(m.overlays)
        var c = [CLLocationCoordinate2D(latitude: v.lat - v.spanLat / 2, longitude: v.lon - v.spanLon / 2), CLLocationCoordinate2D(latitude: v.lat - v.spanLat / 2, longitude: v.lon + v.spanLon / 2), CLLocationCoordinate2D(latitude: v.lat + v.spanLat / 2, longitude: v.lon + v.spanLon / 2), CLLocationCoordinate2D(latitude: v.lat + v.spanLat / 2, longitude: v.lon - v.spanLon / 2)]
        m.addOverlay(MKPolygon(coordinates: &c, count: 4))
    }
}

struct AssignLocationSheet: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var error = ""
    func apply(_ lat: Double, _ lon: Double, _ names: [String: String] = [:]) { model.assignLocation(lat: lat, lon: lon, names: names); model.showAssignLocation = false }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.L("Assign Location to \(model.selection.count) photos", "Ort \(model.selection.count) Fotos zuweisen")).font(Theme.font(14, bold: true))
            HStack { TextField(model.L("Search a place or address", "Ort oder Adresse suchen"), text: $query, onCommit: search).textFieldStyle(.roundedBorder); Button(model.L("Search", "Suchen"), action: search).buttonStyle(AquaButtonStyle()) }
            if searching { ProgressView().controlSize(.small) }
            if !error.isEmpty { Text(error).font(Theme.tiny).foregroundColor(.orange) }
            List(results, id: \.self) { it in
                Button { let c = it.placemark.coordinate; apply(c.latitude, c.longitude, ["place.name": it.name ?? "", "place.city": it.placemark.locality ?? "", "place.state": it.placemark.administrativeArea ?? "", "place.country": it.placemark.country ?? ""]) } label: {
                    VStack(alignment: .leading) { Text(it.name ?? "").font(Theme.small); Text([it.placemark.locality, it.placemark.country].compactMap { $0 }.joined(separator: ", ")).font(Theme.tiny).foregroundColor(.gray) } }.buttonStyle(.plain)
            }.frame(height: 110)
            Text(model.L("My Places", "Meine Orte")).font(Theme.font(11, bold: true))
            List(model.myPlaces.places) { p in Button { apply(p.latitude, p.longitude, ["place.name": p.name]) } label: { Text(p.name).font(Theme.small) }.buttonStyle(.plain) }.frame(height: 90)
            HStack {
                Button(model.L("Use Map Center", "Kartenmitte verwenden")) { if let m = model.mapRef as? MKMapView { apply(m.centerCoordinate.latitude, m.centerCoordinate.longitude) } else { error = model.L("Open Places first.", "Öffne zuerst „Orte“.") } }.buttonStyle(AquaButtonStyle())
                Button(model.L("Use Location of Primary Photo", "Ort des primären Fotos verwenden")) { model.useLocationOfPrimary(); model.showAssignLocation = false }.buttonStyle(AquaButtonStyle()).disabled(model.primaryVersion?.latitude == nil)
                Spacer(); Button(model.L("Cancel", "Abbrechen")) { model.showAssignLocation = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }.padding(16).frame(width: 520).background(Theme.chrome)
    }
    func search() {
        guard !query.isEmpty else { return }; searching = true; error = ""
        let req = MKLocalSearch.Request(); req.naturalLanguageQuery = query
        MKLocalSearch(request: req).start { r, e in searching = false; results = r?.mapItems ?? []; if results.isEmpty { error = e == nil ? model.L("No results", "Keine Ergebnisse") : model.L("Search unavailable (offline?). My Places and the map still work.", "Suche nicht verfügbar (offline?). „Meine Orte“ und die Karte funktionieren weiterhin.") } }
    }
}

struct GPXSheet: View {
    @ObservedObject var model: AppModel
    @State private var track: [TrackPoint] = []
    @State private var file = ""
    @State private var offset = 0.0
    @State private var zone = 0.0
    @State private var tolerance = 10.0
    @State private var overwrite = false
    var targets: [Version] { (model.selection.isEmpty ? model.shown.map(\.id) : model.selection).compactMap { model.store.versions[$0] } }
    var matches: [GPX.Match] { GPX.match(targets, track: track, cameraOffset: offset, timeZoneShift: zone, tolerance: tolerance * 60) }
    var body: some View {
        let m = matches; let conflicts = m.filter { model.store.versions[$0.id]?.latitude != nil }.count
        VStack(alignment: .leading, spacing: 8) {
            Text(model.L("Geotag with a GPS Track", "Mit GPS-Track verorten")).font(Theme.font(14, bold: true))
            HStack { Text(file.isEmpty ? model.L("No track loaded", "Kein Track geladen") : "\(file) – \(track.count) " + model.L("points", "Punkte")).font(Theme.small); Spacer()
                Button(model.L("Open .gpx…", ".gpx öffnen …")) { let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]; if p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) { track = GPX.parse(d); file = u.lastPathComponent; model.addTrack(name: u.deletingPathExtension().lastPathComponent, data: d) } }.buttonStyle(AquaButtonStyle()) }
            if let a = track.first, let b = track.last { Text("\(a.time.formatted(date: .abbreviated, time: .shortened)) – \(b.time.formatted(date: .abbreviated, time: .shortened)) (UTC → local)").font(Theme.tiny).foregroundColor(.gray) }
            Stepper(model.L("Camera clock is ahead by \(Int(offset)) s", "Kamerauhr geht \(Int(offset)) s vor"), value: $offset, in: -86400...86400, step: 1)
            Stepper(model.L("Camera time zone vs. UTC: " + String(format: "%+.0f", zone) + " h", "Zeitzone der Kamera gegenüber UTC: " + String(format: "%+.0f", zone) + " Std."), value: $zone, in: -14...14, step: 1)
            Stepper(model.L("Tolerance: \(Int(tolerance)) min", "Toleranz: \(Int(tolerance)) Min."), value: $tolerance, in: 1...120)
            Text(model.L("\(m.count) of \(targets.count) photos would be placed" + (conflicts > 0 ? "; \(conflicts) already have a location" : ""), "\(m.count) von \(targets.count) Fotos würden verortet" + (conflicts > 0 ? "; \(conflicts) haben schon einen Ort" : ""))).font(Theme.small)
            if conflicts > 0 { Toggle(model.L("Overwrite existing locations", "Vorhandene Orte überschreiben"), isOn: $overwrite).toggleStyle(.checkbox).font(Theme.small) }
            HStack { Spacer(); Button(model.L("Cancel", "Abbrechen")) { model.showGPX = false }.buttonStyle(AquaButtonStyle())
                Button(model.L("Apply", "Anwenden")) { apply(m) }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction).disabled(m.isEmpty) }
        }.padding(16).frame(width: 500).background(Theme.chrome)
    }
    func apply(_ m: [GPX.Match]) {
        let use = m.filter { overwrite || model.store.versions[$0.id]?.latitude == nil }
        let before = use.compactMap { model.store.versions[$0.id] }
        for x in use { try? model.store.assignLocation([x.id], lat: x.lat, lon: x.lon) }
        model.pushUndo(model.L("GPS Track", "GPS-Track"), undo: { let mm = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) }); try? model.store.update(Array(mm.keys)) { $0 = mm[$0.id] ?? $0 } }, redo: { for x in use { try? model.store.assignLocation([x.id], lat: x.lat, lon: x.lon) } })
        model.status = model.L("\(use.count) photos placed from the track", "\(use.count) Fotos aus dem Track verortet"); model.showGPX = false
    }
}

/// Manage My Places : place list and landmark search on the left, map with the selected place's circle on the right.
struct MyPlacesSheet: View {
    @ObservedObject var model: AppModel
    @State private var selected: ID?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var pending: MKMapItem?
    @State private var mapKind = 0
    @State private var labels = true
    @State private var focus: CLLocationCoordinate2D?
    var place: MyPlace? { model.myPlaces.places.first { $0.id == selected } }
    func edit(_ f: (inout MyPlace) -> Void) { guard var p = place else { return }; f(&p); model.myPlaces.add(p); model.configChanged() }
    func search() {
        guard !query.isEmpty else { results = []; return }
        searching = true
        let req = MKLocalSearch.Request(); req.naturalLanguageQuery = query
        MKLocalSearch(request: req).start { r, _ in searching = false; results = r?.mapItems ?? [] }
    }
    var body: some View {
        let _ = model.configTick
        VStack(alignment: .leading, spacing: 8) {
            Text(model.L("Manage My Places", "Meine Orte verwalten")).font(Theme.font(13, bold: true))
            Text(model.L("Select one of your places to move the center point, adjust its size, rename it, or delete the place. To create a new place, search for a landmark. Then select a result and press the \"+\" button, move the center point, adjust its size and name the place.",
                         "Wähle einen deiner Orte, um den Mittelpunkt zu verschieben, die Größe anzupassen, ihn umzubenennen oder zu löschen. Um einen neuen Ort anzulegen, suche nach einem Wahrzeichen, wähle ein Ergebnis und klicke auf „+“. Dann Mittelpunkt verschieben, Größe anpassen und den Ort benennen.")).font(Theme.tiny).foregroundColor(.gray).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 6) {
                    HStack { Image(systemName: "magnifyingglass").font(.system(size: 11)); TextField(model.L("Search", "Suchen"), text: $query, onCommit: search).textFieldStyle(.plain).font(Theme.small)
                        if searching { ProgressView().controlSize(.small) } }.padding(5).background(Color.white).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.4))).cornerRadius(10)
                    List(selection: Binding(get: { pending.map { "r\($0.hashValue)" } ?? selected }, set: { id in
                        if let id, id.hasPrefix("r"), let it = results.first(where: { "r\($0.hashValue)" == id }) { pending = it; selected = nil; focus = it.placemark.coordinate }
                        else { pending = nil; selected = id; if let p = place { focus = CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude) } } })) {
                        if !results.isEmpty { Section(model.L("Search Results", "Suchergebnisse")) {
                            ForEach(results, id: \.self) { Text($0.name ?? "—").font(Theme.small).tag("r\($0.hashValue)") } } }
                        Section(model.L("My Places", "Meine Orte")) { ForEach(model.myPlaces.places) { Text($0.name).font(Theme.small).tag($0.id as String?) } }
                    }.frame(width: 228)
                    HStack(spacing: 4) {
                        Button("+") {
                            if let it = pending { let c = it.placemark.coordinate; let np = MyPlace(name: it.name ?? model.L("New Place", "Neuer Ort"), latitude: c.latitude, longitude: c.longitude); model.myPlaces.add(np); model.configChanged(); selected = np.id; pending = nil }
                            else if let v = model.primaryVersion, let la = v.latitude, let lo = v.longitude { let np = MyPlace(name: v.name, latitude: la, longitude: lo); model.myPlaces.add(np); model.configChanged(); selected = np.id; focus = CLLocationCoordinate2D(latitude: la, longitude: lo) }
                        }.buttonStyle(AquaButtonStyle()).help(model.L("Add the selected search result (or the primary photo's location)", "Gewähltes Suchergebnis (oder Ort des primären Fotos) hinzufügen"))
                        Button("−") { if let id = selected { model.myPlaces.remove(id); model.configChanged(); selected = nil } }.buttonStyle(AquaButtonStyle()).disabled(selected == nil)
                        Spacer()
                    }
                }
                VStack(spacing: 0) {
                    PlaceEditMap(center: Binding(get: { place.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }, set: { c in if let c { edit { $0.latitude = c.latitude; $0.longitude = c.longitude } } }),
                                 radius: place?.radius ?? 0, kind: mapKind, labels: labels, focus: focus).frame(maxWidth: .infinity, maxHeight: .infinity)
                    AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
                        HStack(spacing: 8) {
                            Text(model.L("Place Name:", "Ortsname:")).font(Theme.tiny).fixedSize()
                            TextField("", text: Binding(get: { place?.name ?? "" }, set: { n in edit { $0.name = n } })).textFieldStyle(.roundedBorder).frame(width: 96).disabled(place == nil)
                            Text(model.L("Size:", "Größe:")).font(Theme.tiny).fixedSize()
                            Slider(value: Binding(get: { log10(max(10, place?.radius ?? 150)) }, set: { v in edit { $0.radius = (pow(10, v) / 10).rounded() * 10 } }), in: 1...4.5).frame(width: 56).disabled(place == nil)
                            Text(place.map { $0.radius >= 1000 ? String(format: "%.1f km", $0.radius / 1000) : "\(Int($0.radius)) m" } ?? "").font(Theme.tiny).frame(width: 44, alignment: .leading).fixedSize()
                            Toggle(model.L("Show Labels", "Beschriftungen"), isOn: $labels).toggleStyle(.checkbox).font(Theme.tiny).fixedSize()
                            Spacer()
                            Picker("", selection: $mapKind) { Text(model.L("Satellite", "Satellit")).tag(1); Text(model.L("Road", "Straße")).tag(0); Text(model.L("Terrain", "Gelände")).tag(2) }.pickerStyle(.segmented).labelsHidden().frame(width: 150).controlSize(.small)
                        }.foregroundColor(.black).padding(.horizontal, 8).frame(height: 31)
                    }
                }.frame(maxWidth: .infinity).overlay(Rectangle().stroke(Color.black.opacity(0.5)))
            }
            HStack { Text(model.L("Click the map to move the center point of the selected place.", "Auf die Karte klicken, um den Mittelpunkt des gewählten Orts zu verschieben.")).font(Theme.tiny).foregroundColor(.gray); Spacer()
                Button(model.L("Done", "Fertig")) { model.showMyPlaces = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(14).frame(width: 825, height: 600).background(Theme.chrome)
        .onAppear { if selected == nil, let f = model.myPlaces.places.first { selected = f.id; focus = CLLocationCoordinate2D(latitude: f.latitude, longitude: f.longitude) } }
    }
}

/// Map for the place editor: draws the selected place as a circle and moves its center on click.
struct PlaceEditMap: NSViewRepresentable {
    @Binding var center: CLLocationCoordinate2D?
    var radius: Double, kind: Int, labels: Bool, focus: CLLocationCoordinate2D?
    func makeCoordinator() -> Coord { Coord() }
    func makeNSView(context: Context) -> MKMapView {
        let m = MKMapView(); m.delegate = context.coordinator
        m.addGestureRecognizer(NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coord.click(_:))))
        context.coordinator.map = m; return m
    }
    func updateNSView(_ m: MKMapView, context: Context) {
        let c = context.coordinator; c.onMove = { new in center = new }
        m.mapType = kind == 1 ? .satellite : .standard
        if kind != 1 { let cfg = MKStandardMapConfiguration(elevationStyle: kind == 2 ? .realistic : .flat); cfg.pointOfInterestFilter = labels ? .includingAll : .excludingAll; m.preferredConfiguration = cfg }
        m.removeOverlays(m.overlays)
        if let ce = center, radius > 0 { m.addOverlay(MKCircle(center: ce, radius: radius)); c.hasCenter = true } else { c.hasCenter = false }
        if let f = focus, f.latitude != c.lastFocus?.latitude || f.longitude != c.lastFocus?.longitude {
            c.lastFocus = f; m.setRegion(MKCoordinateRegion(center: f, latitudinalMeters: max(2000, radius * 6), longitudinalMeters: max(2000, radius * 6)), animated: true)
        }
    }
    final class Coord: NSObject, MKMapViewDelegate {
        weak var map: MKMapView?; var onMove: ((CLLocationCoordinate2D) -> Void)?; var hasCenter = false; var lastFocus: CLLocationCoordinate2D?
        @objc func click(_ g: NSClickGestureRecognizer) {
            guard hasCenter, let m = map else { return }
            onMove?(m.convert(g.location(in: m), toCoordinateFrom: m))
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let r = MKCircleRenderer(overlay: overlay); r.fillColor = NSColor.systemBlue.withAlphaComponent(0.25); r.strokeColor = .systemBlue; r.lineWidth = 2; return r
        }
    }
}

/// Places breadcrumb as usual: [home] [Countries ▾][States/Provinces ▾][Cities ▾][Places ▾], title, search.
struct Breadcrumb: View {
    @ObservedObject var model: AppModel
    var path: [String] { if case .location(let p) = model.source { return p }; return [] }
    struct Loc: Hashable { var country: String, state: String, city: String, place: String }
    var locs: [Loc] { Array(Set(model.store.versions.values.filter { !$0.trashed && $0.latitude != nil }.map { Loc(country: $0.meta["place.country"] ?? "Unknown", state: $0.meta["place.state"] ?? "", city: $0.meta["place.city"] ?? "", place: $0.meta["place.name"] ?? "") })) }
    func seg(_ title: String, _ items: [(String, [String])]) -> some View {
        Menu {
            Button(model.L("All", "Alle")) { model.source = .all }
            Divider()
            ForEach(items.indices, id: \.self) { i in Button(items[i].0.isEmpty ? model.L("(no name)", "(ohne Namen)") : items[i].0) { model.source = .location(items[i].1) } }
        } label: { Text(title + " ▾").font(Theme.font(11)).foregroundColor(.black).lineLimit(1) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
    func uniq(_ xs: [(String, [String])]) -> [(String, [String])] { var seen = Set<String>(); return xs.filter { seen.insert($0.1.joined(separator: "\u{1}")).inserted }.sorted { $0.0 < $1.0 } }
    var body: some View {
        let L = locs
        let ctry = uniq(L.map { ($0.country, [$0.country]) })
        let st = uniq(L.filter { $0.state != "" && (path.isEmpty || $0.country == path[0]) }.map { ($0.state, [$0.country, $0.state]) })
        let ci = uniq(L.filter { $0.city != "" && (path.count < 2 || ($0.country == path[0] && $0.state == path[1])) }.map { ($0.city, [$0.country, $0.state, $0.city]) })
        let pl = uniq(L.filter { $0.place != "" && (path.count < 3 || ($0.country == path[0] && $0.state == path[1] && $0.city == path[2])) }.map { ($0.place, [$0.country, $0.state, $0.city, $0.place]) })
        AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
            HStack(spacing: 6) {
                if !path.isEmpty { Button(model.L("Back", "Zurück")) { model.source = path.count <= 1 ? .all : .location(Array(path.dropLast())) }.buttonStyle(AquaButtonStyle()) }
                HStack(spacing: 0) {
                    Button { model.source = .all } label: { Image(systemName: "house.fill").font(.system(size: 11)).frame(width: 26, height: 20) }.buttonStyle(.plain)
                    ForEach(Array([(path.first ?? model.L("\(ctry.count) Countries", "\(ctry.count) Länder"), ctry), (path.count > 1 ? path[1] : model.L("\(st.count) States/Provinces", "\(st.count) Bundesländer"), st), (path.count > 2 ? path[2] : model.L("\(ci.count) Cities", ci.count == 1 ? "1 Stadt" : "\(ci.count) Städte"), ci), (path.count > 3 ? path[3] : model.L(pl.count == 1 ? "1 Place" : "\(pl.count) Places", pl.count == 1 ? "1 Ort" : "\(pl.count) Orte"), pl)].enumerated()), id: \.offset) { _, s in
                        Rectangle().fill(Color.black.opacity(0.3)).frame(width: 1, height: 20)
                        seg(s.0, s.1).padding(.horizontal, 8)
                    }
                }.background(LinearGradient(colors: [.white, Theme.hex(0xD8D8D8)], startPoint: .top, endPoint: .bottom)).cornerRadius(4).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.45), lineWidth: 0.7))
                Spacer()
                Text(model.L("Places in “\(model.title)”", "Orte in „\(model.title)“")).font(Theme.font(12, bold: true))
                Spacer()
                HStack(spacing: 3) { Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundColor(.gray)
                    TextField("", text: $model.placesSearch, onCommit: search).textFieldStyle(.plain).font(Theme.tiny).frame(width: 220) }
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.white).cornerRadius(9).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.4)))
            }.padding(.horizontal, 10).frame(height: 30)
        }
    }
    func search() {   // jump the map to a searched place
        guard !model.placesSearch.isEmpty, let m = model.mapRef as? MKMapView else { return }
        let req = MKLocalSearch.Request(); req.naturalLanguageQuery = model.placesSearch
        MKLocalSearch(request: req).start { r, _ in if let c = r?.mapItems.first?.placemark.coordinate { m.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: 20_000, longitudinalMeters: 20_000), animated: true) } }
    }
}

struct PlacesBottomBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
            HStack(spacing: 8) {
                Menu { Button(model.L("Assign Location…", "Ort zuweisen …")) { model.showAssignLocation = true }; Button(model.L("Remove Locations", "Orte entfernen")) { model.removeLocations() }; Button(model.L("Place Names", "Ortsnamen ermitteln")) { model.updatePlaceNames() }; Button(model.L("My Places…", "Meine Orte …")) { model.showMyPlaces = true } } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).frame(width: 34)
                Menu {
                    Button(model.L("Import GPS Track…", "GPS-Track importieren …")) { model.showGPX = true }
                    Divider()
                    ForEach(model.gpsTracks.indices, id: \.self) { i in Button((model.gpsTracks[i].visible ? "✓ " : "   ") + model.gpsTracks[i].name) { model.gpsTracks[i].visible.toggle() } }
                    if model.gpsTracks.isEmpty { Text(model.L("no tracks loaded", "keine Tracks geladen")) }
                } label: { Text("GPS").font(Theme.tiny) }.menuStyle(.borderlessButton).frame(width: 60)
                Toggle(model.L("Show Labels", "Beschriftungen"), isOn: $model.showMapLabels).toggleStyle(.checkbox).font(Theme.tiny)
                Button(model.L("Move Pins", "Pins bewegen")) { model.movePins.toggle() }.buttonStyle(AquaButtonStyle()).background(model.movePins ? Theme.hex(0x9DB7DC) : Color.clear).cornerRadius(4)
                Spacer()
                Picker("", selection: $model.mapKind) { Text(model.L("Satellite", "Satellit")).tag(1); Text(model.L("Road", "Straße")).tag(0); Text(model.L("Terrain", "Gelände")).tag(2) }.pickerStyle(.segmented).labelsHidden().frame(width: 200).controlSize(.small)
            }.padding(.horizontal, 8).frame(height: 28)
        }
    }
}

/// Small map with the primary photo's location (inspector, as usual).
struct MiniMap: NSViewRepresentable {
    var lat: Double, lon: Double
    func makeNSView(context: Context) -> MKMapView { let m = MKMapView(); m.isZoomEnabled = true; m.showsZoomControls = true; return m }
    func updateNSView(_ m: MKMapView, context: Context) {
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        m.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: 15_000, longitudinalMeters: 15_000), animated: false)
        m.removeAnnotations(m.annotations); let a = MKPointAnnotation(); a.coordinate = c; m.addAnnotation(a)
    }
}

/// Welcome text of the Places view while no photo has a location .
struct PlacesIntro: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.L("Places", "Orte")).font(Theme.font(26, bold: true))
            Text(model.L("Explore your library based on where your photos were taken.", "Entdecke deine Bibliothek danach, wo die Fotos aufgenommen wurden.")).font(Theme.font(15))
            Divider()
            Text(model.L("Assigning locations to your photos", "Orte zu Fotos zuweisen")).font(Theme.font(13, bold: true))
            Text(model.L("Photos with GPS data are automatically plotted on the interactive map. To assign locations yourself, just drag your photos onto the map.", "Fotos mit GPS-Daten erscheinen automatisch auf der interaktiven Karte. Um Orte selbst zuzuweisen, ziehe die Fotos einfach auf die Karte.")).font(Theme.font(11))
            Text(model.L("Import data from GPS track logs", "Daten aus GPS-Tracks importieren")).font(Theme.font(13, bold: true))
            Text(model.L("Assign locations to your photos by importing a standard GPS track log.", "Weise Fotos Orte zu, indem du ein GPS-Track-Protokoll importierst.")).font(Theme.font(11))
        }.foregroundColor(.white).padding(20).frame(width: 440, alignment: .leading).background(Color.black.opacity(0.7)).cornerRadius(10).allowsHitTesting(false)
    }
}

import Foundation

public struct MyPlace: Codable, Identifiable, Equatable, Sendable {
    public var id: ID = newID()
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var radius: Double = 150                  // meters
    public init(name: String, latitude: Double, longitude: Double, radius: Double = 150) { self.name = name; self.latitude = latitude; self.longitude = longitude; self.radius = radius }
}

/// "My Places": named coordinates stored locally (independent of any map or geocoding service –).
public final class MyPlacesStore {
    let url: URL
    public private(set) var places: [MyPlace] = []
    public init(libraryRoot: URL) { url = libraryRoot.appendingPathComponent("Places.json"); if let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([MyPlace].self, from: d) { places = p } }
    func save() { try? JSONEncoder().encode(places).write(to: url, options: .atomic) }
    public func add(_ p: MyPlace) { places.removeAll { $0.id == p.id }; places.append(p); places.sort { $0.name < $1.name }; save() }
    public func remove(_ id: ID) { places.removeAll { $0.id == id }; save() }
    public func nearest(_ lat: Double, _ lon: Double) -> MyPlace? { places.filter { GeoMath.distance(lat, lon, $0.latitude, $0.longitude) <= $0.radius }.min { GeoMath.distance(lat, lon, $0.latitude, $0.longitude) < GeoMath.distance(lat, lon, $1.latitude, $1.longitude) } }
}

public enum GeoMath {
    /// Haversine distance in meters.
    public static func distance(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = 6_371_000.0, p1 = la1 * .pi / 180, p2 = la2 * .pi / 180, dp = (la2 - la1) * .pi / 180, dl = (lo2 - lo1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2); return 2 * r * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}

public struct TrackPoint: Equatable, Sendable { public var lat: Double; public var lon: Double; public var time: Date; public var ele: Double? }

public enum GPX {
    public static func parse(_ data: Data) -> [TrackPoint] {
        final class P: NSObject, XMLParserDelegate {
            var pts: [TrackPoint] = []; var cur: (Double, Double)?; var text = ""; var ele: Double?; var time: Date?
            let f1: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }(); let f2 = ISO8601DateFormatter()
            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
                if e == "trkpt" || e == "rtept" || e == "wpt", let la = a["lat"].flatMap(Double.init), let lo = a["lon"].flatMap(Double.init) { cur = (la, lo); ele = nil; time = nil }; text = ""
            }
            func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
            func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if e == "ele" { ele = Double(t) } else if e == "time" { time = f1.date(from: t) ?? f2.date(from: t) }
                else if (e == "trkpt" || e == "rtept" || e == "wpt"), let c = cur, let tm = time { pts.append(TrackPoint(lat: c.0, lon: c.1, time: tm, ele: ele)); cur = nil }
            }
        }
        let p = P(); let x = XMLParser(data: data); x.delegate = p; x.parse()
        return p.pts.sorted { $0.time < $1.time }
    }

    public struct Match: Sendable { public var id: ID; public var lat: Double; public var lon: Double; public var gap: TimeInterval }
    /// Matches photos to the track. `cameraOffset` = seconds the camera clock is AHEAD of real (UTC) time; `timeZoneShift` hours between camera local time and UTC.
    /// Between two track points closer than `maxGap` the position is interpolated; otherwise the nearest point within `tolerance` is used.
    public static func match(_ versions: [Version], track: [TrackPoint], cameraOffset: TimeInterval = 0, timeZoneShift: Double = 0, tolerance: TimeInterval = 600, maxGap: TimeInterval = 900) -> [Match] {
        guard !track.isEmpty else { return [] }
        var out: [Match] = []
        for v in versions {
            let t = v.imageDate.addingTimeInterval(-cameraOffset - timeZoneShift * 3600)
            var lo = 0, hi = track.count
            while lo < hi { let mid = (lo + hi) / 2; if track[mid].time < t { lo = mid + 1 } else { hi = mid } }
            let after = lo < track.count ? track[lo] : nil, before = lo > 0 ? track[lo - 1] : nil
            if let a = after, let b = before, a.time.timeIntervalSince(b.time) <= maxGap, a.time > b.time {
                let f = t.timeIntervalSince(b.time) / a.time.timeIntervalSince(b.time)
                out.append(Match(id: v.id, lat: b.lat + (a.lat - b.lat) * f, lon: b.lon + (a.lon - b.lon) * f, gap: 0)); continue
            }
            let cands = [before, after].compactMap { $0 }.map { ($0, abs($0.time.timeIntervalSince(t))) }.filter { $0.1 <= tolerance }
            if let c = cands.min(by: { $0.1 < $1.1 }) { out.append(Match(id: v.id, lat: c.0.lat, lon: c.0.lon, gap: c.1)) }
        }
        return out
    }
}

public extension LibraryStore {
    @discardableResult func assignLocation(_ ids: [ID], lat: Double, lon: Double, names: [String: String] = [:]) throws -> Int {
        try update(ids) { v in v.latitude = lat; v.longitude = lon; for (k, val) in names { v.meta[k] = val.isEmpty ? nil : val } }; return ids.count
    }
    func removeLocations(_ ids: [ID]) throws { try update(ids) { v in v.latitude = nil; v.longitude = nil; for k in ["place.country", "place.state", "place.city", "place.name"] { v.meta[k] = nil } } }
    /// Country → state → city → place counts for the Places navigation.
    func locationTree() -> [String: [String: [String: Int]]] {
        var t: [String: [String: [String: Int]]] = [:]
        for v in versions.values where !v.trashed && v.latitude != nil {
            let c = v.meta["place.country"] ?? "Unknown", s = v.meta["place.state"] ?? "", ci = v.meta["place.city"] ?? ""
            t[c, default: [:]][s, default: [:]][ci, default: 0] += 1
        }
        return t
    }
    var geotaggedCount: Int { versions.values.filter { !$0.trashed && $0.latitude != nil }.count }
}

import Foundation
import ImageCaptureCore
import AppKit
import RetroluxCore

/// Cameras and card readers through ImageCaptureCore (PTP/MTP devices macOS supports). Used for camera import and tethered shooting.
/// Note: needs real hardware; the logic below is compiled and unit-reviewed but could not be exercised without a camera.
final class CameraManager: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    @Published var cameras: [ICCameraDevice] = []
    @Published var files: [ICCameraFile] = []
    @Published var connected: ICCameraDevice?
    @Published var ready = false
    @Published var message = ""
    @Published var tethering = false
    @Published var tetherCount = 0
    @Published var lastTether: URL?
    var onTetherFile: ((URL) -> Void)?
    private let browser = ICDeviceBrowser()
    private var tetherStart = Date()
    private var tetherDir: URL?

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue | ICDeviceLocationTypeMask.remote.rawValue)!
        browser.start()
    }
    deinit { browser.stop(); connected?.requestCloseSession() }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        if let c = device as? ICCameraDevice { DispatchQueue.main.async { if !self.cameras.contains(where: { $0 === c }) { self.cameras.append(c) } } }
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        DispatchQueue.main.async { self.cameras.removeAll { $0 === device }; if self.connected === device { self.connected = nil; self.files = []; self.ready = false } }
    }
    func connect(_ cam: ICCameraDevice) { files = []; ready = false; message = "Connecting to \(cam.name ?? "camera")…"; cam.delegate = self; connected = cam; cam.requestOpenSession() }
    func disconnect() { connected?.requestCloseSession(); connected = nil; files = []; ready = false; tethering = false }

    // MARK: ICDeviceDelegate
    func didRemove(_ device: ICDevice) { DispatchQueue.main.async { self.connected = nil; self.ready = false } }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) { DispatchQueue.main.async { self.message = error?.localizedDescription ?? "Session open – reading catalog…" } }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) { DispatchQueue.main.async { self.ready = true; self.message = "\(self.files.count) items" } }
    // MARK: ICCameraDeviceDelegate
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        let fs = items.compactMap { $0 as? ICCameraFile }
        DispatchQueue.main.async {
            self.files.append(contentsOf: fs)
            if self.tethering { for f in fs where (f.creationDate ?? Date()) >= self.tetherStart.addingTimeInterval(-2) { self.downloadTether(f) } }
        }
    }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { DispatchQueue.main.async { self.files.removeAll { f in items.contains { $0 === f } } } }
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}

    // MARK: download / tether
    func download(_ items: [ICCameraFile], to dir: URL, progress: @escaping (Int, Int) -> Void, done: @escaping ([URL]) -> Void) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []; let q = DispatchQueue(label: "rl.camera"); let group = DispatchGroup()
        for (i, f) in items.enumerated() {
            group.enter()
            let opts: [ICDownloadOption: Any] = [.downloadsDirectoryURL: dir, .overwrite: true, .saveAsFilename: f.name ?? "img_\(i).jpg"]
            f.requestDownload(options: opts) { name, err in
                q.async { if err == nil, let name { out.append(dir.appendingPathComponent(name)) }; progress(out.count, items.count); group.leave() }
            }
        }
        group.notify(queue: .main) { done(out.sorted { $0.lastPathComponent < $1.lastPathComponent }) }
    }
    func startTether(into dir: URL) { tetherDir = dir; try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); tetherStart = Date(); tethering = true; tetherCount = 0; lastTether = nil }
    func stopTether() { tethering = false }
    private func downloadTether(_ f: ICCameraFile) {
        guard let dir = tetherDir else { return }
        download([f], to: dir, progress: { _, _ in }) { urls in if let u = urls.first { self.tetherCount += 1; self.lastTether = u; self.onTetherFile?(u) } }
    }
    func capture() { if let c = connected, c.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue) { c.requestTakePicture() } else { message = "This camera cannot be triggered remotely." } }
    var canCapture: Bool { connected?.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue) == true }
}

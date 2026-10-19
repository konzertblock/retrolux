import XCTest
import CoreImage
@testable import RetroluxCore

final class ToneStageTests: XCTestCase {
    func pixel(_ p: ToneParams) -> [Float] {
        var buf: [Float] = [0.2, 0.3, 0.1, 1,  0.8, 0.7, 0.9, 1,  0.0, 0.0, 0.0, 1,  1.5, 1.2, 0.9, 1]
        ToneStageKernel.process(&buf, w: 4, h: 1, p: p.array)
        return buf
    }
    func testIdentityKeepsPixels() {
        let b = pixel(ToneParams()); XCTAssertEqual(b[0], 0.2, accuracy: 1e-5); XCTAssertEqual(b[4], 0.8, accuracy: 1e-5)
    }
    func testBlackPointVibranceSaturationAreFinite() {
        var p = ToneParams(); p.biasSlope = 1.005; p.biasOffset = 0.005; p.saturation = 1.08; p.vibrance = 0.157
        let b = pixel(p); XCTAssertTrue(b.allSatisfy { $0.isFinite }, "\(b)")
        XCTAssertGreaterThan(b[4], 0.5)
    }
}

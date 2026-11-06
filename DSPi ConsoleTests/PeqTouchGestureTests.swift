#if os(iOS)
import XCTest
@testable import DSPi_Console

/// The touch editor's drag mapping (PeqTouchEditor.dragged): what a finger
/// moving a band's dot changes, by the band's role, the touch counterpart of
/// the macOS editor's drag cases in PeqGraphEditorTests.
final class PeqTouchGestureTests: XCTestCase {

    /// 20 Hz to 20 kHz over 300 pt (100 pt per decade), +25 to -25 dB over 250 pt.
    private let g = PeqGraphGeometry(size: CGSize(width: 300, height: 250),
                                     minFreq: 20, maxFreq: 20_000, dbTop: 25, dbBottom: -25)

    func testBellFollowsWithFrequencyAndGain() {
        let bell = FilterParams(type: .peaking, freq: 1000, q: 1, gain: 0)
        let p = PeqTouchEditor.dragged(bell, by: CGSize(width: 100, height: -50), in: g)
        XCTAssertEqual(Double(p.freq), 10_000, accuracy: 1)        // one decade right
        XCTAssertEqual(Double(p.gain), 10, accuracy: 0.01)         // 50 pt up at 0.2 dB/pt
        XCTAssertEqual(p.q, 1)
        XCTAssertEqual(p.type, .peaking)
    }

    func testGainIsClampedAndFrequencyBounded() {
        let bell = FilterParams(type: .peaking, freq: 1000, q: 1, gain: 20)
        let p = PeqTouchEditor.dragged(bell, by: CGSize(width: 10_000, height: -10_000), in: g)
        XCTAssertEqual(Double(p.gain), PeqLimits.gain.upperBound)
        XCTAssertEqual(Double(p.freq), PeqLimits.freq.upperBound, accuracy: 1)
    }

    func testSecondOrderCutChangesQNotGain() {
        let lowPass = FilterParams(type: .lowPass, freq: 2000, q: 0.707, gain: 0)
        let p = PeqTouchEditor.dragged(lowPass, by: CGSize(width: 0, height: -30), in: g)
        // The dot sits at 20 log10(Q); 30 pt up is +6 dB, so Q doubles.
        XCTAssertEqual(Double(p.q), 0.707 * pow(10, 6.0 / 20), accuracy: 0.001)
        XCTAssertEqual(p.gain, 0)
        XCTAssertEqual(Double(p.freq), 2000, accuracy: 0.5)
    }

    func testNotchMovesInFrequencyOnly() {
        let notch = FilterParams(type: .notch, freq: 500, q: 5, gain: 0)
        let p = PeqTouchEditor.dragged(notch, by: CGSize(width: -100, height: 80), in: g)
        XCTAssertEqual(Double(p.freq), 50, accuracy: 0.1)
        XCTAssertEqual(p.q, 5)
        XCTAssertEqual(p.gain, 0)
    }

    func testShelfGainFollowsItsDotScale() {
        let shelf = FilterParams(type: .lowShelf, freq: 100, q: 0.707, gain: 0)
        guard case .gain(let scale) = PeqNodeRole.of(shelf) else { return XCTFail("a shelf drags gain") }
        let p = PeqTouchEditor.dragged(shelf, by: CGSize(width: 0, height: -25), in: g)
        // 25 pt up = +5 dB at the dot, which is `scale` dB per dB of gain.
        XCTAssertEqual(Double(p.gain), 5 / scale, accuracy: 0.01)
    }

    func testLinkwitzTransformIsNotDragged() {
        let lt = FilterParams(type: .linkwitzTransform, freq: 40, q: 0.7, gain: 0)
        XCTAssertEqual(PeqTouchEditor.dragged(lt, by: CGSize(width: 50, height: -50), in: g), lt)
    }
}
#endif

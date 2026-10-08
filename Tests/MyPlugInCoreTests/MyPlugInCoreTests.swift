import AudioToolbox
import XCTest
@testable import MyPlugInCore

final class MyPlugInCoreTests: XCTestCase {
    func testFourCC() {
        XCTAssertEqual(MyFXFourCC("MRev"), 0x4D52_6576)
        XCTAssertEqual(MyFXFourCC("Toka"), 0x546F_6B61)
    }

    func testMeterPeaksAreTakenOnce() {
        let peaks = MyFXMeterPeaks()
        let left: [Float] = [0.1, -0.6, 0.2]
        let right: [Float] = [0.3, 0.1, -0.2]
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                peaks.recordInput(l.baseAddress!, r.baseAddress!, 3)
                peaks.recordOutput(r.baseAddress!, l.baseAddress!, 3)
            }
        }
        XCTAssertEqual(peaks.take(), MyFXPeaks(inputLeft: 0.6, inputRight: 0.3, outputLeft: 0.3, outputRight: 0.6))
        XCTAssertEqual(peaks.take(), MyFXPeaks())
    }

    func testMeterStateHoldsAndFalls() {
        var state = MyFXMeterState()
        state.update(left: 0.8, right: 0.4, interval: 1.0 / 30)
        state.update(left: 0, right: 0, interval: 1.0 / 30)
        XCTAssertEqual(state.holdLeft, 0.8)
        XCTAssertLessThan(state.left, 0.8)
        XCTAssertEqual(state.maximum, 0.8)
        for _ in 0..<60 { state.update(left: 0, right: 0, interval: 1.0 / 30) }
        XCTAssertLessThan(state.holdLeft, 0.8, "hold lets go after 1.5 s")
    }

    func testMeterScaleMatchesMyDAW() {
        XCTAssertEqual(MyFXMeterScale.fraction(forDecibels: 0), 0.84, accuracy: 1e-9)
        XCTAssertEqual(MyFXMeterScale.label(forLevel: 1), "0.0")
        XCTAssertEqual(MyFXMeterScale.label(forLevel: 0), "-∞")
    }

    func testBaseUnitCannotBeInstantiated() {
        let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 1,
                                                    componentManufacturer: 1, componentFlags: 0, componentFlagsMask: 0)
        XCTAssertThrowsError(try MyFXAudioUnit(componentDescription: description, options: []))
    }
}

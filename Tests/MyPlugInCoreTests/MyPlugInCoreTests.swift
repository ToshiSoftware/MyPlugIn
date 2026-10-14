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

    func testMeterStateLatchesClipUntilCleared() {
        var state = MyFXMeterState()
        state.update(left: 0.999, right: 0.5, interval: 1.0 / 30)
        XCTAssertFalse(state.clipped)
        state.update(left: 0.2, right: 1.0, interval: 1.0 / 30)
        XCTAssertTrue(state.clipped)
        state.update(left: 0, right: 0, interval: 1.0 / 30)
        XCTAssertTrue(state.clipped)
        state.clearPeaks()
        XCTAssertFalse(state.clipped)
        XCTAssertEqual(state.maximum, 0)
    }

    func testNoteLengthsAtTheHostTempo() {
        let tempo = MyFXTempo()
        XCTAssertEqual(tempo.beatsPerMinute, 120)
        XCTAssertEqual(tempo.seconds(.quarter, .normal), 0.5, accuracy: 1e-12)
        XCTAssertEqual(tempo.seconds(.quarter, .dotted), 0.75, accuracy: 1e-12)
        XCTAssertEqual(tempo.seconds(.eighth, .triplet), 0.25 * 2 / 3, accuracy: 1e-12)
        XCTAssertEqual(tempo.seconds(.sixtyFourth, .normal), 0.5 / 16, accuracy: 1e-12)
        XCTAssertEqual(tempo.seconds(.half, .normal), 1, accuracy: 1e-12)
        XCTAssertEqual(tempo.seconds(.fourBars, .normal), 8, accuracy: 1e-12)
        tempo.update(beatsPerMinute: 60, numerator: 3, denominator: 4)
        XCTAssertEqual(tempo.seconds(.oneBar, .normal), 3, accuracy: 1e-12)
        tempo.update(beatsPerMinute: 60, numerator: 6, denominator: 8)
        XCTAssertEqual(tempo.seconds(.twoBars, .normal), 6, accuracy: 1e-12)
        tempo.update(beatsPerMinute: 0, numerator: 0, denominator: 0)
        XCTAssertEqual(tempo.beatsPerMinute, 60, "no tempo: keep the last one")
        XCTAssertEqual(tempo.beatsPerBar, 3)
    }

    func testCyclePhaseFromTheSongPosition() {
        let tempo = MyFXTempo()
        XCTAssertNil(tempo.cyclePhase(.oneBar, .normal), "not playing")
        tempo.updatePosition(beatPosition: 6)
        XCTAssertEqual(tempo.cyclePhase(.oneBar, .normal)!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(tempo.cyclePhase(.quarter, .dotted)!, 0, accuracy: 1e-12) // 6 / 1.5 = 4 cycles
        XCTAssertEqual(tempo.cyclePhase(.twoBars, .normal)!, 0.75, accuracy: 1e-12)
        let count = tempo.renderCount
        tempo.updatePosition(beatPosition: nil)
        XCTAssertFalse(tempo.isMoving)
        XCTAssertEqual(tempo.renderCount, count + 1)
    }

    func testNoteValueStrings() {
        XCTAssertEqual(MyFXNoteValue.displayString(.eighth, .dotted), "1/8D")
        XCTAssertEqual(MyFXNoteValue.displayString(.fourBars, .triplet), "4 barT")
        for length in MyFXNoteLength.allCases {
            for type in MyFXNoteType.allCases {
                let parsed = MyFXNoteValue.parse(MyFXNoteValue.displayString(length, type))
                XCTAssertEqual(parsed?.0, length)
                XCTAssertEqual(parsed?.1, type)
            }
        }
        XCTAssertEqual(MyFXNoteValue.parse("2 bars")?.0, .twoBars)
        XCTAssertEqual(MyFXNoteValue.parse("1/16.")?.1, .dotted)
        XCTAssertEqual(MyFXNoteValue.parse("1/8 t")?.1, .triplet)
        XCTAssertNil(MyFXNoteValue.parse("1/3"))
    }
}

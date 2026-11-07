import AVFoundation
import XCTest
@testable import MyTuner
import MyPlugInCore

final class MyTunerTests: XCTestCase {
    /// A plucked-string-like tone: harmonics falling off as 1/n, the
    /// fundamental at `fundamentalLevel` of its 1/n level.
    private func tone(_ frequency: Double, sampleRate: Double, seconds: Double, harmonics: Int = 1,
                      fundamentalLevel: Double = 1, amplitude: Float = 0.5) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            var sum = 0.0
            for harmonic in 1...harmonics where frequency * Double(harmonic) < sampleRate / 2 {
                let level = (harmonic == 1 ? fundamentalLevel : 1) / Double(harmonic)
                sum += level * sin(2 * .pi * frequency * Double(harmonic) * time)
            }
            return amplitude * Float(sum / Double(harmonics == 1 ? 1 : 2))
        }
    }

    /// Feeds `input` through a kernel in 512-frame blocks and returns the
    /// analyzer's last pitch.
    private func detect(_ input: [Float], sampleRate: Double) -> TunerAnalyzer.Update {
        let kernel = TunerKernel()
        kernel.prepare(sampleRate: sampleRate, maximumFrames: 512)
        kernel.isAnalyzing = true
        let analyzer = TunerAnalyzer(kernel: kernel)
        var output = [Float](repeating: 0, count: 512)
        var last = TunerAnalyzer.Update.none
        var start = 0
        while start < input.count {
            let count = min(512, input.count - start)
            input.withUnsafeBufferPointer { inPointer in
                output.withUnsafeMutableBufferPointer { outPointer in
                    let source = inPointer.baseAddress! + start
                    kernel.process(inputLeft: source, inputRight: source,
                                   outputLeft: outPointer.baseAddress!, outputRight: nil, frameCount: count)
                }
            }
            let update = analyzer.update()
            if update != .none { last = update }
            start += count
        }
        return last
    }

    private func cents(_ update: TunerAnalyzer.Update, from frequency: Double,
                       file: StaticString = #filePath, line: UInt = #line) -> Double {
        guard case .pitch(let detected) = update else {
            XCTFail("No pitch for \(frequency) Hz: \(update)", file: file, line: line)
            return .infinity
        }
        return 1_200 * log2(detected / frequency)
    }

    // MARK: Detection

    func testSineAccuracyAcrossRangeAndRates() {
        for sampleRate in [44_100.0, 48_000, 96_000] {
            for frequency in [41.2, 82.41, 110, 146.83, 196, 246.94, 329.63, 523.25, 880, 1_174.66, 1_480] {
                let error = cents(detect(tone(frequency, sampleRate: sampleRate, seconds: 0.4),
                                         sampleRate: sampleRate), from: frequency)
                XCTAssertLessThan(abs(error), 0.5, "\(frequency) Hz at \(sampleRate): \(error) cents")
            }
        }
    }

    func testRichToneWithWeakFundamentalKeepsItsOctave() {
        for frequency in [82.41, 110, 146.83, 196, 246.94, 329.63] {
            let input = tone(frequency, sampleRate: 48_000, seconds: 0.5, harmonics: 12, fundamentalLevel: 0.3)
            let error = cents(detect(input, sampleRate: 48_000), from: frequency)
            XCTAssertLessThan(abs(error), 1, "\(frequency) Hz: \(error) cents")
        }
    }

    func testDetuneIsMeasured() {
        let frequency = 110 * pow(2, 7.0 / 1_200) // A2 +7 cents
        let error = cents(detect(tone(frequency, sampleRate: 48_000, seconds: 0.4, harmonics: 6),
                                 sampleRate: 48_000), from: 110)
        XCTAssertEqual(error, 7, accuracy: 0.5)
    }

    func testSilenceAndNoiseGiveNoPitch() {
        XCTAssertEqual(detect([Float](repeating: 0, count: 24_000), sampleRate: 48_000), .silence)
        // -66 dBFS: below the gate.
        XCTAssertEqual(detect(tone(110, sampleRate: 48_000, seconds: 0.4, amplitude: 0.0005), sampleRate: 48_000),
                       .silence)
        var seed: UInt64 = 12_345
        let noise: [Float] = (0..<24_000).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: seed >> 1) % 20_000) / 20_000 * 0.5
        }
        XCTAssertEqual(detect(noise, sampleRate: 48_000), .silence)
    }

    func testSingleOctaveJumpIsIgnored() {
        let rate = 48_000.0
        let low = tone(110, sampleRate: rate, seconds: 0.4)
        // Then 220 Hz: its first detection is an octave jump and is held back once.
        let analyzerInput = low + tone(220, sampleRate: rate, seconds: 0.4)
        let kernel = TunerKernel()
        kernel.prepare(sampleRate: rate, maximumFrames: 4_096)
        kernel.isAnalyzing = true
        let analyzer = TunerAnalyzer(kernel: kernel)
        var updates: [TunerAnalyzer.Update] = []
        var output = [Float](repeating: 0, count: 256)
        for start in stride(from: 0, to: analyzerInput.count, by: 256) {
            let count = min(256, analyzerInput.count - start)
            analyzerInput.withUnsafeBufferPointer { inPointer in
                output.withUnsafeMutableBufferPointer { outPointer in
                    let source = inPointer.baseAddress! + start
                    kernel.process(inputLeft: source, inputRight: source,
                                   outputLeft: outPointer.baseAddress!, outputRight: nil, frameCount: count)
                }
            }
            let update = analyzer.update()
            if update != .none { updates.append(update) }
        }
        let pitches = updates.compactMap { update -> Double? in
            if case .pitch(let frequency) = update { return frequency }
            return nil
        }
        guard let firstHigh = pitches.firstIndex(where: { $0 > 200 }) else {
            return XCTFail("Never reached 220 Hz: \(pitches)")
        }
        // The detection before the first 220 was 220 too, but reported as 110.
        XCTAssertEqual(pitches[firstHigh - 1], 110, accuracy: 1)
        XCTAssertEqual(pitches.last ?? 0, 220, accuracy: 1)
    }

    // MARK: Notes

    func testNotesAndCents() {
        for calibration in [430.0, 440, 450] {
            let a4 = TunerNote(frequency: calibration, calibration: calibration, mode: .chromatic)
            XCTAssertEqual(a4?.name, "A")
            XCTAssertEqual(a4?.octave, 4)
            XCTAssertEqual(a4?.cents ?? 1, 0, accuracy: 1e-9)
        }
        let lowE = TunerNote(frequency: 82.41, calibration: 440, mode: .chromatic)
        XCTAssertEqual(lowE?.name, "E")
        XCTAssertEqual(lowE?.octave, 2)
        let c4 = TunerNote(frequency: 261.63, calibration: 440, mode: .chromatic)
        XCTAssertEqual(c4?.name, "C")
        XCTAssertEqual(c4?.octave, 4)
        // 49 cents above A4 is still A; 51 is A♯ -49.
        let nearlyHalf = TunerNote(frequency: 440 * pow(2, 0.49 / 12), calibration: 440, mode: .chromatic)
        XCTAssertEqual(nearlyHalf?.name, "A")
        XCTAssertEqual(nearlyHalf?.cents ?? 0, 49, accuracy: 1e-6)
        let overHalf = TunerNote(frequency: 440 * pow(2, 0.51 / 12), calibration: 440, mode: .chromatic)
        XCTAssertEqual(overHalf?.name, "A♯")
        XCTAssertEqual(overHalf?.cents ?? 0, -49, accuracy: 1e-6)
    }

    func testGuitarModePicksTheNearestString() {
        let expected: [(Double, Int, String)] = [
            (82.41, 6, "E"), (110, 5, "A"), (146.83, 4, "D"), (196, 3, "G"), (246.94, 2, "B"), (329.63, 1, "E")
        ]
        for (frequency, string, name) in expected {
            let note = TunerNote(frequency: frequency * 1.01, calibration: 440, mode: .guitar)
            XCTAssertEqual(note?.guitarString, string)
            XCTAssertEqual(note?.name, name)
        }
        // A drop-D low string reads as string 6, 200 cents flat.
        let dropD = TunerNote(frequency: 73.42, calibration: 440, mode: .guitar)
        XCTAssertEqual(dropD?.guitarString, 6)
        XCTAssertEqual(dropD?.cents ?? 0, -200, accuracy: 0.5)
        XCTAssertNil(TunerNote(frequency: 110, calibration: 440, mode: .chromatic)?.guitarString)
    }

    // MARK: Display

    func testDisplayHoldsThenFades() {
        var state = TunerDisplayState()
        let tick = 1.0 / 60
        state.advance(.pitch(110 * pow(2, 10.0 / 1_200)), calibration: 440, mode: .chromatic, interval: tick)
        XCTAssertEqual(state.needleCents, 10, accuracy: 1e-6) // a new note jumps
        state.advance(.silence, calibration: 440, mode: .chromatic, interval: tick)
        for _ in 0..<27 { state.advance(.none, calibration: 440, mode: .chromatic, interval: tick) }
        XCTAssertEqual(state.brightness, 1) // still held at 0.47 s
        for _ in 0..<15 { state.advance(.none, calibration: 440, mode: .chromatic, interval: tick) }
        XCTAssertLessThan(state.brightness, 1)
        XCTAssertGreaterThan(state.brightness, 0)
        XCTAssertNotNil(state.frequency)
        for _ in 0..<30 { state.advance(.none, calibration: 440, mode: .chromatic, interval: tick) }
        XCTAssertEqual(state.brightness, 0)
        XCTAssertNil(state.frequency)
    }

    func testNeedleGlidesAndInTune() {
        var state = TunerDisplayState()
        let tick = 1.0 / 60
        state.advance(.pitch(110 * pow(2, 20.0 / 1_200)), calibration: 440, mode: .chromatic, interval: tick)
        state.advance(.pitch(110), calibration: 440, mode: .chromatic, interval: tick)
        XCTAssertGreaterThan(state.needleCents, 15) // glides, does not jump on the same note
        XCTAssertFalse(state.isInTune)
        for _ in 0..<60 { state.advance(.pitch(110), calibration: 440, mode: .chromatic, interval: tick) }
        XCTAssertEqual(state.needleCents, 0, accuracy: 0.05)
        XCTAssertTrue(state.isInTune)
        // The needle stops at the end of the scale (drop D in Guitar mode: -200 cents).
        state.advance(.pitch(73.42), calibration: 440, mode: .guitar, interval: 1.0 / 60)
        XCTAssertEqual(state.needleCents, -50, accuracy: 1e-6)
    }

    func testStrobeMovesWithTheDetune() {
        var sharp = TunerDisplayState()
        var flat = TunerDisplayState()
        var inTune = TunerDisplayState()
        for _ in 0..<10 {
            sharp.advance(.pitch(110 * pow(2, 3.0 / 1_200)), calibration: 440, mode: .chromatic, interval: 0.01)
            flat.advance(.pitch(110 * pow(2, -3.0 / 1_200)), calibration: 440, mode: .chromatic, interval: 0.01)
            inTune.advance(.pitch(110), calibration: 440, mode: .chromatic, interval: 0.01)
        }
        XCTAssertEqual(sharp.strobePhase, 0.03, accuracy: 1e-6)
        XCTAssertEqual(flat.strobePhase, 0.97, accuracy: 1e-6)
        XCTAssertEqual(inTune.strobePhase, 0)
    }

    // MARK: Unit

    func testSoundPassesThroughUnchanged() {
        let kernel = TunerKernel()
        kernel.prepare(sampleRate: 48_000, maximumFrames: 512)
        kernel.isAnalyzing = true
        let left: [Float] = (0..<512).map { Float($0 % 9) * 0.05 - 0.2 }
        let right: [Float] = (0..<512).map { Float($0 % 7) * -0.03 }
        var outLeft = [Float](repeating: 0, count: 512)
        var outRight = [Float](repeating: 0, count: 512)
        kernel.process(inputLeft: left, inputRight: right, outputLeft: &outLeft, outputRight: &outRight,
                       frameCount: 512)
        XCTAssertEqual(outLeft, left)
        XCTAssertEqual(outRight, right)
    }

    func testNoCaptureUnlessAnalyzing() {
        let kernel = TunerKernel()
        kernel.prepare(sampleRate: 48_000, maximumFrames: 512)
        let input = [Float](repeating: 0.1, count: 512)
        var output = [Float](repeating: 0, count: 512)
        kernel.process(inputLeft: input, inputRight: input, outputLeft: &output, outputRight: nil, frameCount: 512)
        XCTAssertEqual(kernel.writtenCount, 0)
        kernel.isAnalyzing = true
        kernel.process(inputLeft: input, inputRight: input, outputLeft: &output, outputRight: nil, frameCount: 512)
        XCTAssertEqual(kernel.writtenCount, 128)
        XCTAssertEqual(kernel.decimatedSampleRate, 12_000)
    }

    func testParameterStrings() {
        XCTAssertEqual(TunerParameter.calibration.displayString(for: 440), "440.0 Hz")
        XCTAssertEqual(TunerParameter.calibration.value(fromDisplayString: "442.3 Hz"), 442.5)
        XCTAssertEqual(TunerParameter.calibration.value(fromDisplayString: "500"), 450)
        XCTAssertEqual(TunerParameter.mode.value(fromDisplayString: "guitar"), 1)
        XCTAssertEqual(TunerParameter.mode.displayString(for: 0), "Chromatic")
        XCTAssertEqual(TunerParameter.strobe.displayString(for: 1), "On")
    }

    /// The way MyDAW drives the tuner: not in a graph, but its render block
    /// called with one mono input channel in pieces of up to 1024 frames.
    func testRenderBlockWithPulledMonoInput() throws {
        let unit = try MyTunerAudioUnit(componentDescription: MyTunerAudioUnit.componentDescription)
        let rate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = 1_024
        try unit.allocateRenderResources()
        unit.tunerKernel.isAnalyzing = true
        let analyzer = TunerAnalyzer(kernel: unit.tunerKernel)
        let signal = tone(196, sampleRate: rate, seconds: 0.5, harmonics: 8)
        let input = UnsafeMutablePointer<Float>.allocate(capacity: 1_024)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 1_024)
        defer { input.deallocate(); output.deallocate() }
        let pull: AURenderPullInputBlock = { _, _, frameCount, _, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            buffers[0].mData = UnsafeMutableRawPointer(input)
            buffers[0].mDataByteSize = frameCount * 4
            return noErr
        }
        let outputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outputList.unsafeMutablePointer) }
        var last = TunerAnalyzer.Update.none
        var start = 0
        while start < signal.count {
            let count = min(1_024, signal.count - start)
            signal.withUnsafeBufferPointer { input.update(from: $0.baseAddress! + start, count: count) }
            outputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: output)
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = Double(start)
            timestamp.mFlags = .sampleTimeValid
            let status = unit.renderBlock(&flags, &timestamp, AUAudioFrameCount(count), 0,
                                          outputList.unsafeMutablePointer, pull)
            XCTAssertEqual(status, noErr)
            XCTAssertEqual(output[count - 1], input[count - 1])
            let update = analyzer.update()
            if update != .none { last = update }
            start += count
        }
        XCTAssertLessThan(abs(cents(last, from: 196)), 0.5)
    }

    func testUnitAndEditor() throws {
        let unit = try MyTunerAudioUnit(componentDescription: MyTunerAudioUnit.componentDescription)
        XCTAssertEqual(unit.parameterTree?.allParameters.map(\.identifier), TunerParameter.allCases.map(\.identifier))
        XCTAssertEqual(unit.makeEditorViewController().view.frame.size, MyTunerAudioUnit.editorSize)
        XCTAssertEqual(unit.latency, 0)
    }
}

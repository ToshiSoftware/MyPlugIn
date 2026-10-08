import XCTest
@testable import MyReverb

final class ReverbKernelTests: XCTestCase {
    private let blockSize = 512

    // MARK: Helpers

    private func makeKernel(sampleRate: Double = 48_000,
                            _ values: [ReverbParameter: Float] = [:]) -> ReverbKernel {
        let kernel = ReverbKernel()
        for (parameter, value) in values { kernel.setTarget(parameter, value) }
        kernel.prepare(sampleRate: sampleRate, maximumFrames: blockSize)
        return kernel
    }

    /// Runs `input` (stereo, L = R unless `right` is given) through the
    /// kernel in blocks; `beforeBlock` can change parameters between blocks.
    private func render(_ kernel: ReverbKernel, left: [Float], right: [Float]? = nil,
                        beforeBlock: (Int) -> Void = { _ in }) -> (left: [Float], right: [Float]) {
        var outLeft = left
        var outRight = right ?? left
        let inRight = right ?? left
        var start = 0
        var block = 0
        while start < left.count {
            beforeBlock(block)
            let count = min(blockSize, left.count - start)
            left.withUnsafeBufferPointer { inL in
                inRight.withUnsafeBufferPointer { inR in
                    outLeft.withUnsafeMutableBufferPointer { oL in
                        outRight.withUnsafeMutableBufferPointer { oR in
                            kernel.process(inputLeft: inL.baseAddress! + start,
                                           inputRight: inR.baseAddress! + start,
                                           outputLeft: oL.baseAddress! + start,
                                           outputRight: oR.baseAddress! + start,
                                           frameCount: count)
                        }
                    }
                }
            }
            start += count
            block += 1
        }
        return (outLeft, outRight)
    }

    private func impulse(seconds: Double, sampleRate: Double = 48_000) -> [Float] {
        var signal = [Float](repeating: 0, count: Int(seconds * sampleRate))
        signal[0] = 1
        return signal
    }

    private func noise(seconds: Double, sampleRate: Double = 48_000, amplitude: Float = 0.5) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * sampleRate)).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    private func sine(_ frequency: Double, seconds: Double, sampleRate: Double = 48_000, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    /// T60 from a T20 fit of the Schroeder backward integral (-5 to -25 dB).
    private func measuredT60(_ response: [Float], sampleRate: Double = 48_000) -> Double {
        var energy = [Double](repeating: 0, count: response.count)
        var sum = 0.0
        for index in stride(from: response.count - 1, through: 0, by: -1) {
            sum += Double(response[index] * response[index])
            energy[index] = sum
        }
        func time(at decibels: Double) -> Double {
            let threshold = energy[0] * pow(10, decibels / 10)
            let index = energy.firstIndex { $0 <= threshold } ?? energy.count
            return Double(index) / sampleRate
        }
        return (time(at: -25) - time(at: -5)) * 3
    }

    private func rms(_ signal: ArraySlice<Float>) -> Double {
        (signal.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(signal.count, 1))).squareRoot()
    }

    private let wetOnly: [ReverbParameter: Float] = [.mix: 100, .preDelay: 0, .hpf: 0, .lpf: 24_000]

    // MARK: Reverb time

    /// The old unit decayed in about half the set RT (one gain for all lines).
    func testReverbTimeMatchesSettingWithoutDamping() {
        for reverbTime: Float in [0.5, 2, 8] {
            var values = wetOnly
            values[.rt] = reverbTime
            let kernel = makeKernel(values)
            kernel.highFrequencyRatio = 1
            kernel.reset()
            let response = render(kernel, left: impulse(seconds: Double(reverbTime) * 1.2 + 0.3)).left
            let measured = measuredT60(response)
            XCTAssertEqual(measured, Double(reverbTime), accuracy: Double(reverbTime) * 0.15,
                           "RT \(reverbTime) s measured \(measured) s")
        }
    }

    func testDampedLowFrequencyReverbTimeMatchesSetting() {
        var values = wetOnly
        values[.rt] = 3
        values[.lpf] = 400 // isolate the low band, where RT is specified
        let kernel = makeKernel(values)
        let response = render(kernel, left: impulse(seconds: 4)).left
        let measured = measuredT60(response)
        XCTAssertEqual(measured, 3, accuracy: 0.6, "measured \(measured) s")
    }

    func testReverbTimeAtOtherSampleRates() {
        for sampleRate in [44_100.0, 96_000.0] {
            var values = wetOnly
            values[.rt] = 1
            let kernel = makeKernel(sampleRate: sampleRate, values)
            kernel.highFrequencyRatio = 1
            kernel.reset()
            let response = render(kernel, left: impulse(seconds: 1.5, sampleRate: sampleRate)).left
            XCTAssertEqual(measuredT60(response, sampleRate: sampleRate), 1, accuracy: 0.15, "at \(sampleRate) Hz")
        }
    }

    /// The all-pass in each feedback path must not change RT (its mean
    /// delay is counted in the loop length).
    func testLoopDiffusionKeepsReverbTime() {
        var values = wetOnly
        values[.rt] = 2
        let kernel = makeKernel(values)
        XCTAssertEqual(kernel.loopDiffusion, 0.5)
        kernel.highFrequencyRatio = 1
        kernel.reset()
        let response = render(kernel, left: impulse(seconds: 2.7)).left
        XCTAssertEqual(measuredT60(response), 2, accuracy: 0.2)
    }

    // MARK: Levels and stability

    func testLongestReverbTimeStaysBoundedWithNoise() {
        var values = wetOnly
        values[.rt] = 60
        let kernel = makeKernel(values)
        let input = noise(seconds: 20)
        let output = render(kernel, left: input).left
        XCTAssertTrue(output.allSatisfy { $0.isFinite })
        let outputRMS = rms(output[(output.count / 2)...])
        XCTAssertLessThan(outputRMS, 2 * rms(input[...]), "wet RMS \(outputRMS)")
        XCTAssertLessThan(output.map(abs).max()!, 4)
    }

    func testTypicalWetLevelIsNearInputLevel() {
        let kernel = makeKernel(wetOnly)
        let input = noise(seconds: 6)
        let output = render(kernel, left: input).left
        let ratio = rms(output[(output.count / 2)...]) / rms(input[...])
        XCTAssertGreaterThan(ratio, 0.3)
        XCTAssertLessThan(ratio, 2.0)
    }

    func testStereoOutputIsDecorrelated() {
        let kernel = makeKernel(wetOnly)
        let (left, right) = render(kernel, left: impulse(seconds: 1))
        XCTAssertNotEqual(left, right)
    }

    // MARK: Mix, pre-delay, reset, bypass

    func testMixZeroPassesDryUnchanged() {
        let kernel = makeKernel([.mix: 0])
        let input = noise(seconds: 0.5)
        XCTAssertEqual(render(kernel, left: input).left, input)
    }

    func testPreDelayDelaysTheWetOnset() {
        var values = wetOnly
        values[.preDelay] = 0.1
        let kernel = makeKernel(values)
        let output = render(kernel, left: impulse(seconds: 0.5)).left
        let onset = output.firstIndex { abs($0) > 1e-6 }!
        XCTAssertGreaterThanOrEqual(onset, 4_800)
        XCTAssertLessThan(onset, 4_800 + 400)
    }

    /// The old unit stopped writing its buffer at 0 ms and replayed it later.
    func testPreDelayDoesNotReplayStaleAudio() {
        var values = wetOnly
        values[.preDelay] = 0.2
        let kernel = makeKernel(values)
        _ = render(kernel, left: noise(seconds: 0.5))
        kernel.setTarget(.preDelay, 0)
        kernel.setTarget(.rt, 0.1)
        _ = render(kernel, left: [Float](repeating: 0, count: 48_000))
        kernel.setTarget(.preDelay, 0.2)
        let output = render(kernel, left: [Float](repeating: 0, count: 24_000)).left
        XCTAssertLessThan(output.map(abs).max()!, 1e-4)
    }

    func testResetClearsTheTail() {
        var values = wetOnly
        values[.rt] = 10
        let kernel = makeKernel(values)
        _ = render(kernel, left: noise(seconds: 1))
        kernel.requestReset()
        let output = render(kernel, left: [Float](repeating: 0, count: 4_800)).left
        XCTAssertLessThan(output.map(abs).max()!, 1e-6)
    }

    func testBypassPassesInputAndRestartsEmpty() {
        let kernel = makeKernel(wetOnly)
        _ = render(kernel, left: noise(seconds: 1))
        kernel.isBypassed = true
        let input = noise(seconds: 0.2)
        XCTAssertEqual(render(kernel, left: input).left, input)
        kernel.isBypassed = false
        let after = render(kernel, left: [Float](repeating: 0, count: 4_800)).left
        XCTAssertLessThan(after.map(abs).max()!, 1e-6)
    }

    // MARK: Filters

    private func filterGain(highPass: Bool, cutoff: Double, at frequency: Double) -> Double {
        let sampleRate = 48_000.0
        let coefficients = Butterworth3Coefficients(cutoff: cutoff, sampleRate: sampleRate)
        var state = Butterworth3State()
        let input = sine(frequency, seconds: 1, amplitude: 1)
        let output = input.map { state.process($0, coefficients, highPass: highPass) }
        return 20 * log10(rms(output[24_000...]) / rms(input[24_000...]))
    }

    func testButterworthResponse() {
        XCTAssertEqual(filterGain(highPass: false, cutoff: 8_000, at: 8_000), -3.01, accuracy: 0.2)
        XCTAssertEqual(filterGain(highPass: true, cutoff: 1_000, at: 1_000), -3.01, accuracy: 0.2)
        // 3rd order: 18 dB per octave well beyond the cutoff.
        XCTAssertEqual(filterGain(highPass: false, cutoff: 1_000, at: 4_000), -36.1, accuracy: 1.0)
        XCTAssertEqual(filterGain(highPass: true, cutoff: 1_000, at: 250), -36.1, accuracy: 1.0)
        XCTAssertEqual(filterGain(highPass: false, cutoff: 8_000, at: 500), 0, accuracy: 0.05)
    }

    /// At 96 kHz the old unit still low-passed at 24 kHz when showing "Thru".
    func testLowPassThruIsTransparentAtHighSampleRates() {
        let sampleRate = 96_000.0
        let thru = makeKernel(sampleRate: sampleRate, [.mix: 100, .lpf: 24_000, .hpf: 0, .rt: 0.3])
        let filtered = makeKernel(sampleRate: sampleRate, [.mix: 100, .lpf: 23_000, .hpf: 0, .rt: 0.3])
        let input = noise(seconds: 0.5, sampleRate: sampleRate)
        // Second difference: weights energy toward the top octave (24 to 48 kHz).
        func highBand(_ s: [Float]) -> Double {
            rms(Array(zip(zip(s.dropFirst(2), s.dropFirst()), s).map { $0.0 - 2 * $0.1 + $1 })[...])
        }
        let thruHigh = highBand(render(thru, left: input).left)
        let filteredHigh = highBand(render(filtered, left: input).left)
        XCTAssertGreaterThan(thruHigh, filteredHigh * 1.5, "Thru \(thruHigh), 23 kHz LPF \(filteredHigh)")
    }

    /// Moving the cutoffs every block must not click: the largest step
    /// between samples stays near that of the unmodulated output.
    func testFilterSweepsDoNotClick() {
        var values = wetOnly
        values[.mix] = 100
        values[.rt] = 1
        let input = sine(220, seconds: 3)
        let steady = makeKernel(values)
        let reference = render(steady, left: input).left
        let swept = makeKernel(values)
        let output = render(swept, left: input) { block in
            swept.setTarget(.lpf, block % 2 == 0 ? 300 : 12_000)
            swept.setTarget(.hpf, block % 2 == 0 ? 600 : 0)
        }.left
        func maxStep(_ s: [Float]) -> Float { zip(s.dropFirst(), s).map { abs($0 - $1) }.max()! }
        XCTAssertLessThan(maxStep(output), maxStep(reference) * 2 + 0.01)
        XCTAssertTrue(output.allSatisfy { $0.isFinite })
    }

    func testMixAndPreDelayChangesDoNotClick() {
        let input = sine(220, seconds: 2)
        let kernel = makeKernel([.mix: 0])
        let output = render(kernel, left: input) { block in
            kernel.setTarget(.mix, block % 4 < 2 ? 0 : 100)
            kernel.setTarget(.preDelay, block % 3 == 0 ? 0 : 0.5)
        }.left
        let inputStep = zip(input.dropFirst(), input).map { abs($0 - $1) }.max()!
        let outputStep = zip(output.dropFirst(), output).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(outputStep, inputStep * 3 + 0.02)
    }

    // MARK: Parameters

    func testParameterDisplayStrings() {
        XCTAssertEqual(ReverbParameter.hpf.displayString(for: 0), "Thru")
        XCTAssertEqual(ReverbParameter.hpf.displayString(for: 80), "80 Hz")
        XCTAssertEqual(ReverbParameter.lpf.displayString(for: 24_000), "Thru")
        XCTAssertEqual(ReverbParameter.preDelay.displayString(for: 0.02), "20 ms")
        XCTAssertEqual(ReverbParameter.preDelay.value(fromDisplayString: "250 ms"), 0.25)
        XCTAssertEqual(ReverbParameter.lpf.value(fromDisplayString: "Thru"), 24_000)
        XCTAssertEqual(ReverbParameter.lpf.displayString(for: 8_000), "8.00 kHz")
        XCTAssertEqual(ReverbParameter.lpf.value(fromDisplayString: "8.00 kHz"), 8_000)
        XCTAssertEqual(ReverbParameter.lpf.value(fromDisplayString: "12k"), 12_000)
        XCTAssertEqual(ReverbParameter.hpf.value(fromDisplayString: "120"), 120)
        XCTAssertEqual(ReverbParameter.rt.value(fromDisplayString: "2.5 s"), 2.5)
        XCTAssertEqual(ReverbParameter.preDelay.value(fromDisplayString: "0.1 s"), 0.1)
        XCTAssertEqual(ReverbParameter.mix.value(fromDisplayString: "35%"), 35)
        XCTAssertEqual(ReverbParameter.rt.clamped(100), 60)
        XCTAssertEqual(ReverbParameter.rt.clamped(.nan), 2)
    }

    // MARK: Performance

    func testRendersMuchFasterThanRealTime() {
        let kernel = makeKernel()
        let input = noise(seconds: 10)
        let start = Date()
        _ = render(kernel, left: input)
        let elapsed = Date().timeIntervalSince(start)
        // Debug builds are slow; this only catches gross regressions.
        XCTAssertLessThan(elapsed, 10, "10 s of audio took \(elapsed) s")
        print("Rendered 10 s of stereo audio in \(String(format: "%.3f", elapsed)) s")
    }
}

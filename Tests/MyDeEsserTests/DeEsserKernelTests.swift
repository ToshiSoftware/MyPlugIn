import XCTest
@testable import MyDeEsser
import MyPlugInCore

final class DeEsserKernelTests: XCTestCase {
    private let rate = 48_000.0
    private let block = 512

    private func makeKernel(_ settings: [DeEsserParameter: Float] = [:], sampleRate: Double = 48_000) -> DeEsserKernel {
        let kernel = DeEsserKernel()
        for (parameter, value) in settings { kernel.setTarget(parameter, value) }
        kernel.prepare(sampleRate: sampleRate, maximumFrames: block)
        return kernel
    }

    /// Renders in blocks; `right` nil renders mono. `change` runs before the
    /// block that starts at or after `at`.
    private func render(_ kernel: DeEsserKernel, _ left: [Float], _ right: [Float]? = nil,
                        at changeFrame: Int? = nil, change: (() -> Void)? = nil) -> ([Float], [Float]?) {
        var outLeft = left
        var outRight = right
        var offset = 0
        var changed = false
        while offset < left.count {
            if let changeFrame, !changed, offset >= changeFrame {
                change?()
                changed = true
            }
            let count = min(block, left.count - offset)
            left.withUnsafeBufferPointer { inL in
                outLeft.withUnsafeMutableBufferPointer { outL in
                    if let right {
                        right.withUnsafeBufferPointer { inR in
                            outRight!.withUnsafeMutableBufferPointer { outR in
                                kernel.process(inputLeft: inL.baseAddress! + offset, inputRight: inR.baseAddress! + offset,
                                               outputLeft: outL.baseAddress! + offset,
                                               outputRight: outR.baseAddress! + offset, frameCount: count)
                            }
                        }
                    } else {
                        kernel.process(inputLeft: inL.baseAddress! + offset, inputRight: inL.baseAddress! + offset,
                                       outputLeft: outL.baseAddress! + offset, outputRight: nil, frameCount: count)
                    }
                }
            }
            offset += count
        }
        return (outLeft, outRight)
    }

    private func sine(_ frequency: Double, decibels: Float, seconds: Double, rate: Double = 48_000) -> [Float] {
        let amplitude = pow(10, decibels / 20)
        return (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    private func linear(_ decibels: Double) -> Double { pow(10, decibels / 20) }
    private func decibels(_ level: Double) -> Double { 20 * log10(level) }

    /// Amplitude of the `frequency` component over the last `seconds`
    /// (a whole number of cycles of the frequencies used here).
    private func amplitude(of frequency: Double, in samples: [Float], seconds: Double = 0.1, rate: Double = 48_000) -> Double {
        let count = Int(seconds * rate)
        let start = samples.count - count
        var re = 0.0
        var im = 0.0
        for index in 0..<count {
            let phase = 2 * .pi * frequency * Double(start + index) / rate
            re += Double(samples[start + index]) * cos(phase)
            im += Double(samples[start + index]) * sin(phase)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(count)
    }

    // MARK: Crossover

    func testFlatWhenNothingIsLimited() {
        for crossover: Float in [2_000, 6_500, 15_000] {
            for frequency in [100.0, 1_000, 2_000, 5_000, 6_500, 10_000, 15_000, 18_000] {
                let kernel = makeKernel([.threshold: 0, .frequency: crossover])
                let input = sine(frequency, decibels: -20, seconds: 0.4)
                let (output, _) = render(kernel, input)
                let ratio = decibels(amplitude(of: frequency, in: output) / amplitude(of: frequency, in: input))
                XCTAssertEqual(ratio, 0, accuracy: 0.01, "\(frequency) Hz, crossover \(crossover)")
            }
        }
    }

    func testResponseFormulaMatchesTheFilters() {
        for gain in [0.5, 0.1] {
            for frequency in [1_000.0, 4_000, 6_000, 6_500, 8_000, 12_000, 18_000] {
                var crossover = DeEsserCrossover()
                let coefficients = DeEsserFilterCoefficients(frequency: 6_500, sampleRate: rate)
                let input = sine(frequency, decibels: 0, seconds: 0.3)
                let output = input.map { x -> Float in
                    let bands = crossover.process(Double(x), coefficients)
                    return Float(bands.low + gain * bands.high)
                }
                let measured = amplitude(of: frequency, in: output)
                let expected = DeEsserCrossover.response(at: frequency, crossover: 6_500, gain: gain, sampleRate: rate)
                XCTAssertEqual(decibels(measured), decibels(expected), accuracy: 0.05, "\(frequency) Hz, g \(gain)")
            }
        }
    }

    func testResponseDipsMonotonicallyWithoutABump() {
        for gain in [0.5, 0.1] {
            var previous = 2.0
            for step in 0...200 {
                let frequency = 500 * pow(40, Double(step) / 200)
                let response = DeEsserCrossover.response(at: frequency, crossover: 6_500, gain: gain, sampleRate: rate)
                XCTAssertLessThanOrEqual(response, 1 + 1e-12)
                XCTAssertGreaterThanOrEqual(response, gain - 1e-12)
                XCTAssertLessThanOrEqual(response, previous + 1e-12, "not monotonic at \(frequency) Hz")
                previous = response
            }
        }
    }

    // MARK: Limiting

    func testOnlyTheConsonantBandIsTurnedDown() {
        let threshold = -30.0
        let kernel = makeKernel([.threshold: Float(threshold)])
        let (high, _) = render(kernel, sine(10_000, decibels: -10, seconds: 0.4))
        let lowPart = 1 / (1 + pow(tan(.pi * 10_000 / rate) / tan(.pi * 6_500 / rate), 4))
        let expected = lowPart * linear(-10) + linear(threshold)
        XCTAssertEqual(decibels(amplitude(of: 10_000, in: high)), decibels(expected), accuracy: 0.5)
        XCTAssertLessThan(decibels(amplitude(of: 10_000, in: high)), -20)

        let lowKernel = makeKernel([.threshold: Float(threshold)])
        let low = sine(500, decibels: -10, seconds: 0.4)
        let (lowOut, _) = render(lowKernel, low)
        XCTAssertEqual(decibels(amplitude(of: 500, in: lowOut) / amplitude(of: 500, in: low)), 0, accuracy: 0.1)

        let mixKernel = makeKernel([.threshold: Float(threshold)])
        let mix = zip(low, sine(10_000, decibels: -10, seconds: 0.4)).map { $0 + $1 }
        let (mixOut, _) = render(mixKernel, mix)
        XCTAssertEqual(decibels(amplitude(of: 500, in: mixOut) / amplitude(of: 500, in: low)), 0, accuracy: 0.1)
        XCTAssertLessThan(decibels(amplitude(of: 10_000, in: mixOut)), -20)
    }

    /// The output's high-band part: output minus the delayed low band.
    private func limitedHighBand(_ input: [Float], output: [Float], frequency: Double = 6_500) -> [Double] {
        var crossover = DeEsserCrossover()
        let coefficients = DeEsserFilterCoefficients(frequency: frequency, sampleRate: rate)
        let low = input.map { crossover.process(Double($0), coefficients).low }
        let delay = DeEsserKernel.lookAhead(sampleRate: rate)
        return output.indices.map { $0 >= delay ? Double(output[$0]) - low[$0 - delay] : Double(output[$0]) }
    }

    func testLookAheadHoldsTheThresholdFromTheFirstPeak() {
        var burst = [Float](repeating: 0, count: 2_400)
        burst += sine(9_000, decibels: 0, seconds: 0.1)
        let threshold: Float = -24
        let kernel = makeKernel([.threshold: threshold])
        let (output, _) = render(kernel, burst)
        let high = limitedHighBand(burst, output: output)
        let peak = high.map(abs).max()!
        XCTAssertLessThanOrEqual(peak, linear(Double(threshold)) * 1.001)

        let slow = makeKernel([.threshold: threshold, .attack: 5])
        let (slowOutput, _) = render(slow, burst)
        let slowPeak = limitedHighBand(burst, output: slowOutput).map(abs).max()!
        XCTAssertGreaterThan(decibels(slowPeak), Double(threshold) + 6, "a long ATTACK lets the head through")
    }

    func testReleaseFollowsItsTimeConstant() {
        for milliseconds: Float in [5, 10, 50] {
            var chain = DeEsserGainChain()
            let lookAhead = DeEsserKernel.lookAhead(sampleRate: rate)
            chain.prepare(lookAhead: lookAhead)
            let release = DeEsserKernel.coefficient(milliseconds: milliseconds, sampleRate: rate)
            for _ in 0..<2_000 { chain.process(wanted: 0.1, attack: 1, release: release) }
            XCTAssertEqual(chain.gain, 0.1, accuracy: 1e-5)
            // The hold keeps it down for D+1 frames, the mean centres the ramp D/2 later.
            let releaseFrames = Int(Double(milliseconds) / 1_000 * rate)
            let frames = lookAhead + 1 + lookAhead / 2 + releaseFrames
            for _ in 0..<frames { chain.process(wanted: 1, attack: 1, release: release) }
            XCTAssertEqual(Double(chain.gain), 1 - 0.9 * exp(-1.0), accuracy: 0.9 * exp(-1.0) * 0.1, "\(milliseconds) ms")
        }
    }

    func testReductionReading() {
        let kernel = makeKernel([.threshold: -20])
        _ = render(kernel, sine(10_000, decibels: -10, seconds: 0.2))
        _ = kernel.takeReadings()
        _ = render(kernel, sine(10_000, decibels: -10, seconds: 0.1))
        let readings = kernel.takeReadings()
        let highPart = decibels(1 - 1 / (1 + pow(tan(.pi * 10_000 / rate) / tan(.pi * 6_500 / rate), 4)))
        XCTAssertEqual(Double(readings.reductionLeft), -20 - (-10 + highPart), accuracy: 0.5)
        XCTAssertEqual(Double(readings.reductionLeft), -8.6, accuracy: 0.5)
        XCTAssertEqual(decibels(Double(readings.sibilanceLeft)), -10 + highPart, accuracy: 0.3)
    }

    func testStereoLink() {
        let left = sine(10_000, decibels: -10, seconds: 0.3)
        let right = sine(500, decibels: -10, seconds: 0.3)

        let linked = makeKernel([.threshold: -20])
        _ = render(linked, left, right)
        let linkedReadings = linked.takeReadings()
        XCTAssertLessThan(linkedReadings.reductionLeft, -6)
        XCTAssertEqual(linkedReadings.reductionRight, linkedReadings.reductionLeft, accuracy: 0.01)

        let separate = makeKernel([.threshold: -20, .stereoLink: 0])
        let (_, separateRight) = render(separate, left, right)
        let separateReadings = separate.takeReadings()
        XCTAssertLessThan(separateReadings.reductionLeft, -6)
        XCTAssertEqual(separateReadings.reductionRight, 0)
        XCTAssertEqual(decibels(amplitude(of: 500, in: separateRight!) / amplitude(of: 500, in: right)), 0, accuracy: 0.05)
    }

    func testListenPlaysTheConsonantBand() {
        let kernel = makeKernel([.listen: 1, .threshold: -40])
        let low = sine(500, decibels: -6, seconds: 0.3)
        let high = sine(10_000, decibels: -6, seconds: 0.3)
        let (output, _) = render(kernel, zip(low, high).map { $0 + $1 })
        let highPart = 1 - 1 / (1 + pow(tan(.pi * 10_000 / rate) / tan(.pi * 6_500 / rate), 4))
        XCTAssertLessThan(decibels(amplitude(of: 500, in: output) / linear(-6)), -40)
        XCTAssertEqual(decibels(amplitude(of: 10_000, in: output) / linear(-6)), decibels(highPart), accuracy: 0.05)
    }

    // MARK: Latency and bypass

    func testLatencyIsTheLookAhead() {
        let kernel = makeKernel()
        XCTAssertEqual(kernel.latencySamples, 96)
        XCTAssertEqual(makeKernel(sampleRate: 44_100).latencySamples, 88)
        var impulse = [Float](repeating: 0, count: 1_024)
        impulse[100] = 0.5
        let (output, _) = render(kernel, impulse)
        XCTAssertTrue(output[..<196].allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(abs(output[196]), 0.1)

        let bypassed = makeKernel()
        bypassed.isBypassed = true
        bypassed.requestReset()
        let (dry, _) = render(bypassed, impulse)
        XCTAssertEqual(dry[196], 0.5)
        XCTAssertEqual(dry.reduce(0) { $0 + abs($1) }, 0.5)
    }

    func testMonoMatchesStereo() {
        let input = zip(sine(700, decibels: -6, seconds: 0.2), sine(9_000, decibels: -6, seconds: 0.2)).map { $0 + $1 }
        let (mono, _) = render(makeKernel([.threshold: -30]), input)
        let (stereo, _) = render(makeKernel([.threshold: -30]), input, input)
        XCTAssertEqual(mono, stereo)
    }

    // MARK: No clicks

    private func maximumStep(_ samples: ArraySlice<Float>) -> Float {
        zip(samples.dropFirst(), samples).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    func testChangesDoNotClick() {
        let input = zip(sine(800, decibels: -12, seconds: 0.6), sine(8_000, decibels: -18, seconds: 0.6)).map { $0 + $1 }
        let inputStep = maximumStep(input[...])
        let changes: [(String, Float, (DeEsserKernel) -> Void)] = [
            ("input gain", 4, { $0.setTarget(.inputGain, 12) }),
            ("frequency", 1, { $0.setTarget(.frequency, 15_000) }),
            ("frequency down", 1, { $0.setTarget(.frequency, 2_000) }),
            ("threshold", 1, { $0.setTarget(.threshold, -60) }),
            ("stereo link", 1, { $0.setTarget(.stereoLink, 0) }),
            ("listen", 1, { $0.setTarget(.listen, 1) }),
            ("bypass", 1, { $0.isBypassed = true })
        ]
        for (name, scale, change) in changes {
            let kernel = makeKernel([.threshold: -20])
            let left = input
            let right = input.map { $0 * 0.5 }
            let (output, _) = render(kernel, left, right, at: 14_400) { change(kernel) }
            XCTAssertLessThan(maximumStep(output[200...]), inputStep * scale * 1.3, name)
            XCTAssertTrue(output.allSatisfy(\.isFinite), name)
        }
    }

    func testStableAtEverySampleRate() {
        for sampleRate in [44_100.0, 48_000, 96_000] {
            let kernel = makeKernel([.frequency: 15_000, .threshold: -30], sampleRate: sampleRate)
            var state: UInt32 = 7
            let noise: [Float] = (0..<Int(sampleRate)).map { _ in
                state = state &* 1_664_525 &+ 1_013_904_223
                return Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.5
            }
            let (output, _) = render(kernel, noise, at: Int(sampleRate / 2)) { kernel.setTarget(.frequency, 2_000) }
            XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) < 2 }, "\(sampleRate)")
        }
    }
}

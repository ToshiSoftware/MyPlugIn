import XCTest
@testable import MyChannelStrip
import MyPlugInCore

final class ChannelStripKernelTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let block = 512

    private func makeKernel(_ settings: [ChannelStripParameter: Float] = [:]) -> ChannelStripKernel {
        let kernel = ChannelStripKernel()
        for (parameter, value) in settings { kernel.setTarget(parameter, value) }
        kernel.prepare(sampleRate: sampleRate, maximumFrames: block)
        return kernel
    }

    /// Renders in blocks; `right` nil renders mono.
    private func render(_ kernel: ChannelStripKernel, _ left: [Float], _ right: [Float]? = nil) -> ([Float], [Float]?) {
        var outLeft = left
        var outRight = right
        var offset = 0
        while offset < left.count {
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

    private func sine(_ frequency: Double, amplitude: Float, seconds: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    private func noise(_ count: Int, seed: UInt64 = 1) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state >> 11) % 2_000_000) / 2_000_000 * 0.8
        }
    }

    /// Sine amplitude (RMS x √2) of the last `seconds`, in dB relative to
    /// `reference`. RMS, because at high frequencies the samples miss the
    /// peaks of a phase-shifted sine.
    private func peakDecibels(_ samples: [Float], last seconds: Double = 0.1, reference: Float) -> Double {
        let tail = samples.suffix(Int(seconds * sampleRate))
        let meanSquare = tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(tail.count, 1))
        return 20 * log10((2 * meanSquare).squareRoot() / Double(reference))
    }

    private func largestStep(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    // MARK: Flat costs nothing

    func testDefaultsPassInputBitForBitAndComputeNothing() {
        let kernel = makeKernel()
        let left = noise(4_800, seed: 1)
        let right = noise(4_800, seed: 2)
        let (outLeft, outRight) = render(kernel, left, right)
        XCTAssertEqual(outLeft, left)
        XCTAssertEqual(outRight, right)
        XCTAssertEqual(kernel.takeReadings().activeBands, 0)

        let mono = makeKernel()
        XCTAssertEqual(render(mono, left).0, left)
    }

    func testBandBackAtZeroStopsComputingAndPassesExactly() {
        let kernel = makeKernel()
        let gain = ChannelStripParameter.band(1, .gain)
        kernel.setTarget(gain, 6)
        _ = render(kernel, noise(24_000))
        XCTAssertEqual(kernel.takeReadings().activeBands, 0b0010)
        kernel.setTarget(gain, 0)
        _ = render(kernel, noise(24_000))
        XCTAssertEqual(kernel.takeReadings().activeBands, 0)
        let input = noise(4_800, seed: 3)
        XCTAssertEqual(render(kernel, input).0, input)
    }

    func testCutIsComputedAtZeroGainAndEQOffStopsEverything() {
        let kernel = makeKernel([.band(0, .type): Float(ChannelStripFilterType.lowCut.rawValue)])
        _ = render(kernel, noise(4_800))
        XCTAssertEqual(kernel.takeReadings().activeBands, 0b0001)
        kernel.setTarget(.eqOn, 0)
        _ = render(kernel, noise(4_800))
        XCTAssertEqual(kernel.takeReadings().activeBands, 0)
        let input = noise(2_400, seed: 4)
        XCTAssertEqual(render(kernel, input).0, input)
    }

    // MARK: EQ

    func testBellGainAtItsCentre() {
        let kernel = makeKernel([.band(1, .frequency): 1_000, .band(1, .gain): 6, .band(1, .q): 1])
        let output = render(kernel, sine(1_000, amplitude: 0.25, seconds: 0.5)).0
        XCTAssertEqual(peakDecibels(output, reference: 0.25), 6, accuracy: 0.1)
    }

    func testKernelResponseMatchesTheGraphsDesign() {
        let kernel = makeKernel([.band(2, .frequency): 3_000, .band(2, .gain): 9, .band(2, .q): 2])
        let design = ChannelStripFilterDesign(type: .bell, steep: false, frequency: 3_000, gain: 9, q: 2,
                                              sampleRate: sampleRate)
        for frequency in [500.0, 2_000, 3_000, 6_000] {
            kernel.reset()
            let output = render(kernel, sine(frequency, amplitude: 0.1, seconds: 0.3)).0
            XCTAssertEqual(peakDecibels(output, reference: 0.1), design.decibels(at: frequency, sampleRate: sampleRate),
                           accuracy: 0.15, "\(frequency) Hz")
        }
    }

    func testCutSlopes() {
        func cut(_ type: ChannelStripFilterType, steep: Bool, at frequency: Double) -> Double {
            ChannelStripFilterDesign(type: type, steep: steep, frequency: 1_000, gain: 0, q: 0.7071,
                                     sampleRate: sampleRate).decibels(at: frequency, sampleRate: sampleRate)
        }
        XCTAssertEqual(cut(.lowCut, steep: false, at: 1_000), -3.01, accuracy: 0.05)
        XCTAssertEqual(cut(.lowCut, steep: true, at: 1_000), -3.01, accuracy: 0.05)
        XCTAssertEqual(cut(.lowCut, steep: false, at: 250), -24.1, accuracy: 0.3)
        XCTAssertEqual(cut(.lowCut, steep: true, at: 250), -48.2, accuracy: 0.5)
        XCTAssertEqual(cut(.highCut, steep: false, at: 4_000), -24.1, accuracy: 0.5)
        XCTAssertEqual(cut(.highCut, steep: true, at: 4_000), -48.2, accuracy: 1)
    }

    func testFlatShelvesAndBellsAreIdentities() {
        for type in [ChannelStripFilterType.lowShelf, .bell, .highShelf] {
            let design = ChannelStripFilterDesign(type: type, steep: false, frequency: 700, gain: 0, q: 0.9,
                                                  sampleRate: sampleRate)
            XCTAssertEqual(design.first.b0, 1, accuracy: 1e-12)
            XCTAssertEqual(design.first.b1, design.first.a1, accuracy: 1e-12)
            XCTAssertEqual(design.first.b2, design.first.a2, accuracy: 1e-12)
        }
    }

    func testGainAndTypeChangesDoNotClick() {
        let kernel = makeKernel([.band(0, .type): Float(ChannelStripFilterType.bell.rawValue),
                                 .band(0, .frequency): 200])
        let input = sine(100, amplitude: 0.25, seconds: 0.2)
        _ = render(kernel, input)
        kernel.setTarget(.band(0, .gain), 12)
        let raised = render(kernel, input).0
        kernel.setTarget(.band(0, .type), Float(ChannelStripFilterType.lowCut.rawValue))
        kernel.setTarget(.band(0, .slope), 1)
        let cut = render(kernel, input).0
        kernel.setTarget(.band(0, .on), 0)
        let off = render(kernel, input).0
        // A 100 Hz sine at up to +12 dB moves at most ~0.013 per sample.
        for output in [raised, cut, off] {
            XCTAssertLessThan(largestStep(output), 0.03)
        }
        XCTAssertEqual(peakDecibels(off, reference: 0.25), 0, accuracy: 0.01)
    }

    // MARK: Compressor

    func testStaticCurve() {
        let curve = { (x: Float) in ChannelStripCompressorCurve.output(x, threshold: -20, ratio: 4, knee: 10) }
        XCTAssertEqual(curve(-40), -40)
        XCTAssertEqual(curve(-25), -25, accuracy: 1e-5)
        XCTAssertEqual(curve(0), -15, accuracy: 1e-5)
        XCTAssertEqual(curve(-15), -18.75, accuracy: 1e-5)
        // Inside the knee, below the straight lines.
        XCTAssertLessThan(curve(-20), -20)
        XCTAssertGreaterThan(curve(-20), -20 - 10.0 / 8 - 0.01)
        XCTAssertEqual(ChannelStripCompressorCurve.autoMakeup(threshold: -20, ratio: 4), 7.5)
    }

    func testCompressorSettlesOnTheCurve() {
        let kernel = makeKernel([.compOn: 1, .compThreshold: -20, .compRatio: 4, .compKnee: 0,
                                 .compAttack: 1, .compRelease: 50])
        let output = render(kernel, [Float](repeating: 0.5, count: 24_000)).0
        let inputDecibels = 20 * log10(Float(0.5))
        let expected = pow(10, (-20 + (inputDecibels + 20) / 4) / 20)
        XCTAssertEqual(output.last!, expected, accuracy: expected * 0.01)
        let readings = kernel.takeReadings()
        XCTAssertLessThan(readings.reduction, -10)
        XCTAssertEqual(readings.detector, 0.5, accuracy: 1e-6)
    }

    func testCompressorOffOrDryPassesExactly() {
        let input = noise(4_800)
        let off = makeKernel([.compThreshold: -40, .compRatio: 20])
        XCTAssertEqual(render(off, input).0, input)
        XCTAssertGreaterThan(off.takeReadings().detector, 0.5) // the level ring still moves
        let dry = makeKernel([.compOn: 1, .compThreshold: -40, .compRatio: 20, .compMix: 0])
        XCTAssertEqual(render(dry, input).0, input)
    }

    func testUnlinkedChannelsCompressSeparately() {
        let loud = [Float](repeating: 0.8, count: 9_600)
        let quiet = [Float](repeating: 0.01, count: 9_600)
        let linked = makeKernel([.compOn: 1, .compThreshold: -20, .compRatio: 10, .compKnee: 0, .compAttack: 1])
        let unlinked = makeKernel([.compOn: 1, .compThreshold: -20, .compRatio: 10, .compKnee: 0, .compAttack: 1,
                                   .compLink: 0])
        XCTAssertLessThan(render(linked, loud, quiet).1!.last!, 0.005)
        XCTAssertEqual(render(unlinked, loud, quiet).1!.last!, 0.01, accuracy: 1e-5)
    }

    // MARK: Order and output

    func testOrderChangesTheResultWithoutClicking() {
        let settings: [ChannelStripParameter: Float] = [
            .band(1, .frequency): 1_000, .band(1, .gain): 12, .band(1, .q): 1,
            .compOn: 1, .compThreshold: -20, .compRatio: 10, .compKnee: 0, .compAttack: 0.1, .compRelease: 200
        ]
        let kernel = makeKernel(settings)
        let input = sine(1_000, amplitude: 0.1, seconds: 0.5)
        let eqFirst = render(kernel, input).0
        kernel.setTarget(.order, Float(ChannelStripOrder.compFirst.rawValue))
        let compFirst = render(kernel, input).0
        // EQ first: +12 dB is mostly compressed away; comp first: -20 dB is
        // at the threshold, then +12 dB.
        XCTAssertLessThan(peakDecibels(eqFirst, reference: 0.1), 5)
        XCTAssertEqual(peakDecibels(compFirst, reference: 0.1), 12, accuracy: 0.5)
        XCTAssertLessThan(largestStep(compFirst), 0.2)
    }

    func testOutputGain() {
        let kernel = makeKernel([.outputGain: 20 * log10(2)])
        XCTAssertEqual(render(kernel, [Float](repeating: 0.25, count: 4_800)).0.last!, 0.5, accuracy: 1e-5)
        let lowest = makeKernel([.outputGain: -24])
        XCTAssertEqual(render(lowest, [Float](repeating: 1, count: 4_800)).0.last!, pow(10, -24 / 20), accuracy: 1e-5)
    }

    func testBypassPassesInput() {
        let kernel = makeKernel([.band(1, .gain): 12, .compOn: 1, .outputGain: 6])
        kernel.isBypassed = true
        let input = noise(2_400)
        XCTAssertEqual(render(kernel, input).0, input)
    }

    // MARK: Spectrum

    func testSpectrumPeaksInTheSinesBand() {
        let spectrum = ChannelStripSpectrum()
        let levels = spectrum.bands(of: sine(1_000, amplitude: 1, seconds: 0.1), sampleRate: sampleRate)
        let loudest = levels.indices.max { levels[$0] < levels[$1] }!
        XCTAssertLessThanOrEqual(ChannelStripSpectrum.bandEdge(loudest), 1_000)
        XCTAssertGreaterThan(ChannelStripSpectrum.bandEdge(loudest + 1), 1_000)
        XCTAssertEqual(levels[loudest], 0, accuracy: 1.5)
        XCTAssertLessThan(levels[2], -60)
    }

    func testKernelFeedsTheSpectrumOnlyWhileAnalysing() {
        let kernel = makeKernel()
        let spectrum = ChannelStripSpectrum()
        _ = render(kernel, sine(4_000, amplitude: 0.5, seconds: 0.2))
        XCTAssertLessThan(spectrum.bands(of: kernel.analysis, sampleRate: sampleRate).max()!, -100)
        kernel.isAnalysing = true
        _ = render(kernel, sine(4_000, amplitude: 0.5, seconds: 0.2))
        let levels = spectrum.bands(of: kernel.analysis, sampleRate: sampleRate)
        let loudest = levels.indices.max { levels[$0] < levels[$1] }!
        XCTAssertLessThanOrEqual(ChannelStripSpectrum.bandEdge(loudest), 4_000)
        XCTAssertGreaterThan(ChannelStripSpectrum.bandEdge(loudest + 1), 4_000)
    }
}

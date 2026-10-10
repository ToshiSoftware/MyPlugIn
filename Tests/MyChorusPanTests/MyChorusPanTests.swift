import AVFoundation
import XCTest
@testable import MyChorusPan
import MyPlugInCore

final class MyChorusPanTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let blockSize = 512

    // MARK: Helpers

    private func makeKernel(_ values: [ChorusPanParameter: Float] = [:]) -> ChorusPanKernel {
        let kernel = ChorusPanKernel()
        for (parameter, value) in values { kernel.setTarget(parameter, value) }
        kernel.prepare(sampleRate: sampleRate, maximumFrames: blockSize)
        return kernel
    }

    /// Runs stereo input through the kernel in blocks (L = R unless `right`).
    private func render(_ kernel: ChorusPanKernel, left: [Float], right: [Float]? = nil,
                        beforeBlock: (Int) -> Void = { _ in }) -> (left: [Float], right: [Float]) {
        let inRight = right ?? left
        var outLeft = left
        var outRight = inRight
        var start = 0
        var block = 0
        while start < left.count {
            beforeBlock(block)
            let count = min(blockSize, left.count - start)
            left.withUnsafeBufferPointer { inL in
                inRight.withUnsafeBufferPointer { inR in
                    outLeft.withUnsafeMutableBufferPointer { oL in
                        outRight.withUnsafeMutableBufferPointer { oR in
                            kernel.process(inputLeft: inL.baseAddress! + start, inputRight: inR.baseAddress! + start,
                                           outputLeft: oL.baseAddress! + start, outputRight: oR.baseAddress! + start,
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

    private func seconds(_ value: Double) -> Int { Int(value * sampleRate) }

    private func noise(_ count: Int, seed: UInt32) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.5
        }
    }

    private func sine(_ frequency: Double, count: Int) -> [Float] {
        (0..<count).map { 0.5 * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    /// Impulses at `times` (s); returns for each the delay (in samples) of
    /// the strongest output sample within the next 40 ms.
    private func measuredDelays(_ kernel: ChorusPanKernel, at times: [Double], length: Double)
        -> (left: [Int], right: [Int]) {
        var input = [Float](repeating: 0, count: seconds(length))
        for time in times { input[seconds(time)] = 1 }
        let (left, right) = render(kernel, left: input)
        func peaks(_ output: [Float]) -> [Int] {
            times.map { time in
                let start = seconds(time)
                let window = output[start..<(start + seconds(0.04))]
                return window.indices.max { abs(window[$0]) < abs(window[$1]) }! - start
            }
        }
        return (peaks(left), peaks(right))
    }

    /// Chorus, wet only, full stereo: just the modulated delays.
    private let wet: [ChorusPanParameter: Float] = [.chorusMix: 100, .chorusStereoWidth: 100]

    // MARK: LFO

    func testLFOShapes() {
        XCTAssertEqual(ChorusPanLFO.value(.sine, at: 0.25), 1, accuracy: 1e-6)
        XCTAssertEqual(ChorusPanLFO.value(.triangle, at: 0), 0)
        XCTAssertEqual(ChorusPanLFO.value(.triangle, at: 0.25), 1)
        XCTAssertEqual(ChorusPanLFO.value(.triangle, at: 0.75), -1)
        XCTAssertEqual(ChorusPanLFO.value(.saw, at: 0), -1)
        XCTAssertEqual(ChorusPanLFO.value(.saw, at: 0.5), 0)
        XCTAssertEqual(ChorusPanLFO.value(.square, at: 0.25), 1)
        XCTAssertEqual(ChorusPanLFO.value(.square, at: 0.75), -1)
        XCTAssertEqual(ChorusPanLFO.value(.triangle, at: 1.25), 1, "only the fraction counts")
    }

    func testLFOPeriodAndContinuousSpeedChange() {
        var lfo = ChorusPanLFO(sampleRate: sampleRate, speed: 2, smoothingSeconds: 0.05)
        for _ in 0..<seconds(0.5) { lfo.advance(targetSpeed: 2) }
        XCTAssertEqual(lfo.phase.truncatingRemainder(dividingBy: 1), 0, accuracy: 1e-6, "one cycle at 2 Hz")
        var previous = lfo.phase
        for _ in 0..<seconds(0.2) {
            lfo.advance(targetSpeed: 10)
            var step = lfo.phase - previous
            if step < 0 { step += 1 }
            XCTAssertLessThanOrEqual(step, 10 / sampleRate + 1e-9)
            previous = lfo.phase
        }
    }

    // MARK: Chorus Pedal and Flanger Pedal

    func testDepthZeroIsAFixedDelay() {
        var values = wet
        values[.chorusDelay] = 5
        values[.chorusDepth] = 0
        let delays = measuredDelays(makeKernel(values), at: [0.1, 0.6], length: 1)
        XCTAssertEqual(delays.left, [240, 240])
        XCTAssertEqual(delays.right, [240, 240])
    }

    /// Triangle at 0.25 Hz, DEPTH 50 %: DELAY x 1.5 at 1 s (LFO +1), x 0.5
    /// at 3 s (LFO -1); the right side (L.WID 100 % = 180 degrees) opposite.
    func testDelaySweepsWithinDepthAndRightRunsOpposite() {
        var values = wet
        values[.chorusDelay] = 10
        values[.chorusDepth] = 50
        values[.chorusLFOType] = Float(ChorusPanWave.triangle.rawValue)
        values[.chorusSpeed] = 0.25
        values[.chorusLFOWidth] = 100
        let delays = measuredDelays(makeKernel(values), at: [1, 3], length: 3.2)
        XCTAssertEqual(Double(delays.left[0]), 720, accuracy: 4)
        XCTAssertEqual(Double(delays.left[1]), 240, accuracy: 4)
        XCTAssertEqual(Double(delays.right[0]), 240, accuracy: 4)
        XCTAssertEqual(Double(delays.right[1]), 720, accuracy: 4)
    }

    func testLFOWidthZeroModulatesBothSidesAlike() {
        var values = wet
        values[.chorusLFOWidth] = 0
        values[.chorusDepth] = 80
        let (left, right) = render(makeKernel(values), left: noise(seconds(1), seed: 7))
        XCTAssertEqual(left, right)
    }

    func testFlangerFeedbackStaysBoundedBothWays() {
        for feedback: Float in [95, -95] {
            let values: [ChorusPanParameter: Float] = [.mode: Float(ChorusPanMode.flanger.rawValue),
                                                       .flangerFeedback: feedback, .flangerDelay: 2,
                                                       .flangerDepth: 100, .flangerMix: 100]
            let (left, right) = render(makeKernel(values), left: noise(seconds(5), seed: 3))
            XCTAssertTrue((left + right).allSatisfy { $0.isFinite })
            XCTAssertLessThan((left + right).map(abs).max()!, 30, "feedback \(feedback)")
        }
    }

    func testStereoWidthZeroMakesTheWetMono() {
        var values = wet
        values[.chorusStereoWidth] = 0
        let (left, right) = render(makeKernel(values), left: noise(seconds(0.5), seed: 1),
                                   right: noise(seconds(0.5), seed: 2))
        for index in left.indices { XCTAssertEqual(left[index], right[index], accuracy: 1e-6) }
    }

    func testMixZeroPassesTheInputBitForBit() {
        let input = noise(seconds(0.5), seed: 5)
        let values: [ChorusPanParameter: Float] = [.mode: Float(ChorusPanMode.flanger.rawValue),
                                                   .flangerMix: 0, .flangerFeedback: 60]
        let (left, right) = render(makeKernel(values), left: input)
        XCTAssertEqual(left, input)
        XCTAssertEqual(right, input)
    }

    // MARK: Dimension

    private let dimension: [ChorusPanParameter: Float] = [.mode: Float(ChorusPanMode.dimension.rawValue)]

    /// A mono input comes out wide but not anti-phase (each side mostly its
    /// own line), at MIX 50 % about as loud as Chorus Pedal (-3 dB), with
    /// buttons 1 to 3.
    func testDimensionSpreadsAMonoInput() {
        for setting in 0..<3 {
            let (correlation, level) = dimensionCorrelationAndLevel(setting: setting, boost: false)
            XCTAssertGreaterThan(correlation, -0.05, "Dimension \(setting + 1)")
            XCTAssertLessThan(correlation, 0.35, "Dimension \(setting + 1)")
            XCTAssertEqual(level, -3, accuracy: 1.5)
        }
    }

    /// Button 4 raises the effect (and lowers the input): louder overall,
    /// and the cross-mix shows more (the sides further apart).
    func testDimensionButtonFourRaisesTheEffect() {
        for setting in 0..<3 {
            let plain = dimensionCorrelationAndLevel(setting: setting, boost: false)
            let boosted = dimensionCorrelationAndLevel(setting: setting, boost: true)
            XCTAssertGreaterThan(boosted.level, plain.level + 0.5)
            XCTAssertLessThan(boosted.correlation, plain.correlation - 0.3)
        }
    }

    private func dimensionCorrelationAndLevel(setting: Int, boost: Bool) -> (correlation: Double, level: Double) {
        var values = dimension
        values[.dimensionMode] = Float(setting)
        values[.dimensionBoost] = boost ? 1 : 0
        let input = noise(seconds(4), seed: 21)
        let (left, right) = render(makeKernel(values), left: input)
        var product = 0.0, leftEnergy = 0.0, rightEnergy = 0.0, inputEnergy = 0.0
        for index in seconds(1)..<input.count {
            product += Double(left[index] * right[index])
            leftEnergy += Double(left[index] * left[index])
            rightEnergy += Double(right[index] * right[index])
            inputEnergy += Double(input[index] * input[index])
        }
        return (product / (leftEnergy * rightEnergy).squareRoot(),
                10 * log10((leftEnergy + rightEnergy) / 2 / inputEnergy))
    }

    /// As the SDD-320, each input has its own line: a left-only input leaves
    /// the right with just the left line, cross-mixed in inverted at half
    /// level (MIX 50 %: left = x/2 + A/2, right = -A/4).
    func testDimensionKeepsTheInputsApartAndCrossMixesInverted() {
        let input = noise(seconds(1), seed: 23)
        let (left, right) = render(makeKernel(dimension), left: input,
                                   right: [Float](repeating: 0, count: input.count))
        var rightEnergy = 0.0
        for index in input.indices {
            XCTAssertEqual(right[index], -0.5 * (left[index] - 0.5 * input[index]), accuracy: 1e-5)
            rightEnergy += Double(right[index] * right[index])
        }
        XCTAssertGreaterThan(rightEnergy, 1)
    }

    func testDimensionMixZeroLeavesTheInputAndWidthZeroIsMono() {
        let input = noise(seconds(0.5), seed: 22)
        var values = dimension
        values[.dimensionMix] = 0
        let dry = render(makeKernel(values), left: input)
        XCTAssertEqual(dry.left, input)
        XCTAssertEqual(dry.right, input)
        values = dimension
        values[.dimensionStereoWidth] = 0
        let mono = render(makeKernel(values), left: input)
        for index in input.indices { XCTAssertEqual(mono.left[index], mono.right[index], accuracy: 1e-6) }
    }

    func testDimensionSettingChangesDoNotClick() {
        let kernel = makeKernel(dimension)
        let (left, _) = render(kernel, left: sine(220, count: seconds(2))) { block in
            if block == 40 { kernel.setTarget(.dimensionMode, 2) }
            if block == 70 { kernel.setTarget(.dimensionBoost, 1) }
            if block == 100 { kernel.setTarget(.dimensionMode, 1) }
            if block == 130 { kernel.setTarget(.dimensionBoost, 0) }
        }
        XCTAssertLessThan(largestCorner(left, from: 14_000), 0.004)
    }

    // MARK: Auto Pan

    private let autoPan: [ChorusPanParameter: Float] = [.mode: Float(ChorusPanMode.autoPan.rawValue)]

    func testAutoPanWidthZeroPassesTheInput() {
        var values = autoPan
        values[.panWidth] = 0
        let input = noise(seconds(0.5), seed: 9)
        let (left, right) = render(makeKernel(values), left: input)
        for index in input.indices {
            XCTAssertEqual(left[index], input[index], accuracy: 1e-6)
            XCTAssertEqual(right[index], input[index], accuracy: 1e-6)
        }
    }

    /// Square at 0.5 Hz, width 100 %: right for the first second (left
    /// silent, right +3 dB), then left. The two sides' power stays constant.
    func testAutoPanReachesTheSidesWithConstantPower() {
        var values = autoPan
        values[.panType] = Float(ChorusPanWave.square.rawValue)
        values[.panSpeed] = 0.5
        let input = [Float](repeating: 0.5, count: seconds(2))
        let (left, right) = render(makeKernel(values), left: input)
        XCTAssertEqual(left[seconds(0.5)], 0, accuracy: 1e-4)
        XCTAssertEqual(right[seconds(0.5)], 0.5 * Float(2).squareRoot(), accuracy: 1e-4)
        XCTAssertEqual(left[seconds(1.5)], 0.5 * Float(2).squareRoot(), accuracy: 1e-4)
        XCTAssertEqual(right[seconds(1.5)], 0, accuracy: 1e-4)
        for index in stride(from: 0, to: input.count, by: 97) {
            XCTAssertEqual(left[index] * left[index] + right[index] * right[index], 0.5, accuracy: 1e-4)
        }
    }

    /// Square's switch and Saw's drop are smoothed (5 ms): no jump.
    func testAutoPanEdgesAreSmoothed() {
        for wave in [ChorusPanWave.square, .saw] {
            var values = autoPan
            values[.panType] = Float(wave.rawValue)
            values[.panSpeed] = 4
            let input = [Float](repeating: 0.5, count: seconds(1))
            let (left, _) = render(makeKernel(values), left: input)
            var largestStep: Float = 0
            for index in 1..<left.count { largestStep = max(largestStep, abs(left[index] - left[index - 1])) }
            XCTAssertLessThan(largestStep, 0.01, "\(wave)")
        }
    }

    // MARK: Changes, INIT, tail, strings

    /// A click is a corner: a large second difference (0.01 or more here;
    /// a 220 Hz sine at 0.5 has 0.0004). Level and pitch changes (feedback
    /// resonance, Square's quick pitch dip: about 0.002) stay well below.
    private func largestCorner(_ signal: [Float], from start: Int) -> Float {
        var largest: Float = 0
        for index in max(start, 2)..<signal.count {
            largest = max(largest, abs(signal[index] - 2 * signal[index - 1] + signal[index - 2]))
        }
        return largest
    }

    func testParameterAndModeChangesDoNotClick() {
        let kernel = makeKernel()
        let (left, _) = render(kernel, left: sine(220, count: seconds(3))) { block in
            switch block {
            case 30: kernel.setTarget(.chorusDelay, 20)
            case 50: kernel.setTarget(.chorusLFOType, Float(ChorusPanWave.square.rawValue))
            case 70: kernel.setTarget(.mode, Float(ChorusPanMode.flanger.rawValue))
            case 90: kernel.setTarget(.flangerFeedback, -70)
            case 110: kernel.setTarget(.mode, Float(ChorusPanMode.dimension.rawValue))
            case 150: kernel.setTarget(.mode, Float(ChorusPanMode.autoPan.rawValue))
            case 200: kernel.setTarget(.mode, Float(ChorusPanMode.chorus.rawValue))
            default: break
            }
        }
        XCTAssertLessThan(largestCorner(left, from: 14_000), 0.004)
    }

    /// INIT resets exactly the current mode's parameters.
    func testEachModeOwnsItsParametersForInit() {
        XCTAssertEqual(ChorusPanMode.chorus.parameters, [.chorusDelay, .chorusDepth, .chorusLFOType, .chorusSpeed,
                                                         .chorusLFOWidth, .chorusStereoWidth, .chorusMix])
        XCTAssertEqual(ChorusPanMode.dimension.parameters,
                       [.dimensionMode, .dimensionStereoWidth, .dimensionMix, .dimensionBoost])
        XCTAssertEqual(ChorusPanMode.flanger.parameters.count, 8)
        XCTAssertEqual(ChorusPanMode.autoPan.parameters, [.panType, .panSpeed, .panWidth])
        let all = ChorusPanMode.allCases.flatMap(\.parameters) + [.mode]
        XCTAssertEqual(Set(all), Set(ChorusPanParameter.allCases))
        XCTAssertEqual(ChorusPanParameter.flangerFeedback.defaultValue, 60)
        XCTAssertEqual(ChorusPanParameter.dimensionMode.displayString(for: ChorusPanParameter.dimensionMode.defaultValue), "1")
        XCTAssertEqual(ChorusPanParameter.dimensionBoost.defaultValue, 0, "INIT: 1 with 4 off")
    }

    func testTailTime() {
        XCTAssertEqual(makeKernel([.chorusDelay: 10, .chorusDepth: 0]).tailTime, 0.01, accuracy: 1e-6)
        let flanger = makeKernel([.mode: Float(ChorusPanMode.flanger.rawValue), .flangerDelay: 5,
                                  .flangerDepth: 100, .flangerFeedback: -50])
        XCTAssertEqual(flanger.tailTime, 0.01 + 0.01 * log(0.001) / log(0.5), accuracy: 1e-6)
        XCTAssertEqual(makeKernel(autoPan).tailTime, 0)
    }

    func testLampFollowsTheCurrentModesLFO() {
        let kernel = makeKernel([.chorusSpeed: 1, .chorusLFOType: Float(ChorusPanWave.saw.rawValue)])
        _ = render(kernel, left: [Float](repeating: 0, count: seconds(0.25)))
        XCTAssertEqual(kernel.lamp.phase, 0.25, accuracy: 0.002)
        XCTAssertEqual(kernel.lamp.wave, .saw)
        kernel.setTarget(.mode, Float(ChorusPanMode.autoPan.rawValue))
        _ = render(kernel, left: [Float](repeating: 0, count: seconds(0.1)))
        XCTAssertEqual(kernel.lamp.wave, .sine)
        kernel.setTarget(.mode, Float(ChorusPanMode.dimension.rawValue))
        _ = render(kernel, left: [Float](repeating: 0, count: seconds(0.1)))
        XCTAssertEqual(kernel.lamp.wave, .triangle)
    }

    func testParameterStrings() {
        XCTAssertEqual(ChorusPanParameter.chorusDelay.displayString(for: 8), "8.0 ms")
        XCTAssertEqual(ChorusPanParameter.flangerDelay.displayString(for: 0.1), "0.10ms")
        XCTAssertEqual(ChorusPanParameter.chorusDelay.displayString(for: 30), "30 ms")
        XCTAssertEqual(ChorusPanParameter.chorusSpeed.displayString(for: 0.6), "0.60Hz")
        XCTAssertEqual(ChorusPanParameter.panSpeed.displayString(for: 10), "10.0Hz")
        XCTAssertEqual(ChorusPanParameter.flangerFeedback.displayString(for: -40), "-40%")
        XCTAssertEqual(ChorusPanParameter.flangerFeedback.displayString(for: 0), "0%")
        XCTAssertEqual(ChorusPanParameter.mode.displayString(for: 1), "Dimension")
        XCTAssertEqual(ChorusPanParameter.flangerLFOType.displayString(for: 2), "Saw")
        XCTAssertEqual(ChorusPanParameter.chorusLFOType.value(fromDisplayString: "square"), 3)
        XCTAssertEqual(ChorusPanParameter.mode.value(fromDisplayString: "flanger pedal"), 2)
        XCTAssertEqual(ChorusPanParameter.dimensionMode.value(fromDisplayString: "3"), 2)
        XCTAssertNil(ChorusPanParameter.dimensionMode.value(fromDisplayString: "4"))
        XCTAssertEqual(ChorusPanParameter.dimensionBoost.displayString(for: 1), "On")
        XCTAssertEqual(ChorusPanParameter.chorusDelay.value(fromDisplayString: "12.5 ms"), 12.5)
        XCTAssertEqual(ChorusPanParameter.flangerFeedback.value(fromDisplayString: "-200"), -95)
        XCTAssertEqual(ChorusPanParameter.chorusDelay.clamped(1), 3, "Chorus DELAY starts at 3 ms")
        XCTAssertEqual(ChorusPanParameter.chorusLFOType.clamped(1.6), 2)
        XCTAssertEqual(ChorusPanParameter.chorusDelay.clamped(.nan), 8)
        XCTAssertEqual(ChorusPanParameter.flangerSpeed.hostName, "Flanger Pedal Speed")
    }

    func testFaderTaperRoundTripsAndLayout() {
        for parameter in ChorusPanParameter.allCases where !parameter.isIndexed {
            for value in [parameter.range.lowerBound, parameter.defaultValue, parameter.range.upperBound] {
                let fraction = ChorusPanFaderTaper.fraction(for: parameter, value: value)
                XCTAssertEqual(ChorusPanFaderTaper.value(for: parameter, fraction: fraction), value,
                               accuracy: abs(value) * 1e-4 + 1e-4, "\(parameter)")
            }
        }
        XCTAssertEqual(ChorusPanFaderTaper.fraction(for: .flangerFeedback, value: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ChorusPanMode.allCases.map { ChorusPanFaderTaper.faders(for: $0).count }, [6, 2, 7, 2])
        for mode in ChorusPanMode.allCases {
            XCTAssertTrue(ChorusPanFaderTaper.faders(for: mode).allSatisfy { $0.mode == mode })
            XCTAssertEqual(ChorusPanFaderTaper.buttons(for: mode).mode, mode)
        }
    }

    // MARK: Audio Unit

    func testUnitAndEditor() throws {
        let unit = try MyChorusPanAudioUnit(componentDescription: MyChorusPanAudioUnit.componentDescription)
        let parameters = try XCTUnwrap(unit.parameterTree?.allParameters)
        XCTAssertEqual(parameters.map(\.identifier), ChorusPanParameter.allCases.map(\.identifier))
        XCTAssertEqual(parameters.map(\.address), ChorusPanParameter.allCases.map(\.address))
        XCTAssertEqual(parameters.first { $0.identifier == "chorus_lfo_type" }?.valueStrings,
                       ["Sine", "Triangle", "Saw", "Square"])
        XCTAssertEqual(parameters.first { $0.identifier == "dimension_mode" }?.valueStrings, ["1", "2", "3"])
        XCTAssertEqual(parameters.first { $0.identifier == "mode" }?.valueStrings,
                       ["Chorus Pedal", "Dimension", "Flanger Pedal", "Auto Pan"])
        XCTAssertEqual(unit.makeEditorViewController().view.frame.size, NSSize(width: 300, height: 460))
    }

    func testRendersMuchFasterThanRealTime() {
        let kernel = makeKernel([.mode: Float(ChorusPanMode.flanger.rawValue), .flangerDepth: 100, .flangerFeedback: 80])
        let input = noise(seconds(10), seed: 11)
        let start = Date()
        _ = render(kernel, left: input)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}


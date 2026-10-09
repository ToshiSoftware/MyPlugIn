import XCTest
@testable import MyMaximizer
import MyPlugInCore

final class MaximizerKernelTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let block = 512

    private func makeKernel(_ settings: [MaximizerParameter: Float] = [:],
                            sampleRate: Double = 48_000) -> MaximizerKernel {
        let kernel = MaximizerKernel()
        for (parameter, value) in settings { kernel.setTarget(parameter, value) }
        kernel.prepare(sampleRate: sampleRate, maximumFrames: block)
        return kernel
    }

    /// Renders in blocks; `right` nil renders mono.
    private func render(_ kernel: MaximizerKernel, _ left: [Float], _ right: [Float]? = nil) -> ([Float], [Float]?) {
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

    private func sine(_ frequency: Double, decibels: Float, seconds: Double, rate: Double = 48_000) -> [Float] {
        let amplitude = pow(10, decibels / 20)
        return (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    private func decibels(_ level: Float) -> Float { 20 * log10(level) }

    private func peak(_ samples: ArraySlice<Float>) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    // MARK: Ceiling

    func testOutputNeverExceedsTheCeiling() {
        var noiseState: UInt32 = 1
        let noise: [Float] = (0..<48_000).map { _ in
            noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: noiseState)) / Float(Int32.max)
        }
        var impulses = [Float](repeating: 0.01, count: 24_000)
        for index in stride(from: 100, to: impulses.count, by: 997) { impulses[index] = index % 2 == 0 ? 1 : -1 }
        let square: [Float] = (0..<24_000).map { ($0 / 40) % 2 == 0 ? 0.9 : -0.9 }
        let signals = [sine(20, decibels: 0, seconds: 0.5), sine(1_000, decibels: -3, seconds: 0.5),
                       sine(18_000, decibels: 0, seconds: 0.5), noise, impulses, square]

        for ceiling: Float in [-0.1, -1, -6] {
            for (index, signal) in signals.enumerated() {
                let kernel = makeKernel([.inputGain: 24, .outputLevel: ceiling])
                let (left, right) = render(kernel, signal, signal.map { -$0 * 0.7 })
                let limit = pow(10, ceiling / 20)
                XCTAssertLessThanOrEqual(peak(left[...]), limit, "signal \(index), ceiling \(ceiling)")
                XCTAssertLessThanOrEqual(peak(right![...]), limit, "signal \(index), ceiling \(ceiling)")
                XCTAssertEqual(kernel.safetyClips, 0, "signal \(index), ceiling \(ceiling)")
            }
        }
    }

    func testCeilingHoldsAtEverySampleRateAttackAndRelease() {
        for rate in [44_100.0, 48_000, 96_000] {
            for (attack, release): (Float, Float) in [(0, 10), (0, 50), (2, 50), (10, 500), (10, 10)] {
                let kernel = makeKernel([.inputGain: 18, .attack: attack, .release: release], sampleRate: rate)
                let signal = sine(60, decibels: -2, seconds: 0.4, rate: rate)
                    .enumerated().map { $0.element + (($0.offset / 300) % 7 == 0 ? 0.5 : 0) }
                let (left, _) = render(kernel, signal)
                let label = "rate \(rate), attack \(attack), release \(release)"
                XCTAssertLessThanOrEqual(peak(left[...]), pow(10, -0.1 / 20), label)
                XCTAssertEqual(kernel.safetyClips, 0, label)
            }
        }
    }

    /// Moving ATTACK while limiting keeps the ceiling.
    func testAttackChangesKeepTheCeiling() {
        let kernel = makeKernel([.inputGain: 12])
        let signal = sine(90, decibels: -3, seconds: 0.6)
        var output: [Float] = []
        for (index, start) in stride(from: 0, to: signal.count, by: 2_400).enumerated() {
            kernel.setTarget(.attack, Float(index % 5) * 2.5)
            output += render(kernel, Array(signal[start..<min(start + 2_400, signal.count)])).0
        }
        XCTAssertLessThanOrEqual(peak(output[...]), pow(10, -0.1 / 20))
        XCTAssertGreaterThan(peak(output[24_000...]), 0.9)
    }

    // MARK: Threshold (soft knee)

    func testSoftKneeCurve() {
        let curve = { (x: Float) in MaximizerLimiter.curve(x, threshold: -6, ceiling: -0.1) }
        XCTAssertEqual(curve(-10), -10)
        XCTAssertEqual(curve(-6), -6)
        XCTAssertEqual(curve(-3), -3.65, accuracy: 0.02)
        XCTAssertEqual(curve(0), -2.24, accuracy: 0.02)
        XCTAssertEqual(curve(6), -0.87, accuracy: 0.02)
        XCTAssertEqual(curve(12), -0.38, accuracy: 0.02)
        // No corner at the knee: slope 1 just above it.
        XCTAssertEqual((curve(-5.99) - curve(-6)) / 0.01, 1, accuracy: 0.01)
        // Rises all the way, never reaching the ceiling.
        var last: Float = -100
        for x in stride(from: Float(-12), through: 40, by: 0.5) {
            XCTAssertGreaterThanOrEqual(curve(x), last)
            XCTAssertLessThan(curve(x), -0.1)
            last = curve(x)
        }
        // THRESH at (or above) the ceiling: a brickwall.
        XCTAssertEqual(MaximizerLimiter.curve(3, threshold: -0.1, ceiling: -0.1), -0.1)
        XCTAssertEqual(MaximizerLimiter.curve(3, threshold: 0, ceiling: -1), -1)
    }

    /// Peaks above THRESH are pressed toward the ceiling along the curve;
    /// those below pass untouched.
    func testThresholdPressesPeaksTowardTheCeiling() {
        let settings: [MaximizerParameter: Float] = [.upward: 0, .threshold: -6]
        let (pressed, _) = render(makeKernel(settings), sine(500, decibels: 0, seconds: 0.5))
        XCTAssertEqual(decibels(peak(pressed[12_000...])), -2.24, accuracy: 0.15)

        let quietKernel = makeKernel(settings)
        let quiet = sine(500, decibels: -8, seconds: 0.2)
        let (untouched, _) = render(quietKernel, quiet)
        let delay = quietKernel.latencySamples
        XCTAssertEqual(Array(untouched[delay...]), Array(quiet[..<(quiet.count - delay)]))
    }

    func testDeepThresholdKeepsTheCeiling() {
        for threshold: Float in [-30, -12, -3] {
            let kernel = makeKernel([.inputGain: 24, .threshold: threshold, .release: 10])
            let (output, _) = render(kernel, sine(70, decibels: 0, seconds: 0.5))
            XCTAssertLessThanOrEqual(peak(output[...]), pow(10, -0.1 / 20), "threshold \(threshold)")
            XCTAssertEqual(kernel.safetyClips, 0, "threshold \(threshold)")
        }
    }

    /// The default THRESH (-0.1 dB, at OUTPUT) is the plain brickwall, and
    /// a THRESH above OUTPUT counts as OUTPUT.
    func testThresholdAtOrAboveOutputIsABrickwall() {
        let input = sine(300, decibels: 0, seconds: 0.3)
        let brickwall = render(makeKernel([.inputGain: 6, .outputLevel: -1, .threshold: -1]), input).0
        let above = render(makeKernel([.inputGain: 6, .outputLevel: -1, .threshold: 0]), input).0
        XCTAssertEqual(brickwall, above)
        XCTAssertEqual(MaximizerParameter.threshold.defaultValue, MaximizerParameter.outputLevel.defaultValue)
    }

    /// Below the ceiling with UPWARD off, the output is the input delayed by
    /// the look-ahead, bit for bit.
    func testQuietSignalPassesDelayedBitForBit() {
        let kernel = makeKernel([.upward: 0])
        let input = sine(440, decibels: -20, seconds: 0.1)
        let (output, _) = render(kernel, input)
        let delay = kernel.latencySamples
        XCTAssertEqual(delay, 480)
        XCTAssertEqual(Array(output[delay...]), Array(input[..<(input.count - delay)]))
        XCTAssertEqual(Array(output[..<delay]), [Float](repeating: 0, count: delay))
    }

    func testLatencyFollowsTheSampleRate() {
        XCTAssertEqual(makeKernel(sampleRate: 44_100).latencySamples, 441)
        XCTAssertEqual(makeKernel(sampleRate: 96_000).latencySamples, 960)
        // ATTACK does not change it.
        XCTAssertEqual(makeKernel([.attack: 10]).latencySamples, 480)
    }

    func testBypassKeepsTheSameDelay() {
        let kernel = makeKernel([.inputGain: 12])
        kernel.isBypassed = true
        kernel.reset()
        var input = [Float](repeating: 0, count: 2_000)
        input[10] = 1.5
        let (output, _) = render(kernel, input)
        XCTAssertEqual(output[10 + kernel.latencySamples], 1.5)
        XCTAssertEqual(output.filter { $0 != 0 }.count, 1)
    }

    func testBypassSwitchDoesNotClick() {
        let kernel = makeKernel([.upward: 0])
        let input = sine(200, decibels: -12, seconds: 0.2)
        var output: [Float] = []
        for (index, chunk) in stride(from: 0, to: input.count, by: 1_200).enumerated() {
            kernel.isBypassed = index % 2 == 1
            output += render(kernel, Array(input[chunk..<min(chunk + 1_200, input.count)])).0
        }
        let largestStep = zip(output.dropFirst(), output).map { abs($0 - $1) }.max() ?? 0
        // A 200 Hz sine at -12 dB moves at most ~0.007 per sample.
        XCTAssertLessThan(largestStep, 0.01)
    }

    func testSinglePeakIsCaughtBeforeItGetsOut() {
        let kernel = makeKernel([.upward: 0])
        var input = [Float](repeating: 0.1, count: 4_800)
        input[2_000] = 3
        let (output, _) = render(kernel, input)
        let delayed = 2_000 + kernel.latencySamples
        XCTAssertEqual(output[delayed], pow(10, -0.1 / 20), accuracy: 1e-3)
        XCTAssertLessThanOrEqual(peak(output[...]), pow(10, -0.1 / 20))
    }

    // MARK: Attack and release

    /// With ATTACK 0 the gain drops right at the peak; with 5 ms it ramps
    /// down over the 5 ms before it.
    func testAttackRampEndsAtThePeak() {
        var input = [Float](repeating: 0.1, count: 9_600)
        input[4_800] = 3
        let ceiling = pow(10, -0.1 / 20) as Float

        let instant = makeKernel([.upward: 0, .attack: 0])
        let (sharp, _) = render(instant, input)
        let peakOut = 4_800 + instant.latencySamples
        XCTAssertEqual(sharp[peakOut - 1], 0.1)
        XCTAssertEqual(sharp[peakOut], ceiling, accuracy: 1e-3)

        let ramped = makeKernel([.upward: 0, .attack: 5])
        let (soft, _) = render(ramped, input)
        XCTAssertEqual(soft[peakOut - 241], 0.1)
        XCTAssertLessThan(soft[peakOut - 120], 0.07)
        XCTAssertEqual(soft[peakOut], ceiling, accuracy: 1e-3)
    }

    /// Seconds until the reduction has recovered to 1/e of its depth.
    private func recovery(releaseMilliseconds: Float) -> Double {
        let limiter = MaximizerLimiter()
        limiter.prepare(sampleRate: sampleRate)
        limiter.setAttack(milliseconds: 0)
        limiter.setRelease(milliseconds: releaseMilliseconds)
        var left: Float = 0
        var right: Float = 0
        for _ in 0..<Int(0.02 * sampleRate) {
            left = 2
            right = 2
            limiter.process(&left, &right, ceiling: 1, threshold: 1)
        }
        var depth: Float = 0
        for frame in 0..<Int(5 * sampleRate) {
            left = 0.1
            right = 0.1
            limiter.process(&left, &right, ceiling: 1, threshold: 1)
            // The quiet frames reach the gain after the look-ahead.
            if frame == limiter.lookAhead { depth = 1 - limiter.gain }
            if frame > limiter.lookAhead && 1 - limiter.gain < depth / Float(M_E) {
                return Double(frame - limiter.lookAhead) / sampleRate
            }
        }
        return .infinity
    }

    func testReleaseTimeFollowsRelease() {
        for release: Float in [10, 50, 500] {
            XCTAssertEqual(recovery(releaseMilliseconds: release), Double(release) / 1_000,
                           accuracy: Double(release) / 1_000 * 0.1, "release \(release)")
        }
    }

    // MARK: Upward

    private func boost(after input: [Float], _ settings: [MaximizerParameter: Float]) -> Float {
        let kernel = makeKernel(settings)
        let (output, _) = render(kernel, input)
        let tail = output.count - 4_800
        return decibels(peak(output[tail...])) - decibels(peak(input[(tail - kernel.latencySamples)...]))
    }

    func testUpwardLiftsQuietMusicOnly() {
        XCTAssertEqual(boost(after: sine(500, decibels: -30, seconds: 4), [:]), 2, accuracy: 0.1)
        XCTAssertEqual(boost(after: sine(500, decibels: -30, seconds: 6), [.upward: 6]), 6, accuracy: 0.15)
        XCTAssertEqual(boost(after: sine(500, decibels: -6, seconds: 2), [:]), 0, accuracy: 0.01)
        // Silence from the start: nothing to lift.
        XCTAssertEqual(boost(after: sine(500, decibels: -80, seconds: 2), [:]), 0, accuracy: 0.01)
        // Near the -12 dB threshold the boost is only the difference.
        XCTAssertEqual(boost(after: sine(500, decibels: -13, seconds: 4), [:]), 1, accuracy: 0.1)
    }

    /// Attack = the limiter's ATTACK, release = ten times its RELEASE.
    func testUpwardFollowsTheLimiterTimes() {
        let upward = MaximizerUpward()
        upward.prepare(sampleRate: sampleRate)
        upward.setTimes(attackMilliseconds: 0, releaseMilliseconds: 50)
        for _ in 0..<Int(4 * sampleRate) { _ = upward.gain(level: 0.03, amount: 2) }
        XCTAssertEqual(upward.boost, 2, accuracy: 0.02)
        // Loud, ATTACK 0: gone at once.
        _ = upward.gain(level: 0.5, amount: 2)
        XCTAssertEqual(upward.boost, 0)
        // Quiet again: 500 ms (10 x 50 ms) to come back.
        for _ in 0..<Int(0.5 * sampleRate) { _ = upward.gain(level: 0.03, amount: 2) }
        XCTAssertEqual(upward.boost, 2 * (1 - exp(-1)), accuracy: 0.1)

        upward.setTimes(attackMilliseconds: 10, releaseMilliseconds: 50)
        for _ in 0..<Int(4 * sampleRate) { _ = upward.gain(level: 0.03, amount: 2) }
        for _ in 0..<Int(0.01 * sampleRate) { _ = upward.gain(level: 0.5, amount: 2) }
        XCTAssertEqual(upward.boost, 2 * exp(-1), accuracy: 0.1)
    }

    /// In silence the boost is held, so the music comes back with it.
    func testUpwardHoldsItsBoostThroughSilence() {
        let upward = MaximizerUpward()
        upward.prepare(sampleRate: sampleRate)
        upward.setTimes(attackMilliseconds: 0, releaseMilliseconds: 50)
        for _ in 0..<Int(4 * sampleRate) { _ = upward.gain(level: 0.03, amount: 2) }
        let held = upward.boost
        for _ in 0..<Int(2 * sampleRate) { _ = upward.gain(level: 0, amount: 2) }
        XCTAssertEqual(upward.boost, held)
        XCTAssertEqual(upward.gain(level: 0.03, amount: 2), pow(10, held / 20), accuracy: 1e-3)
        // A lowered amount is followed even in silence.
        for _ in 0..<100 { _ = upward.gain(level: 0, amount: 1) }
        XCTAssertEqual(upward.boost, 1, accuracy: 1e-3)

        // Through the kernel: quiet, silence, quiet again - boosted at once.
        let kernel = makeKernel()
        let quiet = sine(500, decibels: -30, seconds: 4)
        _ = render(kernel, quiet)
        _ = render(kernel, [Float](repeating: 0, count: 96_000))
        let (back, _) = render(kernel, Array(quiet[..<9_600]))
        XCTAssertEqual(decibels(peak(back[4_800...])) + 30, 2, accuracy: 0.1)
    }

    func testGainChangesDoNotClick() {
        let kernel = makeKernel([.upward: 0])
        let input = sine(100, decibels: -30, seconds: 0.3)
        let first = render(kernel, Array(input[..<4_800])).0
        kernel.setTarget(.inputGain, 12)
        kernel.setTarget(.outputLevel, -6)
        let rest = render(kernel, Array(input[4_800...])).0
        let output = first + rest
        let largestStep = zip(output.dropFirst(), output).map { abs($0 - $1) }.max() ?? 0
        // A 100 Hz sine at -18 dB moves at most ~0.0017 per sample.
        XCTAssertLessThan(largestStep, 0.003)
    }

    func testMonoMatchesLeftOfStereo() {
        let input = sine(300, decibels: 0, seconds: 0.2)
        let mono = render(makeKernel([.inputGain: 6]), input).0
        let stereo = render(makeKernel([.inputGain: 6]), input, input).0
        XCTAssertEqual(mono, stereo)
    }

    // MARK: History and readings

    func testHistoryColumns() {
        let kernel = makeKernel([.inputGain: 12])
        let length = MaximizerHistory.columnFrames(sampleRate: sampleRate)
        XCTAssertEqual(length, 507)
        _ = render(kernel, sine(1_000, decibels: -3, seconds: Double(length * 10) / sampleRate))
        XCTAssertEqual(kernel.history.count, 10)
        let (columns, next) = kernel.history.read(since: 0)
        XCTAssertEqual(next, 10)
        XCTAssertEqual(columns.count, 10)
        XCTAssertEqual(columns.last!.peak, pow(10, -0.1 / 20), accuracy: 0.01)
        // -3 dBFS + 12 dB against a -0.1 dB ceiling: 9.1 dB of reduction.
        XCTAssertEqual(columns.last!.reduction, -9.1, accuracy: 0.2)
        XCTAssertFalse(columns.last!.isBypassed)
        XCTAssertTrue(kernel.history.read(since: 10).columns.isEmpty)

        let readings = kernel.takeReadings()
        XCTAssertEqual(readings.reduction, -9.1, accuracy: 0.2)
        XCTAssertEqual(kernel.takeReadings(), MaximizerReadings())
    }

    func testHistoryRingWrapsAround() {
        let kernel = makeKernel()
        let length = MaximizerHistory.columnFrames(sampleRate: sampleRate)
        let columns = MaximizerHistory.capacity + 50
        _ = render(kernel, [Float](repeating: 0.01, count: length * columns))
        let (read, next) = kernel.history.read(since: 0)
        XCTAssertEqual(next, columns)
        XCTAssertEqual(read.count, MaximizerHistory.capacity - 1)
    }

    func testBypassedColumnsAreMarked() {
        let kernel = makeKernel()
        kernel.isBypassed = true
        _ = render(kernel, [Float](repeating: 0.1, count: MaximizerHistory.columnFrames(sampleRate: sampleRate) * 3))
        XCTAssertTrue(kernel.history.read(since: 0).columns.allSatisfy(\.isBypassed))
    }

    func testGraphMergesColumns() {
        let columns = (0..<10).map {
            MaximizerColumn(peak: Float($0) / 10, reduction: -Float($0), boost: Float($0 % 2), isBypassed: false)
        }
        // Groups of 4 by column number: 0-3, 4-7; 8-9 are not complete yet.
        let points = MaximizerGraphScale.points(columns, merge: 4)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[1].peak, 0.7, accuracy: 1e-6)
        XCTAssertEqual(points[1].reduction, -7)
        XCTAssertEqual(points[1].boost, 0.5, accuracy: 1e-6)
        // One more column arriving does not regroup what is drawn: the
        // points stay the same until a group completes (no shimmer).
        let more = columns + [MaximizerColumn(peak: 1, reduction: -10, boost: 0)]
        XCTAssertEqual(MaximizerGraphScale.points(more, merge: 4), points)
        let complete = more + [MaximizerColumn(peak: 1, reduction: -11, boost: 1)]
        XCTAssertEqual(Array(MaximizerGraphScale.points(complete, merge: 4).prefix(2)), points)
        // Dropping old columns keeps the grouping by number.
        let shifted = Array(complete.dropFirst(5))
        XCTAssertEqual(MaximizerGraphScale.points(shifted, firstIndex: 5, merge: 4), 
                       Array(MaximizerGraphScale.points(complete, merge: 4).suffix(1)))
        XCTAssertEqual(MaximizerGraphScale.points(columns, merge: 1).count, 10)
        XCTAssertEqual(MaximizerGraphScale.depth(-15), 0.5)
        XCTAssertEqual(MaximizerGraphScale.height(3), 0.1, accuracy: 1e-6)
    }

    func testRendersMuchFasterThanRealTime() {
        let kernel = makeKernel([.inputGain: 9, .upward: 4])
        let input = sine(80, decibels: -6, seconds: 10).enumerated().map {
            $0.element * (($0.offset / 24_000) % 2 == 0 ? 1 : 0.1)
        }
        let start = Date()
        _ = render(kernel, input, input)
        let elapsed = Date().timeIntervalSince(start)
        // Debug builds are slow; this only catches gross regressions.
        XCTAssertLessThan(elapsed, 10, "10 s of audio took \(elapsed) s")
        print("Rendered 10 s of stereo audio in \(String(format: "%.3f", elapsed)) s")
    }

    /// The GR / UP readouts: up at once, held 1 s, then a 0.2 s glide.
    func testReadoutPeakHold() {
        let tick = 1.0 / 30
        var hold = MaximizerPeakHold()
        hold.update(6, interval: tick)
        XCTAssertEqual(hold.value, 6)
        // Quieter readings for 0.9 s: still holding.
        for _ in 0..<27 { hold.update(1, interval: tick) }
        XCTAssertEqual(hold.value, 6)
        // After the hold, 0.2 s takes it about 63 % of the way down.
        for _ in 0..<4 { hold.update(1, interval: tick) }
        for _ in 0..<6 { hold.update(1, interval: tick) }
        XCTAssertEqual(hold.value, 1 + 5 * Float(exp(-1.0)), accuracy: 0.5)
        // A new peak jumps up and restarts the hold.
        hold.update(8, interval: tick)
        XCTAssertEqual(hold.value, 8)
        for _ in 0..<300 { hold.update(0, interval: tick) }
        XCTAssertEqual(hold.value, 0)
    }
}

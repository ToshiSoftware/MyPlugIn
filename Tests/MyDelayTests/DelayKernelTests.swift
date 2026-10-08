import XCTest
@testable import MyDelay

final class DelayKernelTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let blockSize = 512
    /// 100 ms at 48 kHz.
    private let echo = 4_800

    // MARK: Helpers

    private func makeKernel(_ mode: DelayMode, _ values: [DelayParameter: Float] = [:]) -> DelayKernel {
        let kernel = DelayKernel()
        kernel.setTarget(.mode, Float(mode.rawValue))
        kernel.setTarget(.time, 0.1)
        kernel.setTarget(.mix, 100)
        kernel.setTarget(.width, 100)
        kernel.setTarget(.feedback, 50)
        for (parameter, value) in values { kernel.setTarget(parameter, value) }
        kernel.prepare(sampleRate: sampleRate, maximumFrames: blockSize)
        return kernel
    }

    private func render(_ kernel: DelayKernel, left: [Float], right: [Float],
                        beforeBlock: (Int) -> Void = { _ in }) -> (left: [Float], right: [Float]) {
        var outLeft = left
        var outRight = right
        var start = 0
        var block = 0
        while start < left.count {
            beforeBlock(block)
            let count = min(blockSize, left.count - start)
            left.withUnsafeBufferPointer { inL in
                right.withUnsafeBufferPointer { inR in
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

    /// An impulse on the left input only.
    private func leftImpulse(seconds: Double = 0.5) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: Int(seconds * sampleRate))
        left[0] = 1
        return (left, [Float](repeating: 0, count: left.count))
    }

    private func noise(seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { _ in Float.random(in: -amplitude...amplitude) }
    }

    private func sine(seconds: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { 0.5 * Float(sin(2 * Double.pi * 220 * Double($0) / sampleRate)) }
    }

    private func maxStep(_ signal: [Float]) -> Float {
        zip(signal.dropFirst(), signal).map { abs($0 - $1) }.max() ?? 0
    }

    /// Indices where |sample| > threshold.
    private func hits(_ signal: [Float], above threshold: Float = 1e-4) -> [Int] {
        signal.indices.filter { abs(signal[$0]) > threshold }
    }

    // MARK: Modes

    func testMonoDelaySumsInputAndRepeatsOnBothSides() {
        let input = leftImpulse()
        let (left, right) = render(makeKernel(.mono), left: input.left, right: input.right)
        XCTAssertEqual(hits(left), [echo, 2 * echo, 3 * echo, 4 * echo])
        XCTAssertEqual(left[echo], 0.5, accuracy: 1e-6) // (L + R) / 2
        XCTAssertEqual(left[2 * echo], 0.25, accuracy: 1e-6) // 50 % feedback
        XCTAssertEqual(left, right)
    }

    func testStereoDelayKeepsSidesApart() {
        let input = leftImpulse()
        let (left, right) = render(makeKernel(.stereo), left: input.left, right: input.right)
        XCTAssertEqual(hits(left), [echo, 2 * echo, 3 * echo, 4 * echo])
        XCTAssertEqual(left[echo], 1, accuracy: 1e-6)
        XCTAssertEqual(left[2 * echo], 0.5, accuracy: 1e-6)
        XCTAssertEqual(hits(right), [])
    }

    func testDoublerUsesTwoTimesAndNoFeedback() {
        let input = leftImpulse()
        let (left, right) = render(makeKernel(.doubler, [.feedback: 100]), left: input.left, right: input.right)
        XCTAssertEqual(hits(left), [echo])
        XCTAssertEqual(hits(right), [echo * 3 / 2])
        XCTAssertEqual(left[echo], 0.5, accuracy: 1e-6)
        XCTAssertEqual(right[echo * 3 / 2], 0.5, accuracy: 1e-6)
    }

    func testPingPongAlternatesSides() {
        let input = leftImpulse()
        let (left, right) = render(makeKernel(.pingPong), left: input.left, right: input.right)
        XCTAssertEqual(hits(left), [echo, 3 * echo])
        XCTAssertEqual(hits(right), [2 * echo, 4 * echo])
        XCTAssertEqual(left[echo], 0.5, accuracy: 1e-6)
        XCTAssertEqual(right[2 * echo], 0.25, accuracy: 1e-6)
        XCTAssertEqual(left[3 * echo], 0.125, accuracy: 1e-6)
    }

    func testWidthZeroCentresTheEchoes() {
        for mode in [DelayMode.stereo, .doubler, .pingPong] {
            let input = leftImpulse()
            let (left, right) = render(makeKernel(mode, [.width: 0]), left: input.left, right: input.right)
            XCTAssertEqual(left, right, "\(mode)")
        }
    }

    func testWidthHalfNarrowsTheImage() {
        let input = leftImpulse()
        let (left, right) = render(makeKernel(.stereo, [.width: 50, .feedback: 0]), left: input.left, right: input.right)
        XCTAssertEqual(left[echo], 0.75, accuracy: 1e-6)
        XCTAssertEqual(right[echo], 0.25, accuracy: 1e-6)
    }

    // MARK: Mix, feedback, changes

    func testMixZeroPassesDryUnchanged() {
        let input = noise(seconds: 0.5)
        let output = render(makeKernel(.stereo, [.mix: 0]), left: input, right: input)
        XCTAssertEqual(output.left, input)
        XCTAssertEqual(output.right, input)
    }

    func testFullFeedbackStaysBounded() {
        for mode in [DelayMode.mono, .stereo, .pingPong] {
            let input = noise(seconds: 20, amplitude: 0.9)
            let output = render(makeKernel(mode, [.feedback: 100, .time: 0.05]), left: input, right: input)
            XCTAssertTrue(output.left.allSatisfy { $0.isFinite }, "\(mode)")
            XCTAssertLessThanOrEqual(output.left.map(abs).max()!, DelayKernel.ceiling, "\(mode)")
        }
    }

    func testFullFeedbackHoldsTheRepeats() {
        let input = leftImpulse(seconds: 2.2)
        let (left, _) = render(makeKernel(.stereo, [.feedback: 100, .time: 0.1]), left: input.left, right: input.right)
        // Below full scale the limiter does nothing: the repeats hold exactly.
        for index in 1...21 {
            XCTAssertEqual(left[index * echo], 1, accuracy: 1e-6, "repeat \(index)")
        }
    }

    func testTimeChangesDoNotClick() {
        let input = sine(seconds: 3)
        let kernel = makeKernel(.stereo, [.feedback: 40])
        let output = render(kernel, left: input, right: input) { block in
            kernel.setTarget(.time, block % 6 < 3 ? 0.1 : 0.37)
        }
        XCTAssertLessThan(maxStep(output.left), maxStep(input) * 4 + 0.02)
    }

    func testModeChangesDoNotClick() {
        let input = sine(seconds: 3)
        let kernel = makeKernel(.stereo, [.feedback: 40, .time: 0.05])
        let output = render(kernel, left: input, right: input) { block in
            kernel.setTarget(.mode, Float((block / 20) % DelayMode.allCases.count))
        }
        XCTAssertTrue(output.left.allSatisfy { $0.isFinite })
        XCTAssertLessThan(maxStep(output.left), maxStep(input) * 4 + 0.02)
        XCTAssertLessThan(maxStep(output.right), maxStep(input) * 4 + 0.02)
    }

    func testModeChangeStartsFromEmptyLines() {
        let kernel = makeKernel(.stereo, [.feedback: 90, .time: 0.05])
        _ = render(kernel, left: noise(seconds: 1), right: noise(seconds: 1))
        kernel.setTarget(.mode, Float(DelayMode.mono.rawValue))
        let silence = [Float](repeating: 0, count: 24_000)
        let output = render(kernel, left: silence, right: silence)
        // After the 10 ms fade-out, the old echoes are gone.
        XCTAssertLessThan(output.left[1_024...].map(abs).max()!, 1e-6)
    }

    func testResetAndBypass() {
        let kernel = makeKernel(.stereo, [.feedback: 90])
        _ = render(kernel, left: noise(seconds: 1), right: noise(seconds: 1))
        kernel.requestReset()
        let silence = [Float](repeating: 0, count: 9_600)
        XCTAssertLessThan(render(kernel, left: silence, right: silence).left.map(abs).max()!, 1e-6)

        kernel.isBypassed = true
        let input = noise(seconds: 0.2)
        XCTAssertEqual(render(kernel, left: input, right: input).left, input)
    }

    func testTailTime() {
        let kernel = makeKernel(.stereo, [.feedback: 50, .time: 0.5])
        // 0.5^10 < 0.001: ten repeats after the first echo.
        XCTAssertEqual(kernel.tailTime, 0.5 + 0.5 * 10, accuracy: 1e-9)
        kernel.setTarget(.mode, Float(DelayMode.doubler.rawValue))
        XCTAssertEqual(kernel.tailTime, 0.75, accuracy: 1e-9)
    }

    // MARK: Parameters and editor

    func testParameterStrings() {
        XCTAssertEqual(DelayParameter.time.displayString(for: 0.25), "250 ms")
        XCTAssertEqual(DelayParameter.time.displayString(for: 0.0125), "12.5 ms")
        XCTAssertEqual(DelayParameter.time.displayString(for: 1.5), "1.50 s")
        XCTAssertEqual(DelayParameter.time.value(fromDisplayString: "1.5 s"), 1.5)
        XCTAssertEqual(DelayParameter.time.value(fromDisplayString: "250"), 0.25)
        XCTAssertEqual(DelayParameter.time.value(fromDisplayString: "0.5"), 0.001, "ms, clamped to 1 ms")
        XCTAssertEqual(DelayParameter.mode.value(fromDisplayString: "Ping-Pong"), 3)
        XCTAssertEqual(DelayParameter.mode.displayString(for: 0), "Mono Delay")
        XCTAssertEqual(DelayParameter.mode.clamped(1.6), 2)
        XCTAssertEqual(DelayParameter.feedback.value(fromDisplayString: "45%"), 45)
    }

    func testFaderTaperAndLayout() {
        for parameter in [DelayParameter.time, .feedback, .width, .mix] {
            for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
                let value = DelayFaderTaper.value(for: parameter, fraction: fraction)
                let again = DelayFaderTaper.value(for: parameter,
                                                  fraction: DelayFaderTaper.fraction(for: parameter, value: value))
                XCTAssertEqual(again, value, accuracy: max(value * 1e-3, 1e-5))
            }
        }
        XCTAssertEqual(DelayFaderTaper.value(for: .time, fraction: 0), 0.001)
        XCTAssertEqual(DelayFaderTaper.value(for: .time, fraction: 1), 10)
        XCTAssertEqual(DelayFaderTaper.faders(for: .mono), [.time, .feedback, .mix])
        XCTAssertEqual(DelayFaderTaper.faders(for: .stereo), [.time, .feedback, .width, .mix])
        XCTAssertEqual(DelayFaderTaper.faders(for: .doubler), [.time, .width, .mix])
        XCTAssertEqual(DelayFaderTaper.faders(for: .pingPong), [.time, .feedback, .width, .mix])
    }

    func testRendersMuchFasterThanRealTime() {
        let kernel = makeKernel(.pingPong)
        let input = noise(seconds: 10)
        let start = Date()
        _ = render(kernel, left: input, right: input)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 10)
        print("Rendered 10 s of stereo audio in \(String(format: "%.3f", elapsed)) s")
    }
}

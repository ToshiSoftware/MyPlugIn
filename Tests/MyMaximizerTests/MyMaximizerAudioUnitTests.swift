import AVFoundation
import XCTest
@testable import MyMaximizer
import MyPlugInCore

final class MyMaximizerAudioUnitTests: XCTestCase {
    func testParametersAreUniqueAndComplete() {
        let parameters = MaximizerParameter.allCases
        XCTAssertEqual(parameters.map(\.rawValue), [0, 10, 22, 31, 30, 20])
        XCTAssertEqual(parameters.map(\.identifier),
                       ["input_gain", "upward", "threshold", "attack", "release", "output_level"])
        XCTAssertEqual(MaximizerParameter.threshold.defaultValue, -0.1)
        XCTAssertEqual(MaximizerParameter.threshold.range, -30...0)
        XCTAssertTrue(parameters.allSatisfy { $0.rawValue < MaximizerParameter.addressCount })
        XCTAssertEqual(MaximizerParameter.inputGain.defaultValue, 0)
        XCTAssertEqual(MaximizerParameter.upward.defaultValue, 2)
        XCTAssertEqual(MaximizerParameter.attack.defaultValue, 0)
        XCTAssertEqual(MaximizerParameter.attack.range, 0...10)
        XCTAssertEqual(MaximizerParameter.release.defaultValue, 50)
        XCTAssertEqual(MaximizerParameter.release.range, 10...500)
        XCTAssertEqual(MaximizerParameter.outputLevel.defaultValue, -0.1)
        for parameter in parameters {
            XCTAssertEqual(parameter.clamped(parameter.defaultValue), parameter.defaultValue, "\(parameter)")
        }
    }

    func testDisplayStringsParseBack() {
        XCTAssertEqual(MaximizerParameter.inputGain.displayString(for: 3), "+3.0 dB")
        XCTAssertEqual(MaximizerParameter.outputLevel.displayString(for: -0.1), "-0.1 dB")
        XCTAssertEqual(MaximizerParameter.outputLevel.value(fromDisplayString: "+3"), 0)
        XCTAssertEqual(MaximizerParameter.attack.displayString(for: 2.5), "2.5 ms")
        XCTAssertEqual(MaximizerParameter.threshold.displayString(for: -6), "-6.0 dB")
        XCTAssertEqual(MaximizerParameter.threshold.value(fromDisplayString: "-40"), -30)
        XCTAssertEqual(MaximizerParameter.release.displayString(for: 50), "50 ms")
        XCTAssertEqual(MaximizerParameter.release.value(fromDisplayString: "120 ms"), 120)
        XCTAssertEqual(MaximizerParameter.release.value(fromDisplayString: "5"), 10)
    }

    func testReleaseFaderIsLogarithmic() {
        XCTAssertEqual(MaximizerTaper.fraction(.release, 10), 0)
        XCTAssertEqual(MaximizerTaper.fraction(.release, 500), 1, accuracy: 1e-9)
        XCTAssertEqual(MaximizerTaper.value(.release, MaximizerTaper.fraction(.release, 50)), 50, accuracy: 1e-3)
        XCTAssertEqual(MaximizerTaper.value(.attack, 0.5), 5)
        XCTAssertEqual(MaximizerTaper.value(.inputGain, MaximizerTaper.fraction(.inputGain, 0.2)), 0)
    }

    func testUnitStateLatencyAndEditor() throws {
        let unit = try MyMaximizerAudioUnit(componentDescription: MyMaximizerAudioUnit.componentDescription)
        XCTAssertEqual(unit.parameterTree?.allParameters.map(\.identifier),
                       MaximizerParameter.allCases.map(\.identifier))
        let attack = AUParameterAddress(MaximizerParameter.attack.rawValue)
        unit.parameterTree?.parameter(withAddress: attack)?.value = 4
        let state = unit.fullState

        let restored = try MyMaximizerAudioUnit(componentDescription: MyMaximizerAudioUnit.componentDescription)
        restored.fullState = state
        XCTAssertEqual(restored.parameterTree?.parameter(withAddress: attack)?.value, 4)
        XCTAssertEqual(restored.maximizerKernel.target(.attack), 4)

        try unit.allocateRenderResources()
        XCTAssertEqual(unit.latency, 0.01, accuracy: 1e-9)
        unit.deallocateRenderResources()

        XCTAssertEqual(unit.makeEditorViewController().view.frame.size, NSSize(width: 300, height: 460))
        XCTAssertEqual(unit.makeEditorViewController().preferredContentSize, MyMaximizerAudioUnit.editorSize)
    }

    /// Through AVAudioEngine's offline render, the limiter holds the ceiling.
    func testRendersThroughTheAudioUnit() throws {
        let unit = try MyMaximizerAudioUnit(componentDescription: MyMaximizerAudioUnit.componentDescription)
        unit.parameterTree?.parameter(withAddress: AUParameterAddress(MaximizerParameter.inputGain.rawValue))?.value = 18
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }

        let frames: AVAudioFrameCount = 2_048
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        input.frameLength = frames
        for channel in 0..<2 {
            for frame in 0..<Int(frames) {
                input.floatChannelData![channel][frame] = 0.8 * Float(sin(Double(frame) * 0.05))
            }
        }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        output.frameLength = frames
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        let status = unit.renderBlock(&flags, &timestamp, frames, 0, output.mutableAudioBufferList) { _, _, _, _, inputData in
            let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
            let target = UnsafeMutableAudioBufferListPointer(inputData)
            for channel in 0..<2 {
                memcpy(target[channel].mData, source[channel].mData, Int(source[channel].mDataByteSize))
            }
            return noErr
        }
        XCTAssertEqual(status, noErr)
        let peak = (0..<Int(frames)).map { abs(output.floatChannelData![0][$0]) }.max()!
        XCTAssertGreaterThan(peak, 0.5)
        XCTAssertLessThanOrEqual(peak, pow(10, -0.1 / 20))
    }
}

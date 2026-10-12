import AVFoundation
import XCTest
@testable import MyDeEsser
import MyPlugInCore

final class MyDeEsserAudioUnitTests: XCTestCase {
    func testParametersAreUniqueAndComplete() {
        let parameters = DeEsserParameter.allCases
        XCTAssertEqual(parameters.map(\.rawValue), [0, 10, 20, 21, 22, 23, 30])
        XCTAssertEqual(parameters.map(\.identifier),
                       ["input_gain", "frequency", "threshold", "attack", "release", "stereo_link", "listen"])
        XCTAssertTrue(parameters.allSatisfy { $0.rawValue < DeEsserParameter.addressCount })
        XCTAssertEqual(DeEsserParameter.inputGain.range, -24...24)
        XCTAssertEqual(DeEsserParameter.frequency.range, 2_000...15_000)
        XCTAssertEqual(DeEsserParameter.frequency.defaultValue, 6_500)
        XCTAssertEqual(DeEsserParameter.threshold.range, -60...0)
        XCTAssertEqual(DeEsserParameter.threshold.defaultValue, -12)
        XCTAssertEqual(DeEsserParameter.attack.range, 0...5)
        XCTAssertEqual(DeEsserParameter.attack.defaultValue, 0)
        XCTAssertEqual(DeEsserParameter.release.range, 5...50)
        XCTAssertEqual(DeEsserParameter.release.defaultValue, 10)
        XCTAssertEqual(DeEsserParameter.stereoLink.defaultValue, 1)
        XCTAssertEqual(DeEsserParameter.listen.defaultValue, 0)
        for parameter in parameters {
            XCTAssertEqual(parameter.clamped(parameter.defaultValue), parameter.defaultValue, "\(parameter)")
        }
    }

    func testDisplayStringsParseBack() {
        XCTAssertEqual(DeEsserParameter.inputGain.displayString(for: 3), "+3.0 dB")
        XCTAssertEqual(DeEsserParameter.threshold.displayString(for: -12), "-12.0 dB")
        XCTAssertEqual(DeEsserParameter.frequency.displayString(for: 6_500), "6.50k")
        XCTAssertEqual(DeEsserParameter.frequency.displayString(for: 12_000), "12.0k")
        XCTAssertEqual(DeEsserParameter.frequency.value(fromDisplayString: "6.5k"), 6_500)
        XCTAssertEqual(DeEsserParameter.frequency.value(fromDisplayString: "8000"), 8_000)
        XCTAssertEqual(DeEsserParameter.frequency.value(fromDisplayString: "8"), 8_000)
        XCTAssertEqual(DeEsserParameter.frequency.value(fromDisplayString: "40k"), 15_000)
        XCTAssertEqual(DeEsserParameter.attack.displayString(for: 2.5), "2.5 ms")
        XCTAssertEqual(DeEsserParameter.release.displayString(for: 10), "10 ms")
        XCTAssertEqual(DeEsserParameter.release.value(fromDisplayString: "1"), 5)
        XCTAssertEqual(DeEsserParameter.stereoLink.displayString(for: 1), "On")
        XCTAssertEqual(DeEsserParameter.listen.value(fromDisplayString: "on"), 1)
        XCTAssertEqual(DeEsserParameter.listen.clamped(0.7), 1)
    }

    func testTapers() {
        XCTAssertEqual(DeEsserTaper.fraction(.frequency, 2_000), 0)
        XCTAssertEqual(DeEsserTaper.fraction(.frequency, 15_000), 1, accuracy: 1e-9)
        XCTAssertEqual(DeEsserTaper.value(.frequency, DeEsserTaper.fraction(.frequency, 6_500)), 6_500, accuracy: 0.5)
        XCTAssertEqual(DeEsserTaper.value(.release, DeEsserTaper.fraction(.release, 10)), 10, accuracy: 1e-3)
        XCTAssertEqual(DeEsserTaper.value(.threshold, 0.8), -12)
        XCTAssertEqual(DeEsserTaper.value(.inputGain, DeEsserTaper.fraction(.inputGain, 0.2)), 0)
    }

    func testUnitStateLatencyAndEditor() throws {
        let unit = try MyDeEsserAudioUnit(componentDescription: MyDeEsserAudioUnit.componentDescription)
        XCTAssertEqual(unit.parameterTree?.allParameters.map(\.identifier),
                       DeEsserParameter.allCases.map(\.identifier))
        let threshold = DeEsserParameter.threshold.address
        let link = DeEsserParameter.stereoLink.address
        unit.parameterTree?.parameter(withAddress: threshold)?.value = -30
        unit.parameterTree?.parameter(withAddress: link)?.value = 0
        let state = unit.fullState

        let restored = try MyDeEsserAudioUnit(componentDescription: MyDeEsserAudioUnit.componentDescription)
        restored.fullState = state
        XCTAssertEqual(restored.parameterTree?.parameter(withAddress: threshold)?.value, -30)
        XCTAssertEqual(restored.deEsserKernel.target(.threshold), -30)
        XCTAssertEqual(restored.deEsserKernel.target(.stereoLink), 0)

        try unit.allocateRenderResources()
        XCTAssertEqual(unit.latency, 0.002, accuracy: 1e-9)
        unit.deallocateRenderResources()

        XCTAssertEqual(unit.makeEditorViewController().view.frame.size, NSSize(width: 300, height: 500))
        XCTAssertEqual(unit.makeEditorViewController().preferredContentSize, MyDeEsserAudioUnit.editorSize)
    }

    /// Through the render block, a loud 10 kHz tone comes out turned down
    /// and a 300 Hz tone does not.
    func testRendersThroughTheAudioUnit() throws {
        let unit = try MyDeEsserAudioUnit(componentDescription: MyDeEsserAudioUnit.componentDescription)
        unit.parameterTree?.parameter(withAddress: DeEsserParameter.threshold.address)?.value = -30
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }

        func peak(of frequency: Double) -> Float {
            let frames: AVAudioFrameCount = 4_096
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            input.frameLength = frames
            for channel in 0..<2 {
                for frame in 0..<Int(frames) {
                    input.floatChannelData![channel][frame] = 0.5 * Float(sin(2 * .pi * frequency * Double(frame) / 48_000))
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
            return (2_048..<Int(frames)).map { abs(output.floatChannelData![0][$0]) }.max()!
        }
        XCTAssertEqual(peak(of: 300), 0.5, accuracy: 0.01)
        XCTAssertLessThan(peak(of: 12_000), 0.15)
    }
}

import AVFoundation
import XCTest
@testable import MyDelayKit
import MyFXShared

final class MyDelayAudioUnitTests: XCTestCase {
    private let frames: AUAudioFrameCount = 512

    private func makeUnit(channels: AVAudioChannelCount = 2) throws -> MyDelayAudioUnit {
        let unit = try MyDelayAudioUnit(componentDescription: MyDelayAudioUnit.componentDescription)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = frames
        try unit.allocateRenderResources()
        return unit
    }

    private func address(_ parameter: DelayParameter) -> AUParameterAddress {
        AUParameterAddress(parameter.rawValue)
    }

    private func render(_ unit: AUAudioUnit, frameCount: AUAudioFrameCount? = nil, sampleTime: Double = 0,
                        inputValue: @escaping (Int, Int) -> Float) -> (AUAudioUnitStatus, [[Float]]) {
        let count = frameCount ?? frames
        let format = unit.outputBusses[0].format
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(count, 1))!
        buffer.frameLength = count
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid
        var flags = AudioUnitRenderActionFlags()
        let status = unit.renderBlock(&flags, &timestamp, count, 0, buffer.mutableAudioBufferList) { _, _, pullFrames, _, input in
            let list = UnsafeMutableAudioBufferListPointer(input)
            for channel in 0..<list.count {
                let samples = list[channel].mData!.assumingMemoryBound(to: Float.self)
                for frame in 0..<Int(pullFrames) { samples[frame] = inputValue(channel, frame) }
            }
            return noErr
        }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let output = (0..<Int(format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: list[channel].mData!.assumingMemoryBound(to: Float.self), count: Int(count)))
        }
        return (status, output)
    }

    func testInProcessRegistrationGivesAVAudioUnitAName() throws {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x5444_6C79, // 'TDly'
            componentManufacturer: 0x546F_6B61,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        MyDelayAudioUnit.registerInProcess(as: description, name: "Toka: MyDelay Test")
        let instantiated = expectation(description: "instantiate")
        var unit: AVAudioUnit?
        AVAudioUnit.instantiate(with: description, options: []) { audioUnit, _ in
            unit = audioUnit
            instantiated.fulfill()
        }
        wait(for: [instantiated], timeout: 5)
        XCTAssertEqual(unit?.name, "MyDelay Test")
        XCTAssertTrue(unit?.auAudioUnit is MyDelayAudioUnit)
    }

    func testEchoArrivesAtTheSetTime() throws {
        let unit = try makeUnit()
        unit.parameterTree?.parameter(withAddress: address(.time))?.value = 0.02 // 960 frames
        unit.reset()
        var left: [Float] = []
        for block in 0..<4 {
            let (status, output) = render(unit, sampleTime: Double(block) * Double(frames)) { channel, frame in
                block == 0 && frame == 0 && channel == 0 ? 1 : 0
            }
            XCTAssertEqual(status, noErr)
            left += output[0]
        }
        XCTAssertEqual(left.indices.filter { abs(left[$0]) > 1e-4 }.first, 960)
    }

    func testScheduledModeChangeIsApplied() throws {
        let unit = try makeUnit()
        unit.scheduleParameterBlock(AUEventSampleTimeImmediate, 0, address(.mode), Float(DelayMode.pingPong.rawValue))
        _ = render(unit) { _, _ in 0 }
        XCTAssertEqual(unit.parameterTree?.parameter(withAddress: address(.mode))?.value,
                       Float(DelayMode.pingPong.rawValue))
    }

    func testMonoAndFrameLimits() throws {
        let mono = try makeUnit(channels: 1)
        XCTAssertEqual(render(mono) { _, frame in Float(frame % 7) * 0.1 }.0, noErr)
        let stereo = try makeUnit()
        XCTAssertEqual(render(stereo, frameCount: frames * 2) { _, _ in 0 }.0, kAudioUnitErr_TooManyFramesToProcess)
    }

    func testParametersRoundTripThroughFullState() throws {
        let unit = try makeUnit()
        let tree = try XCTUnwrap(unit.parameterTree)
        tree.parameter(withAddress: address(.mode))?.value = Float(DelayMode.doubler.rawValue)
        tree.parameter(withAddress: address(.time))?.value = 0.033
        let restored = try makeUnit()
        restored.fullState = unit.fullState
        let restoredTree = try XCTUnwrap(restored.parameterTree)
        XCTAssertEqual(restoredTree.parameter(withAddress: address(.mode))?.value, Float(DelayMode.doubler.rawValue))
        XCTAssertEqual(restoredTree.parameter(withAddress: address(.time))?.value ?? 0, 0.033, accuracy: 1e-6)
        XCTAssertEqual(restoredTree.parameter(withAddress: address(.feedback))?.value, 30)
    }

    func testModeParameterIsAnIndexedList() throws {
        let unit = try makeUnit()
        let mode = try XCTUnwrap(unit.parameterTree?.parameter(withAddress: address(.mode)))
        XCTAssertEqual(mode.unit, .indexed)
        XCTAssertEqual(mode.valueStrings ?? [], ["Mono Delay", "Stereo Delay", "Doubler", "Ping-Pong"])
        XCTAssertEqual(mode.value, 1)
    }

    func testEditorAndMeters() throws {
        let unit = try makeUnit()
        unit.shouldBypassEffect = true
        _ = render(unit) { _, frame in frame == 3 ? 0.25 : 0 }
        XCTAssertEqual(unit.takeMeterPeaks().inputLeft, 0.25)

        let delivered = expectation(description: "view controller")
        var controller: NSViewController?
        unit.requestViewController { viewController in
            controller = viewController
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 2)
        let editor = try XCTUnwrap(controller as? MyFXEditorViewController)
        XCTAssertEqual(editor.view.frame.size, NSSize(width: 300, height: 400))
        editor.model.setOnce(address(.mode), 0)
        XCTAssertEqual(unit.parameterTree?.parameter(withAddress: address(.mode))?.value, 0)
    }
}

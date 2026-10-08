import AVFoundation
import XCTest
@testable import MyReverb
import MyPlugInCore

final class MyReverbAudioUnitTests: XCTestCase {
    private let frames: AUAudioFrameCount = 512

    private func makeUnit(channels: AVAudioChannelCount = 2) throws -> MyReverbAudioUnit {
        let unit = try MyReverbAudioUnit(componentDescription: MyReverbAudioUnit.componentDescription)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = frames
        try unit.allocateRenderResources()
        return unit
    }

    /// Renders one buffer whose input is `inputValue(channel, frame)`.
    /// `outputBuffers: false` passes nil mData, as hosts may.
    private func render(_ unit: AUAudioUnit, frameCount: AUAudioFrameCount? = nil, sampleTime: Double = 0,
                        outputBuffers: Bool = true,
                        inputValue: @escaping (Int, Int) -> Float) -> (AUAudioUnitStatus, [[Float]]) {
        let count = frameCount ?? frames
        let channels = Int(unit.outputBusses[0].format.channelCount)
        let format = unit.outputBusses[0].format
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(count, 1))!
        buffer.frameLength = count
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        if !outputBuffers {
            for index in 0..<list.count { list[index].mData = nil }
        }
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid
        var flags = AudioUnitRenderActionFlags()
        let status = unit.renderBlock(&flags, &timestamp, count, 0, buffer.mutableAudioBufferList) { _, _, pullFrames, _, input in
            let inputList = UnsafeMutableAudioBufferListPointer(input)
            for channel in 0..<inputList.count {
                let samples = inputList[channel].mData!.assumingMemoryBound(to: Float.self)
                for frame in 0..<Int(pullFrames) { samples[frame] = inputValue(channel, frame) }
            }
            return noErr
        }
        let output = (0..<channels).map { channel -> [Float] in
            let samples = list[channel].mData!.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: samples, count: Int(count)))
        }
        return (status, output)
    }

    private func value(_ channel: Int, _ frame: Int) -> Float {
        Float(sin(Double(frame) * 0.05 + Double(channel))) * 0.5
    }

    // MARK: Tests

    /// MyDAW aborted in -[AVAudioUnit name] for a component named without
    /// "Vendor: ". Registered with a proper name, AVAudioUnit can read it.
    func testInProcessRegistrationGivesAVAudioUnitAName() throws {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x5465_7374, // 'Test'
            componentManufacturer: 0x546F_6B61,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        MyReverbAudioUnit.registerInProcess(as: description, name: "Toka: MyReverb Test")
        let expectation = expectation(description: "instantiate")
        var instantiated: AVAudioUnit?
        AVAudioUnit.instantiate(with: description, options: []) { unit, _ in
            instantiated = unit
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        let unit = try XCTUnwrap(instantiated)
        XCTAssertEqual(unit.name, "MyReverb Test")
        XCTAssertEqual(unit.manufacturerName, "Toka")
        XCTAssertTrue(unit.auAudioUnit is MyReverbAudioUnit)
    }

    func testRendersReverbIntoHostBuffers() throws {
        let unit = try makeUnit()
        var heard = false
        for block in 0..<20 {
            let (status, output) = render(unit, sampleTime: Double(block) * Double(frames)) { channel, frame in
                block == 0 && frame == 0 ? 1 : 0
            }
            XCTAssertEqual(status, noErr)
            XCTAssertTrue(output.joined().allSatisfy { $0.isFinite })
            if block > 2, output[0].contains(where: { abs($0) > 1e-5 }) { heard = true }
        }
        XCTAssertTrue(heard, "no tail after the impulse")
    }

    func testRendersInPlaceWhenHostGivesNoBuffers() throws {
        let unit = try makeUnit()
        unit.parameterTree?.parameter(withAddress: AUParameterAddress(ReverbParameter.mix.rawValue))?.value = 0
        unit.reset()
        let (status, output) = render(unit, outputBuffers: false, inputValue: value)
        XCTAssertEqual(status, noErr)
        XCTAssertEqual(output[0][100], value(0, 100), accuracy: 1e-6)
        XCTAssertEqual(output[1][100], value(1, 100), accuracy: 1e-6)
    }

    func testMonoRenders() throws {
        let unit = try makeUnit(channels: 1)
        let (status, output) = render(unit, inputValue: value)
        XCTAssertEqual(status, noErr)
        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(output[0].allSatisfy { $0.isFinite })
    }

    func testTooManyFramesIsRefused() throws {
        let unit = try makeUnit()
        let (status, _) = render(unit, frameCount: frames * 2, inputValue: value)
        XCTAssertEqual(status, kAudioUnitErr_TooManyFramesToProcess)
    }

    func testUnsupportedFormatsAreRefused() throws {
        let unit = try MyReverbAudioUnit(componentDescription: MyReverbAudioUnit.componentDescription)
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
        let surround = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        XCTAssertThrowsError(try unit.inputBusses[0].setFormat(surround))
        let interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        XCTAssertThrowsError(try unit.outputBusses[0].setFormat(interleaved))
        let stereo96 = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        XCTAssertNoThrow(try unit.outputBusses[0].setFormat(stereo96))
    }

    func testScheduledParameterEventsAreApplied() throws {
        let unit = try makeUnit()
        // Mix 0 scheduled at frame 0 of this buffer: dry comes out (after the
        // 20 ms mix glide), so the last frames of the third buffer equal the input.
        unit.scheduleParameterBlock(AUEventSampleTimeImmediate, 0,
                                    AUParameterAddress(ReverbParameter.mix.rawValue), 0)
        var output: [[Float]] = []
        for block in 0..<12 {
            output = render(unit, sampleTime: Double(block) * Double(frames), inputValue: value).1
        }
        XCTAssertEqual(output[0][Int(frames) - 1], value(0, Int(frames) - 1), accuracy: 1e-3)
        XCTAssertEqual(unit.parameterTree?.parameter(withAddress: AUParameterAddress(ReverbParameter.mix.rawValue))?.value, 0)
    }

    func testParametersRoundTripThroughFullState() throws {
        let unit = try makeUnit()
        let tree = try XCTUnwrap(unit.parameterTree)
        tree.parameter(withAddress: AUParameterAddress(ReverbParameter.rt.rawValue))?.value = 7.5
        tree.parameter(withAddress: AUParameterAddress(ReverbParameter.hpf.rawValue))?.value = 0
        let state = try XCTUnwrap(unit.fullState)

        let restored = try makeUnit()
        restored.fullState = state
        let restoredTree = try XCTUnwrap(restored.parameterTree)
        XCTAssertEqual(restoredTree.parameter(withAddress: AUParameterAddress(ReverbParameter.rt.rawValue))?.value, 7.5)
        XCTAssertEqual(restoredTree.parameter(withAddress: AUParameterAddress(ReverbParameter.hpf.rawValue))?.value, 0)
        XCTAssertEqual(restoredTree.parameter(withAddress: AUParameterAddress(ReverbParameter.lpf.rawValue))?.value, 8_000)
    }

    func testDefaultsAndDisplay() throws {
        let unit = try makeUnit()
        let tree = try XCTUnwrap(unit.parameterTree)
        XCTAssertEqual(tree.allParameters.map(\.identifier), ["hpf", "lpf", "rt", "preDelay", "mix"])
        let hpf = try XCTUnwrap(tree.parameter(withAddress: AUParameterAddress(ReverbParameter.hpf.rawValue)))
        XCTAssertEqual(hpf.value, 80)
        XCTAssertEqual(hpf.string(fromValue: nil), "80 Hz")
        var zero: AUValue = 0
        XCTAssertEqual(hpf.string(fromValue: &zero), "Thru")
        XCTAssertEqual(unit.tailTime, 2.02, accuracy: 1e-4)
    }

    func testBypassPassesInput() throws {
        let unit = try makeUnit()
        unit.shouldBypassEffect = true
        let (status, output) = render(unit, inputValue: value)
        XCTAssertEqual(status, noErr)
        XCTAssertEqual(output[1][200], value(1, 200))
    }
    // MARK: Editor

    func testFaderTaperRoundTrips() {
        for parameter in ReverbParameter.allCases {
            for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
                let value = ReverbFaderTaper.value(for: parameter, fraction: fraction)
                XCTAssertTrue(parameter.range.contains(value), "\(parameter) \(value)")
                let back = ReverbFaderTaper.fraction(for: parameter, value: value)
                let again = ReverbFaderTaper.value(for: parameter, fraction: back)
                XCTAssertEqual(again, value, accuracy: max(abs(value) * 1e-3, 1e-4), "\(parameter) at \(fraction)")
            }
        }
        XCTAssertEqual(ReverbFaderTaper.value(for: .hpf, fraction: 0), 0) // Thru
        XCTAssertEqual(ReverbFaderTaper.value(for: .lpf, fraction: 1), 24_000) // Thru
        XCTAssertEqual(ReverbFaderTaper.fraction(for: .preDelay, value: 0.25), 0.5, accuracy: 1e-6)
    }

    func testMeterPeaksFollowInputAndOutput() throws {
        let unit = try makeUnit()
        unit.shouldBypassEffect = true
        _ = render(unit) { _, frame in frame == 10 ? 0.5 : 0 }
        let peaks = unit.takeMeterPeaks()
        XCTAssertEqual(peaks.inputLeft, 0.5)
        XCTAssertEqual(peaks.outputRight, 0.5)
        XCTAssertEqual(unit.takeMeterPeaks().inputLeft, 0, "taking the peaks starts over")
    }

    func testEditorSetsParameters() throws {
        let unit = try makeUnit()
        let model = MyFXEditorModel(parameterTree: unit.parameterTree, metering: unit)
        let rt = AUParameterAddress(ReverbParameter.rt.rawValue)
        let mix = AUParameterAddress(ReverbParameter.mix.rawValue)
        model.set(rt, 4.5)
        XCTAssertEqual(unit.parameterTree?.parameter(withAddress: rt)?.value, 4.5)
        XCTAssertEqual(model.value(rt), 4.5)
        model.set(mix, 250)
        XCTAssertEqual(model.value(mix), 100, "clamped")
    }

    func testEditorFollowsHostChanges() throws {
        let unit = try makeUnit()
        let model = MyFXEditorModel(parameterTree: unit.parameterTree, metering: unit)
        let lpf = AUParameterAddress(ReverbParameter.lpf.rawValue)
        unit.parameterTree?.parameter(withAddress: lpf)?.value = 3_000
        // Observers are notified asynchronously; give it up to a second.
        let deadline = Date().addingTimeInterval(1)
        while model.value(lpf) != 3_000 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(model.value(lpf), 3_000)
    }

    func testRequestViewControllerGivesTheEditor() throws {
        let unit = try makeUnit()
        let delivered = expectation(description: "view controller")
        var controller: NSViewController?
        unit.requestViewController { viewController in
            controller = viewController
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 2)
        let editor = try XCTUnwrap(controller as? MyFXEditorViewController)
        XCTAssertEqual(editor.view.frame.size, NSSize(width: 300, height: 400))
    }
}

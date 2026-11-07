import AppKit
import AVFoundation
import AudioToolbox
import CoreAudioKit
import CoreMIDI
import SwiftUI

/// The DSP side of an instrument, as MyFXInstrumentAudioUnit drives it.
/// Threading: `prepare` while not rendering; `applyParameter`,
/// `receiveMIDI` and `render` on the render thread; the rest from any thread.
public protocol MyFXInstrumentKernel: AnyObject {
    func prepare(sampleRate: Double, maximumFrames: Int)
    /// Silences every voice at the start of the next `render`.
    func requestReset()
    var tailTime: Double { get }
    /// The current target of a parameter (what the host reads back).
    func targetValue(_ address: AUParameterAddress) -> AUValue

    /// Render thread: a parameter event at the current position.
    func applyParameter(_ address: AUParameterAddress, _ value: AUValue)
    /// Render thread: one MIDI 1.0 channel message at the current position
    /// (`data2` is 0 for two-byte messages).
    func receiveMIDI(status: UInt8, data1: UInt8, data2: UInt8)
    /// Writes (not adds) `frameCount` frames. `right` is nil for mono.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frameCount: Int)
}

/// Base of every MyPlugIn instrument: an AUv3 music device with no input
/// and one 1- or 2-channel output (Float32, deinterleaved) around a
/// MyFXInstrumentKernel. Like MyFXAudioUnit it builds the parameter tree,
/// saves the parameters in `fullState` and hands hosts the editor; MIDI
/// from `scheduleMIDIEventBlock` reaches the kernel sample-accurately.
///
/// A subclass gives its component description ('aumu'), display name and
/// version, overrides `init(componentDescription:options:)` to pass its
/// configuration, and `makeEditorView(model:)` to return its editor.
open class MyFXInstrumentAudioUnit: AUAudioUnit, @unchecked Sendable {
    public struct Configuration {
        public let kernel: any MyFXInstrumentKernel
        public let parameters: [MyFXParameterDescriptor]
        /// Key of the parameter values in `fullState`; never change it.
        public let stateKey: String

        public init<Parameter: MyFXParameter>(kernel: any MyFXInstrumentKernel, parameters: Parameter.Type,
                                              stateKey: String) {
            self.kernel = kernel
            self.parameters = Parameter.descriptors
            self.stateKey = stateKey
        }
    }

    /// 'aumu' subtype 'Toka' for the app extension and tests.
    open class var componentDescription: AudioComponentDescription {
        fatalError("\(self) must override componentDescription")
    }

    /// Name without vendor ("MySynth").
    open class var displayName: String {
        fatalError("\(self) must override displayName")
    }

    open class var version: UInt32 { 0x0001_0000 }

    /// The editor's size; hosts size the plug-in window to it.
    open class var editorSize: NSSize { MyFXEditorViewController.preferredSize }

    /// Makes the unit available to AVAudioUnit.instantiate in this process
    /// under `description`. `name` must be "Vendor: Name".
    public class func registerInProcess(as description: AudioComponentDescription, name: String) {
        AUAudioUnit.registerSubclass(self, as: description, name: name, version: version)
    }

    public let instrumentKernel: any MyFXInstrumentKernel
    private let parameters: [MyFXParameterDescriptor]
    private let stateKey: String
    private let renderer = MyFXInstrumentRenderer()
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    /// Subclasses override this and call `init(componentDescription:options:configuration:)`.
    public required override init(componentDescription: AudioComponentDescription,
                                  options: AudioComponentInstantiationOptions = []) throws {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidProperty),
                      userInfo: [NSLocalizedDescriptionKey: "MyFXInstrumentAudioUnit is abstract"])
    }

    public init(componentDescription: AudioComponentDescription,
                options: AudioComponentInstantiationOptions,
                configuration: Configuration) throws {
        instrumentKernel = configuration.kernel
        parameters = configuration.parameters
        stateKey = configuration.stateKey
        try super.init(componentDescription: componentDescription, options: options)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        let outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 2
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        let kernel = configuration.kernel
        parameterTree = MyFXParameterDescriptor.makeTree(parameters,
                                                         apply: { [kernel] in kernel.applyParameter($0, $1) },
                                                         current: { [kernel] in kernel.targetValue($0) })
        maximumFramesToRender = 4_096
    }

    // MARK: Editor

    /// The instrument's editor content.
    open func makeEditorView(model: MyFXEditorModel) -> AnyView {
        AnyView(EmptyView())
    }

    public func makeEditorViewController() -> MyFXEditorViewController {
        let model = MyFXEditorModel(parameterTree: parameterTree, metering: nil)
        model.followChannelName(of: self)
        return MyFXEditorViewController(model: model, rootView: makeEditorView(model: model),
                                        size: type(of: self).editorSize)
    }

    public override func requestViewController(completionHandler: @escaping (NSViewController?) -> Void) {
        DispatchQueue.main.async {
            completionHandler(self.makeEditorViewController())
        }
    }

    // MARK: Properties

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    open override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    public override var channelCapabilities: [NSNumber]? { [0, 1, 0, 2] }
    public override var tailTime: TimeInterval { instrumentKernel.tailTime }
    public override var latency: TimeInterval { 0 }
    public override var supportsUserPresets: Bool { false }

    public override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              (1...2).contains(format.channelCount) else { return false }
        return super.shouldChange(to: format, for: bus)
    }

    /// Parameter values by identifier, on top of the base class's state, so
    /// a project restores them regardless of the host.
    open override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            var values: [String: NSNumber] = [:]
            for parameter in parameters {
                values[parameter.identifier] = NSNumber(value: instrumentKernel.targetValue(parameter.address))
            }
            state[stateKey] = values
            return state
        }
        set {
            // "data" is AUAudioUnit's archive of the parameter tree. It raises
            // an exception when the saved tree differs from today's, so it
            // gets today's; the values are restored from stateKey below.
            var state = newValue
            if state?[stateKey] != nil, state?["data"] != nil { state?["data"] = super.fullState?["data"] }
            super.fullState = state
            guard let values = newValue?[stateKey] as? [String: NSNumber],
                  let tree = parameterTree else { return }
            for parameter in parameters {
                guard let value = values[parameter.identifier] else { continue }
                tree.parameter(withAddress: parameter.address)?.value = value.floatValue
            }
        }
    }

    // MARK: Render resources

    open override func allocateRenderResources() throws {
        let output = outputBusses[0].format
        guard (1...2).contains(output.channelCount) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        let frames = Int(maximumFramesToRender)
        renderer.allocate(frames: frames)
        instrumentKernel.prepare(sampleRate: output.sampleRate, maximumFrames: frames)
    }

    public override func reset() {
        super.reset()
        instrumentKernel.requestReset()
    }

    open override var internalRenderBlock: AUInternalRenderBlock {
        renderer.makeRenderBlock(kernel: instrumentKernel)
    }
}

/// Output buffers and the render block of a MyFX instrument. It renders
/// into the host's buffers (or its own when the host gives none) and splits
/// each buffer at parameter and MIDI events so both are sample-accurate.
public final class MyFXInstrumentRenderer {
    public private(set) var capacity = 0
    private var left = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var right = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    public init() {}

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// From allocateRenderResources (not while rendering).
    public func allocate(frames: Int) {
        left.deallocate()
        right.deallocate()
        capacity = frames
        left = .allocate(capacity: frames)
        right = .allocate(capacity: frames)
        left.initialize(repeating: 0, count: frames)
        right.initialize(repeating: 0, count: frames)
    }

    public func makeRenderBlock(kernel: any MyFXInstrumentKernel) -> AUInternalRenderBlock {
        return { [self] _, timestamp, frameCount, _, outputData, realtimeEventListHead, _ in
            let frames = Int(frameCount)
            guard frames <= capacity else { return kAudioUnitErr_TooManyFramesToProcess }
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            guard output.count >= 1 else { return kAudioUnitErr_FormatNotSupported }
            let byteSize = UInt32(frames * MemoryLayout<Float>.size)
            // No output buffers from the host: render into ours.
            if output[0].mData == nil { output[0].mData = UnsafeMutableRawPointer(left) }
            output[0].mDataByteSize = byteSize
            if output.count > 1 {
                if output[1].mData == nil { output[1].mData = UnsafeMutableRawPointer(right) }
                output[1].mDataByteSize = byteSize
            }
            guard let leftData = output[0].mData else { return kAudioUnitErr_InvalidParameter }
            let outputLeft = leftData.assumingMemoryBound(to: Float.self)
            let outputRight = output.count > 1 ? output[1].mData?.assumingMemoryBound(to: Float.self) : nil

            let bufferStart = AUEventSampleTime(timestamp.pointee.mSampleTime)
            var event = realtimeEventListHead
            var segmentStart = 0
            while segmentStart < frames {
                var segmentEnd = frames
                while let current = event {
                    let offset = Int(min(max(current.pointee.head.eventSampleTime - bufferStart, 0),
                                         AUEventSampleTime(frames)))
                    if offset > segmentStart {
                        segmentEnd = offset
                        break
                    }
                    switch current.pointee.head.eventType {
                    case .parameter, .parameterRamp:
                        let change = current.pointee.parameter
                        kernel.applyParameter(change.parameterAddress, change.value)
                    case .MIDI:
                        let midi = current.pointee.MIDI
                        if midi.length > 0 {
                            kernel.receiveMIDI(status: midi.data.0,
                                               data1: midi.length > 1 ? midi.data.1 : 0,
                                               data2: midi.length > 2 ? midi.data.2 : 0)
                        }
                    case .midiEventList:
                        MyFXMIDIEventList.forEachMessage(in: current) { status, data1, data2 in
                            kernel.receiveMIDI(status: status, data1: data1, data2: data2)
                        }
                    default:
                        break
                    }
                    event = UnsafePointer(current.pointee.head.next)
                }
                kernel.render(left: outputLeft + segmentStart,
                              right: outputRight.map { $0 + segmentStart },
                              frameCount: segmentEnd - segmentStart)
                segmentStart = segmentEnd
            }
            return noErr
        }
    }
}

/// Reads the Universal MIDI Packets of a render event's MIDIEventList as
/// MIDI 1.0 channel messages: MIDI 1.0 channel voice packets as they are,
/// MIDI 2.0 ones scaled down. Everything else (system, SysEx) is skipped.
public enum MyFXMIDIEventList {
    public static func forEachMessage(in event: UnsafePointer<AURenderEvent>,
                               _ body: (UInt8, UInt8, UInt8) -> Void) {
        guard let listOffset = MemoryLayout<AUMIDIEventList>.offset(of: \.eventList) else { return }
        let list = UnsafeRawPointer(event) + listOffset
        forEachMessage(inList: list.assumingMemoryBound(to: MIDIEventList.self), body)
    }

    public static func forEachMessage(inList list: UnsafePointer<MIDIEventList>,
                                      _ body: (UInt8, UInt8, UInt8) -> Void) {
        guard let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet),
              let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) else { return }
        let wordCountOffset = MemoryLayout<UInt64>.size
        var packet = UnsafeRawPointer(list) + packetOffset
        for _ in 0..<Int(list.pointee.numPackets) {
            let wordCount = Int(packet.loadUnaligned(fromByteOffset: wordCountOffset, as: UInt32.self))
            let words = packet + wordsOffset
            var index = 0
            while index < wordCount {
                let word = words.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                let size = packetSize(ofType: word >> 28)
                if index + size > wordCount { break }
                let second = size > 1 ? words.loadUnaligned(fromByteOffset: (index + 1) * 4, as: UInt32.self) : 0
                decode(word, second, body)
                index += size
            }
            // Packets follow each other with no padding (words are 4-byte aligned).
            packet = words + wordCount * 4
        }
    }

    /// UMP size in words by message type.
    private static func packetSize(ofType type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }

    private static func decode(_ word: UInt32, _ second: UInt32, _ body: (UInt8, UInt8, UInt8) -> Void) {
        let status = UInt8((word >> 16) & 0xFF)
        let index = UInt8((word >> 8) & 0x7F)
        switch word >> 28 {
        case 0x2:
            body(status, index, UInt8(word & 0x7F))
        case 0x4:
            switch status & 0xF0 {
            case 0x80, 0x90:
                var velocity = UInt8(second >> 25)
                // A MIDI 2.0 note-on is never a note-off, however soft.
                if status & 0xF0 == 0x90, velocity == 0 { velocity = 1 }
                body(status, index, velocity)
            case 0xA0, 0xB0:
                body(status, index, UInt8(second >> 25))
            case 0xC0:
                body(status, UInt8((second >> 24) & 0x7F), 0)
            case 0xD0:
                body(status, UInt8(second >> 25), 0)
            case 0xE0:
                let bend = second >> 18
                body(status, UInt8(bend & 0x7F), UInt8(bend >> 7))
            default:
                break
            }
        default:
            break
        }
    }
}

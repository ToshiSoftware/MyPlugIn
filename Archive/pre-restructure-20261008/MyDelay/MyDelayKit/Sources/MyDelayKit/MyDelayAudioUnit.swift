import AppKit
import AVFoundation
import AudioToolbox
import CoreAudioKit
#if canImport(MyFXShared)
import MyFXShared
#endif

/// MyDelay as an AUv3 effect (1 or 2 channels in = out, Float32
/// deinterleaved). MyDAW registers it in-process with
/// `registerInProcess(as:name:)`.
public final class MyDelayAudioUnit: AUAudioUnit, MyFXMetering, @unchecked Sendable {
    /// 'aufx' 'MDly' 'Toka', for an app extension or a test host.
    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x4D44_6C79, // 'MDly'
        componentManufacturer: 0x546F_6B61, // 'Toka'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    public static let version: UInt32 = 0x0001_0000

    private static let stateKey = "MyDelayParameters"

    /// Makes the unit available to AVAudioUnit.instantiate in this process
    /// under `description`. `name` must be "Vendor: Name".
    public static func registerInProcess(as description: AudioComponentDescription, name: String) {
        AUAudioUnit.registerSubclass(MyDelayAudioUnit.self, as: description, name: name, version: version)
    }

    private let kernel = DelayKernel()
    private let renderer = MyFXRenderer()
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        let inputBus = try AUAudioUnitBus(format: format)
        let outputBus = try AUAudioUnitBus(format: format)
        inputBus.maximumChannelCount = 2
        outputBus.maximumChannelCount = 2
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        parameterTree = Self.makeParameterTree(kernel: kernel)
        maximumFramesToRender = 4_096
    }

    // MARK: Properties

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    public override var channelCapabilities: [NSNumber]? { [1, 1, 2, 2] }
    public override var tailTime: TimeInterval { kernel.tailTime }
    public override var latency: TimeInterval { 0 }
    public override var supportsUserPresets: Bool { false }

    public override var shouldBypassEffect: Bool {
        get { kernel.isBypassed }
        set { kernel.isBypassed = newValue }
    }

    public override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              (1...2).contains(format.channelCount) else { return false }
        return super.shouldChange(to: format, for: bus)
    }

    /// Parameter values by identifier, on top of the base class's state.
    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            var values: [String: NSNumber] = [:]
            for parameter in DelayParameter.allCases {
                values[parameter.identifier] = NSNumber(value: kernel.target(parameter))
            }
            state[Self.stateKey] = values
            return state
        }
        set {
            super.fullState = newValue
            guard let values = newValue?[Self.stateKey] as? [String: NSNumber],
                  let tree = parameterTree else { return }
            for parameter in DelayParameter.allCases {
                guard let value = values[parameter.identifier] else { continue }
                tree.parameter(withAddress: AUParameterAddress(parameter.rawValue))?.value = value.floatValue
            }
        }
    }

    // MARK: Editor

    /// MyDelay's own editor (300 x 400 pt).
    public override func requestViewController(completionHandler: @escaping (NSViewController?) -> Void) {
        DispatchQueue.main.async {
            let model = MyFXEditorModel(parameterTree: self.parameterTree, metering: self)
            completionHandler(MyFXEditorViewController(model: model, rootView: DelayEditorView(model: model)))
        }
    }

    public func takeMeterPeaks() -> MyFXPeaks {
        kernel.takeMeterPeaks()
    }

    // MARK: Render resources

    public override func allocateRenderResources() throws {
        let input = inputBusses[0].format
        let output = outputBusses[0].format
        guard input.channelCount == output.channelCount,
              (1...2).contains(output.channelCount),
              input.sampleRate == output.sampleRate else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        let frames = Int(maximumFramesToRender)
        renderer.allocate(frames: frames, channelCount: Int(output.channelCount))
        kernel.prepare(sampleRate: output.sampleRate, maximumFrames: frames)
    }

    public override func reset() {
        super.reset()
        kernel.requestReset()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        renderer.makeRenderBlock(kernel: kernel)
    }

    // MARK: Private

    private static func makeParameterTree(kernel: DelayKernel) -> AUParameterTree {
        let parameters = DelayParameter.allCases.map { parameter -> AUParameter in
            var flags: AudioUnitParameterOptions = [.flag_IsReadable, .flag_IsWritable]
            let unit: AudioUnitParameterUnit
            var valueStrings: [String]?
            switch parameter {
            case .mode:
                unit = .indexed
                valueStrings = DelayMode.allCases.map(\.displayName)
            case .time:
                unit = .seconds
                flags.formUnion([.flag_CanRamp, .flag_DisplayLogarithmic])
            case .feedback, .width, .mix:
                unit = .percent
                flags.insert(.flag_CanRamp)
            }
            let auParameter = AUParameterTree.createParameter(
                withIdentifier: parameter.identifier,
                name: parameter.displayName.capitalized,
                address: AUParameterAddress(parameter.rawValue),
                min: parameter.range.lowerBound,
                max: parameter.range.upperBound,
                unit: unit,
                unitName: nil,
                flags: flags,
                valueStrings: valueStrings,
                dependentParameters: nil
            )
            auParameter.value = parameter.defaultValue
            return auParameter
        }
        let tree = AUParameterTree.createTree(withChildren: parameters)
        tree.implementorValueObserver = { [kernel] parameter, value in
            guard let delayParameter = DelayParameter(rawValue: Int(parameter.address)) else { return }
            kernel.setTarget(delayParameter, value)
        }
        tree.implementorValueProvider = { [kernel] parameter in
            guard let delayParameter = DelayParameter(rawValue: Int(parameter.address)) else { return 0 }
            return kernel.target(delayParameter)
        }
        tree.implementorStringFromValueCallback = { parameter, valuePointer in
            guard let delayParameter = DelayParameter(rawValue: Int(parameter.address)) else { return "" }
            return delayParameter.displayString(for: valuePointer?.pointee ?? parameter.value)
        }
        tree.implementorValueFromStringCallback = { parameter, string in
            guard let delayParameter = DelayParameter(rawValue: Int(parameter.address)) else { return 0 }
            return delayParameter.value(fromDisplayString: string) ?? parameter.value
        }
        return tree
    }
}

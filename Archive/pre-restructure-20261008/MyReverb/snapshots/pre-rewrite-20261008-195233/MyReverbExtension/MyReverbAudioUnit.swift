import AVFoundation
import AudioToolbox

public enum MyReverbParameterAddress {
    public static let hpf: AUParameterAddress = 0
    public static let lpf: AUParameterAddress = 1
    public static let rt: AUParameterAddress = 2
    public static let preDelay: AUParameterAddress = 3
    public static let mix: AUParameterAddress = 4
}

public final class MyReverbAudioUnit: AUAudioUnit, @unchecked Sendable {
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!
    private var parameters: AUParameterTree!
    private var drySignalBuffer: DrySignalBuffer?
    private var preDelayProcessor: PreDelayProcessor?
    private var reverbProcessor: PlateReverbProcessor?
    private var filterBank: ButterworthFilterBank?

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        parameters = Self.makeParameterTree()
        parameterTree = parameters
    }

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    public override var channelCapabilities: [NSNumber] { [2, 2] }

    public override var tailTime: TimeInterval {
        let preDelay = parameters.parameter(withAddress: MyReverbParameterAddress.preDelay)?.value ?? 0
        let reverbTime = parameters.parameter(withAddress: MyReverbParameterAddress.rt)?.value ?? 0
        return TimeInterval(preDelay + reverbTime)
    }

    public override func allocateRenderResources() throws {
        let inputChannelCount = inputBusses[0].format.channelCount
        let outputChannelCount = outputBusses[0].format.channelCount
        guard inputChannelCount == outputChannelCount else {
            throw NSError(domain: NSOSStatusErrorDomain,
                          code: Int(kAudioUnitErr_FailedInitialization),
                          userInfo: nil)
        }

        try super.allocateRenderResources()
        drySignalBuffer = DrySignalBuffer(maximumFrames: Int(maximumFramesToRender),
                           channelCount: Int(outputChannelCount))
        preDelayProcessor = PreDelayProcessor(sampleRate: outputBusses[0].format.sampleRate,
                                               channelCount: Int(outputChannelCount))
        reverbProcessor = PlateReverbProcessor(sampleRate: outputBusses[0].format.sampleRate,
                            channelCount: Int(outputChannelCount))
        filterBank = ButterworthFilterBank(sampleRate: outputBusses[0].format.sampleRate,
                                           channelCount: Int(outputChannelCount))
    }

    public override func deallocateRenderResources() {
        drySignalBuffer = nil
        preDelayProcessor = nil
        reverbProcessor = nil
        filterBank = nil
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        return { [weak self] actionFlags, timestamp, frameCount, outputBusNumber,
                   outputData, realtimeEventListHead, pullInputBlock in
            guard let self,
                  let drySignalBuffer = self.drySignalBuffer,
                  let preDelayProcessor = self.preDelayProcessor,
                  let reverbProcessor = self.reverbProcessor,
                  let filterBank = self.filterBank else {
                return kAudio_ParamError
            }
            if let pullInputBlock {
                let status = pullInputBlock(actionFlags, timestamp, frameCount, 0, outputData)
                if status != noErr {
                    Self.clearAudioBufferList(outputData, frameCount: Int(frameCount))
                }
            } else {
                Self.clearAudioBufferList(outputData, frameCount: Int(frameCount))
            }
            drySignalBuffer.capture(outputData, frameCount: Int(frameCount))
            let delaySeconds = self.parameters.parameter(withAddress: MyReverbParameterAddress.preDelay)?.value ?? 0
            preDelayProcessor.process(outputData,
                                      frameCount: Int(frameCount),
                                      delaySeconds: delaySeconds)
            let reverbTime = self.parameters.parameter(withAddress: MyReverbParameterAddress.rt)?.value ?? 2
            reverbProcessor.process(outputData,
                                    frameCount: Int(frameCount),
                                    reverbTime: reverbTime)
            let hpf = self.parameters.parameter(withAddress: MyReverbParameterAddress.hpf)?.value ?? 0
            let lpf = self.parameters.parameter(withAddress: MyReverbParameterAddress.lpf)?.value ?? 24_000
            filterBank.process(outputData,
                               frameCount: Int(frameCount),
                               hpf: hpf,
                               lpf: lpf)
            let mix = self.parameters.parameter(withAddress: MyReverbParameterAddress.mix)?.value ?? 100
            drySignalBuffer.mixInto(outputData,
                                    frameCount: Int(frameCount),
                                    wetAmount: Double(mix) / 100.0)
            return noErr
        }
    }

    private static func clearAudioBufferList(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                                             frameCount: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for index in 0..<buffers.count {
            guard let data = buffers[index].mData else { continue }
            let sampleCount = Int(buffers[index].mNumberChannels) == 1
                ? frameCount
                : frameCount * Int(buffers[index].mNumberChannels)
            data.assumingMemoryBound(to: Float.self)
                .update(repeating: 0, count: sampleCount)
        }
    }

    private static func makeParameterTree() -> AUParameterTree {
        let hpf = AUParameterTree.createParameter(withIdentifier: "hpf", name: "HPF",
                                                   address: MyReverbParameterAddress.hpf,
                                                   min: 0, max: 1_000, unit: .hertz,
                                                   unitName: nil, flags: [AudioUnitParameterOptions.flag_IsWritable, AudioUnitParameterOptions.flag_IsReadable],
                                                   valueStrings: nil, dependentParameters: nil)
        let lpf = AUParameterTree.createParameter(withIdentifier: "lpf", name: "LPF",
                                                   address: MyReverbParameterAddress.lpf,
                                                   min: 200, max: 24_000, unit: .hertz,
                                                   unitName: nil, flags: [AudioUnitParameterOptions.flag_IsWritable, AudioUnitParameterOptions.flag_IsReadable],
                                                   valueStrings: nil, dependentParameters: nil)
        let rt = AUParameterTree.createParameter(withIdentifier: "rt", name: "RT",
                                                  address: MyReverbParameterAddress.rt,
                                                  min: 0.1, max: 60, unit: .seconds,
                                                  unitName: nil, flags: [AudioUnitParameterOptions.flag_IsWritable, AudioUnitParameterOptions.flag_IsReadable],
                                                  valueStrings: nil, dependentParameters: nil)
        let preDelay = AUParameterTree.createParameter(withIdentifier: "preDelay", name: "PD",
                                                        address: MyReverbParameterAddress.preDelay,
                                                        min: 0, max: 1, unit: .seconds,
                                                        unitName: nil, flags: [AudioUnitParameterOptions.flag_IsWritable, AudioUnitParameterOptions.flag_IsReadable],
                                                        valueStrings: nil, dependentParameters: nil)
        let mix = AUParameterTree.createParameter(withIdentifier: "mix", name: "MIX",
                                                   address: MyReverbParameterAddress.mix,
                                                   min: 0, max: 100, unit: .percent,
                                                   unitName: nil, flags: [AudioUnitParameterOptions.flag_IsWritable, AudioUnitParameterOptions.flag_IsReadable],
                                                   valueStrings: nil, dependentParameters: nil)
        hpf.value = 80
        lpf.value = 8_000
        rt.value = 2
        preDelay.value = 0.020
        mix.value = 100
        let tree = AUParameterTree.createTree(withChildren: [hpf, lpf, rt, preDelay, mix])
        tree.implementorStringFromValueCallback = { parameter, valuePointer in
            guard let value = valuePointer?.pointee else { return "-" }
            switch parameter.address {
            case MyReverbParameterAddress.hpf:
                return value == 0 ? "Thru" : String(format: "%.0f Hz", value)
            case MyReverbParameterAddress.lpf:
                return value >= 24_000 ? "Thru" : String(format: "%.0f Hz", value)
            case MyReverbParameterAddress.rt:
                return String(format: "%.1f s", value)
            case MyReverbParameterAddress.preDelay:
                return String(format: "%.0f ms", value * 1_000)
            case MyReverbParameterAddress.mix:
                return String(format: "%.0f%%", value)
            default:
                return String(format: "%.3f", value)
            }
        }
        return tree
    }
}

private final class DrySignalBuffer {
    private let maximumFrames: Int
    private let channelCount: Int
    private var channels: [[Float]]

    init(maximumFrames: Int, channelCount: Int) {
        self.maximumFrames = max(maximumFrames, 1)
        self.channelCount = channelCount
        channels = (0..<channelCount).map { _ in
            Array(repeating: 0, count: max(maximumFrames, 1))
        }
    }

    func capture(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let count = min(frameCount, maximumFrames)
        guard buffers.count > 0 else { return }
        if buffers.count == channelCount {
            for channel in 0..<channelCount {
                guard let data = buffers[channel].mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<count { channels[channel][frame] = samples[frame] }
            }
        } else {
            guard let data = buffers[0].mData else { return }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<count {
                for channel in 0..<channelCount {
                    channels[channel][frame] = samples[frame * channelCount + channel]
                }
            }
        }
    }

    func mixInto(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                 frameCount: Int,
                 wetAmount: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let count = min(frameCount, maximumFrames)
        let wet = min(max(wetAmount, 0), 1)
        let dry = 1.0 - wet
        guard buffers.count > 0 else { return }
        if buffers.count == channelCount {
            for channel in 0..<channelCount {
                guard let data = buffers[channel].mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<count {
                    samples[frame] = Float(Double(channels[channel][frame]) * dry + Double(samples[frame]) * wet)
                }
            }
        } else {
            guard let data = buffers[0].mData else { return }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<count {
                for channel in 0..<channelCount {
                    let offset = frame * channelCount + channel
                    samples[offset] = Float(Double(channels[channel][frame]) * dry + Double(samples[offset]) * wet)
                }
            }
        }
    }
}

private final class PlateReverbProcessor {
    private let channelCount: Int
    private let sampleRate: Double
    private let delayLines: [ReverbDelayLine]
    private let diffusers: [ReverbAllPass]
    private let dampingCoefficient: Double
    private var feedbackGain = 0.0
    private var currentReverbTime = -1.0
    private var samplePosition = 0

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        let scale = sampleRate / 44_100.0
        let lengths = [1499, 1723, 2111, 2357, 2633, 2971, 3413, 3761]
            .map { max(Int(Double($0) * scale), 2) }
        delayLines = lengths.enumerated().map { index, length in
            ReverbDelayLine(length: length, modulationPhase: Double(index) * 0.73)
        }
        diffusers = [
            ReverbAllPass(length: max(Int(113 * scale), 2), feedback: 0.70),
            ReverbAllPass(length: max(Int(157 * scale), 2), feedback: 0.70),
            ReverbAllPass(length: max(Int(197 * scale), 2), feedback: 0.70),
            ReverbAllPass(length: max(Int(233 * scale), 2), feedback: 0.70)
        ]
        dampingCoefficient = 1.0 - exp(-2.0 * Double.pi * 7_000.0 / sampleRate)
    }

    func process(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                 frameCount: Int,
                 reverbTime: AUValue) {
        let reverbTimeValue = max(Double(reverbTime), 0.1)
        if reverbTimeValue != currentReverbTime {
            currentReverbTime = reverbTimeValue
            let longestDelay = Double(delayLines[delayLines.count - 1].length)
            feedbackGain = pow(10.0, -3.0 * longestDelay / (reverbTimeValue * sampleRate))
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard buffers.count > 0, channelCount >= 2 else { return }
        if buffers.count == channelCount {
            guard let leftData = buffers[0].mData,
                  let rightData = buffers[1].mData else { return }
            let left = leftData.assumingMemoryBound(to: Float.self)
            let right = rightData.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                processFrame(left: &left[frame], right: &right[frame])
            }
        } else {
            guard let data = buffers[0].mData else { return }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                let leftOffset = frame * channelCount
                let rightOffset = leftOffset + 1
                processFrame(left: &samples[leftOffset], right: &samples[rightOffset])
            }
        }
    }

    private func processFrame(left: inout Float, right: inout Float) {
        let inputLeft = Double(left)
        let inputRight = Double(right)
        var firstDiffuse = diffusers[0].process(0.55 * inputLeft + 0.25 * inputRight)
        firstDiffuse = diffusers[1].process(firstDiffuse)
        var secondDiffuse = diffusers[2].process(0.55 * inputRight - 0.25 * inputLeft)
        secondDiffuse = diffusers[3].process(secondDiffuse)

        let d0 = delayLines[0].read(samplePosition: samplePosition, sampleRate: sampleRate)
        let d1 = delayLines[1].read(samplePosition: samplePosition, sampleRate: sampleRate)
        let d2 = delayLines[2].read(samplePosition: samplePosition, sampleRate: sampleRate)
        let d3 = delayLines[3].read(samplePosition: samplePosition, sampleRate: sampleRate)
        let d4 = delayLines[4].read(samplePosition: samplePosition, sampleRate: sampleRate)
        let d5 = delayLines[5].read(samplePosition: samplePosition, sampleRate: sampleRate)
        let d6 = delayLines[6].read(samplePosition: samplePosition, sampleRate: sampleRate)
        let d7 = delayLines[7].read(samplePosition: samplePosition, sampleRate: sampleRate)
        let matrixScale = 0.3535533905932738
        let m0 = matrixScale * (d0 + d1 + d2 + d3 + d4 + d5 + d6 + d7)
        let m1 = matrixScale * (d0 - d1 + d2 - d3 + d4 - d5 + d6 - d7)
        let m2 = matrixScale * (d0 + d1 - d2 - d3 + d4 + d5 - d6 - d7)
        let m3 = matrixScale * (d0 - d1 - d2 + d3 + d4 - d5 - d6 + d7)
        let m4 = matrixScale * (d0 + d1 + d2 + d3 - d4 - d5 - d6 - d7)
        let m5 = matrixScale * (d0 - d1 + d2 - d3 - d4 + d5 - d6 + d7)
        let m6 = matrixScale * (d0 + d1 - d2 - d3 - d4 - d5 + d6 + d7)
        let m7 = matrixScale * (d0 - d1 - d2 + d3 - d4 + d5 + d6 - d7)
        delayLines[0].write(firstDiffuse + feedbackGain * m0, damping: dampingCoefficient)
        delayLines[1].write(secondDiffuse + feedbackGain * m1, damping: dampingCoefficient)
        delayLines[2].write(0.7 * firstDiffuse + 0.3 * secondDiffuse + feedbackGain * m2, damping: dampingCoefficient)
        delayLines[3].write(0.7 * secondDiffuse - 0.3 * firstDiffuse + feedbackGain * m3, damping: dampingCoefficient)
        delayLines[4].write(firstDiffuse - secondDiffuse + feedbackGain * m4, damping: dampingCoefficient)
        delayLines[5].write(secondDiffuse - firstDiffuse + feedbackGain * m5, damping: dampingCoefficient)
        delayLines[6].write(0.5 * firstDiffuse + feedbackGain * m6, damping: dampingCoefficient)
        delayLines[7].write(0.5 * secondDiffuse + feedbackGain * m7, damping: dampingCoefficient)
        left = Float(0.25 * (d0 + d2 + d4 + d6))
        right = Float(0.25 * (d1 + d3 + d5 + d7))
        samplePosition += 1
    }
}

private final class ReverbDelayLine {
    let length: Int
    private var buffer: [Double]
    private var index = 0
    private var dampingState = 0.0
    private let modulationPhase: Double
    private let modulationDepth = 0.75

    init(length: Int, modulationPhase: Double) {
        self.length = length
        self.modulationPhase = modulationPhase
        buffer = Array(repeating: 0, count: length + 2)
    }

    func read(samplePosition: Int, sampleRate: Double) -> Double {
        let phase = 2.0 * Double.pi * 0.17 * Double(samplePosition) / sampleRate + modulationPhase
        let delay = Double(length) + modulationDepth * sin(phase)
        var readPosition = Double(index) - delay
        while readPosition < 0 { readPosition += Double(buffer.count) }
        while readPosition >= Double(buffer.count) { readPosition -= Double(buffer.count) }
        let lowerIndex = Int(readPosition)
        let upperIndex = (lowerIndex + 1) % buffer.count
        let fraction = readPosition - Double(lowerIndex)
        return buffer[lowerIndex] * (1.0 - fraction) + buffer[upperIndex] * fraction
    }

    func write(_ value: Double, damping: Double) {
        dampingState += damping * (value - dampingState)
        buffer[index] = dampingState
        index += 1
        if index == buffer.count { index = 0 }
    }
}

private final class ReverbAllPass {
    private var buffer: [Double]
    private var index = 0
    private let feedback: Double

    init(length: Int, feedback: Double) {
        buffer = Array(repeating: 0, count: length)
        self.feedback = feedback
    }

    func process(_ input: Double) -> Double {
        let delayed = buffer[index]
        let output = -input + delayed
        buffer[index] = input + delayed * feedback
        index += 1
        if index == buffer.count { index = 0 }
        return output
    }
}

private final class ButterworthFilterBank {
    private let sampleRate: Double
    private let channelCount: Int
    private var channels: [FilterChannel]
    private var currentHPF = -1.0
    private var currentLPF = -1.0

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        channels = (0..<channelCount).map { _ in FilterChannel() }
    }

    func process(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                 frameCount: Int,
                 hpf: AUValue,
                 lpf: AUValue) {
        let hpfValue = Double(hpf)
        let lpfValue = Double(lpf)
        if hpfValue != currentHPF || lpfValue != currentLPF {
            currentHPF = hpfValue
            currentLPF = lpfValue
            for channel in channels {
                channel.configure(hpf: hpfValue, lpf: lpfValue, sampleRate: sampleRate)
            }
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard buffers.count > 0 else { return }
        if buffers.count == channelCount {
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    guard let data = buffers[channel].mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    samples[frame] = channels[channel].process(samples[frame])
                }
            }
        } else {
            guard let data = buffers[0].mData else { return }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let offset = frame * channelCount + channel
                    samples[offset] = channels[channel].process(samples[offset])
                }
            }
        }
    }
}

private final class FilterChannel {
    private var highPassFirst = Biquad()
    private var highPassSecond = Biquad()
    private var lowPassFirst = Biquad()
    private var lowPassSecond = Biquad()
    private var highPassEnabled = false
    private var lowPassEnabled = false

    func configure(hpf: Double, lpf: Double, sampleRate: Double) {
        let nyquist = sampleRate * 0.5
        highPassEnabled = hpf > 0 && hpf < nyquist
        lowPassEnabled = lpf > 0 && lpf < nyquist

        if highPassEnabled {
            highPassFirst.configureFirstOrderHighPass(cutoff: hpf, sampleRate: sampleRate)
            highPassSecond.configureSecondOrderHighPass(cutoff: hpf, q: 1.0, sampleRate: sampleRate)
        } else {
            highPassFirst.reset()
            highPassSecond.reset()
        }

        if lowPassEnabled {
            lowPassFirst.configureFirstOrderLowPass(cutoff: lpf, sampleRate: sampleRate)
            lowPassSecond.configureSecondOrderLowPass(cutoff: lpf, q: 1.0, sampleRate: sampleRate)
        } else {
            lowPassFirst.reset()
            lowPassSecond.reset()
        }
    }

    func process(_ sample: Float) -> Float {
        var value = sample
        if highPassEnabled {
            value = highPassFirst.process(value)
            value = highPassSecond.process(value)
        }
        if lowPassEnabled {
            value = lowPassFirst.process(value)
            value = lowPassSecond.process(value)
        }
        return value
    }
}

private struct Biquad {
    private var b0 = 1.0
    private var b1 = 0.0
    private var b2 = 0.0
    private var a1 = 0.0
    private var a2 = 0.0
    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    mutating func configureFirstOrderLowPass(cutoff: Double, sampleRate: Double) {
        let k = tan(Double.pi * cutoff / sampleRate)
        let normalizer = 1.0 / (1.0 + k)
        b0 = k * normalizer
        b1 = b0
        b2 = 0
        a1 = (k - 1.0) * normalizer
        a2 = 0
        resetState()
    }

    mutating func configureFirstOrderHighPass(cutoff: Double, sampleRate: Double) {
        let k = tan(Double.pi * cutoff / sampleRate)
        let normalizer = 1.0 / (1.0 + k)
        b0 = normalizer
        b1 = -normalizer
        b2 = 0
        a1 = (k - 1.0) * normalizer
        a2 = 0
        resetState()
    }

    mutating func configureSecondOrderLowPass(cutoff: Double, q: Double, sampleRate: Double) {
        let k = tan(Double.pi * cutoff / sampleRate)
        let denominator = 1.0 + k / q + k * k
        b0 = k * k / denominator
        b1 = 2.0 * b0
        b2 = b0
        a1 = 2.0 * (k * k - 1.0) / denominator
        a2 = (1.0 - k / q + k * k) / denominator
        resetState()
    }

    mutating func configureSecondOrderHighPass(cutoff: Double, q: Double, sampleRate: Double) {
        let k = tan(Double.pi * cutoff / sampleRate)
        let denominator = 1.0 + k / q + k * k
        b0 = 1.0 / denominator
        b1 = -2.0 * b0
        b2 = b0
        a1 = 2.0 * (k * k - 1.0) / denominator
        a2 = (1.0 - k / q + k * k) / denominator
        resetState()
    }

    mutating func process(_ input: Float) -> Float {
        let input = Double(input)
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return Float(output)
    }

    mutating func reset() {
        b0 = 1
        b1 = 0
        b2 = 0
        a1 = 0
        a2 = 0
        resetState()
    }

    private mutating func resetState() {
        x1 = 0
        x2 = 0
        y1 = 0
        y2 = 0
    }
}

private final class PreDelayProcessor {
    private let sampleRate: Double
    private let channelCount: Int
    private let capacity: Int
    private var buffers: [UnsafeMutablePointer<Float>]
    private var writeIndex = 0

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        capacity = max(Int(sampleRate.rounded()) + 1, 2)
        buffers = []
        for _ in 0..<channelCount {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            buffer.initialize(repeating: 0, count: capacity)
            buffers.append(buffer)
        }
    }

    deinit {
        for buffer in buffers {
            buffer.deinitialize(count: capacity)
            buffer.deallocate()
        }
    }

    func process(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                 frameCount: Int,
                 delaySeconds: AUValue) {
        let delaySamples = min(max(Int((Double(delaySeconds) * sampleRate).rounded()), 0), capacity - 1)
        let buffersPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard buffersPointer.count > 0 else { return }
        guard delaySamples > 0 else { return }

        if buffersPointer.count == channelCount {
            for frame in 0..<frameCount {
                let readIndex = (writeIndex - delaySamples + capacity) % capacity
                for channel in 0..<channelCount {
                    guard let data = buffersPointer[channel].mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let inputSample = samples[frame]
                    samples[frame] = buffers[channel][readIndex]
                    buffers[channel][writeIndex] = inputSample
                }
                writeIndex = (writeIndex + 1) % capacity
            }
        } else {
            guard let data = buffersPointer[0].mData else { return }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                let readIndex = (writeIndex - delaySamples + capacity) % capacity
                for channel in 0..<channelCount {
                    let offset = frame * channelCount + channel
                    let inputSample = samples[offset]
                    samples[offset] = buffers[channel][readIndex]
                    buffers[channel][writeIndex] = inputSample
                }
                writeIndex = (writeIndex + 1) % capacity
            }
        }
    }
}
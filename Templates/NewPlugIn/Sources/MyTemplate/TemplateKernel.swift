import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyTemplate's signal path, independent of Audio Unit APIs. Replace the
/// per-sample part of `process` with the effect.
///
/// Threading: `prepare` while not rendering, `process` on the render
/// thread; targets and flags are single 32-bit words written from any thread.
public final class TemplateKernel: MyFXKernel {
    private static let smoothingSeconds = 0.02

    private let targets = UnsafeMutablePointer<Float>.allocate(capacity: TemplateParameter.allCases.count)
    private let resetRequests = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let bypassFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let meterPeaks = MyFXMeterPeaks()
    private var handledResets: Int32 = 0
    private var isPrepared = false
    private var sampleRate = 48_000.0

    // Smoothed values (render thread only).
    private var gain: Float = 1
    private var mix: Float = 1
    private var smoothing: Float = 0

    public init() {
        for parameter in TemplateParameter.allCases {
            (targets + parameter.rawValue).initialize(to: parameter.defaultValue)
        }
        resetRequests.initialize(to: 0)
        bypassFlag.initialize(to: 0)
    }

    deinit {
        targets.deallocate()
        resetRequests.deallocate()
        bypassFlag.deallocate()
    }

    // MARK: Control (any thread)

    public func setTarget(_ parameter: TemplateParameter, _ value: Float) {
        targets[parameter.rawValue] = parameter.clamped(value)
    }

    public func target(_ parameter: TemplateParameter) -> Float {
        targets[parameter.rawValue]
    }

    public func applyParameter(_ address: AUParameterAddress, _ value: AUValue) {
        guard let parameter = TemplateParameter(rawValue: Int(address)) else { return }
        setTarget(parameter, value)
    }

    public func targetValue(_ address: AUParameterAddress) -> AUValue {
        TemplateParameter(rawValue: Int(address)).map(target) ?? 0
    }

    public func requestReset() {
        resetRequests.pointee &+= 1
    }

    public var isBypassed: Bool {
        get { bypassFlag.pointee != 0 }
        set { bypassFlag.pointee = newValue ? 1 : 0 }
    }

    public var tailTime: Double { 0 }

    public func takeMeterPeaks() -> MyFXPeaks {
        meterPeaks.take()
    }

    // MARK: Setup (not while rendering)

    public func prepare(sampleRate: Double, maximumFrames: Int) {
        self.sampleRate = sampleRate
        smoothing = Float(1 - exp(-1 / (Self.smoothingSeconds * sampleRate)))
        isPrepared = true
        reset()
    }

    /// Clears audio state and jumps every smoothed value to its target.
    public func reset() {
        gain = Self.linear(decibels: target(.gain))
        mix = target(.mix) / 100
        handledResets = resetRequests.pointee
    }

    // MARK: Render

    public func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>?,
        frameCount: Int
    ) {
        guard isPrepared, frameCount > 0 else { return }
        if resetRequests.pointee != handledResets {
            reset()
        }
        // Before processing: output may be the same memory as input.
        meterPeaks.recordInput(inputLeft, inputRight, frameCount)
        if isBypassed {
            if UnsafePointer(outputLeft) != inputLeft { outputLeft.update(from: inputLeft, count: frameCount) }
            if let outputRight, UnsafePointer(outputRight) != inputRight {
                outputRight.update(from: inputRight, count: frameCount)
            }
            meterPeaks.recordOutput(outputLeft, outputRight ?? outputLeft, frameCount)
            return
        }

        var gain = self.gain
        var mix = self.mix
        let gainTarget = Self.linear(decibels: target(.gain))
        let mixTarget = target(.mix) / 100
        let smoothing = self.smoothing
        for frame in 0..<frameCount {
            gain += (gainTarget - gain) * smoothing
            mix += (mixTarget - mix) * smoothing
            let dryLeft = inputLeft[frame]
            let dryRight = inputRight[frame]
            // The effect: here just a gain.
            let wetLeft = dryLeft * gain
            let wetRight = dryRight * gain
            if let outputRight {
                outputLeft[frame] = dryLeft + mix * (wetLeft - dryLeft)
                outputRight[frame] = dryRight + mix * (wetRight - dryRight)
            } else {
                outputLeft[frame] = dryLeft + mix * (0.5 * (wetLeft + wetRight) - dryLeft)
            }
        }
        self.gain = gain
        self.mix = mix
        meterPeaks.recordOutput(outputLeft, outputRight ?? outputLeft, frameCount)
    }

    private static func linear(decibels: Float) -> Float {
        pow(10, decibels / 20)
    }
}

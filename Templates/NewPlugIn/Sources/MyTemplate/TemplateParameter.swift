import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyTemplate's controls. The raw value is the AU parameter address, so it
/// must never change once projects have been saved.
public enum TemplateParameter: Int, CaseIterable, Sendable, MyFXParameter {
    case gain = 0
    case mix = 1

    public var identifier: String {
        switch self {
        case .gain: return "gain"
        case .mix: return "mix"
        }
    }

    public var displayName: String {
        switch self {
        case .gain: return "GAIN"
        case .mix: return "MIX"
        }
    }

    public var range: ClosedRange<Float> {
        switch self {
        case .gain: return -24...24
        case .mix: return 0...100
        }
    }

    public var defaultValue: Float {
        switch self {
        case .gain: return 0
        case .mix: return 100
        }
    }

    public var unit: AudioUnitParameterUnit {
        switch self {
        case .gain: return .decibels
        case .mix: return .percent
        }
    }

    public func displayString(for value: Float) -> String {
        switch self {
        case .gain: return String(format: "%+.1f dB", value)
        case .mix: return String(format: "%.0f%%", value)
        }
    }

    public func value(fromDisplayString string: String) -> Float? {
        let number = string.trimmingCharacters(in: .whitespaces).prefix { "0123456789.-+".contains($0) }
        return Float(number).map(clamped)
    }
}

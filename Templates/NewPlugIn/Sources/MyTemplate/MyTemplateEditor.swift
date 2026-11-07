import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// Fader travel (0 = bottom, 1 = top) for each parameter; linear here.
enum TemplateFaderTaper {
    static func fraction(for parameter: TemplateParameter, value: Float) -> Double {
        Double((parameter.clamped(value) - parameter.range.lowerBound)
            / (parameter.range.upperBound - parameter.range.lowerBound))
    }

    static func value(for parameter: TemplateParameter, fraction: Double) -> Float {
        let fraction = Float(min(max(fraction, 0), 1))
        return parameter.clamped(parameter.range.lowerBound
            + fraction * (parameter.range.upperBound - parameter.range.lowerBound))
    }
}

struct TemplateEditorView: View {
    @ObservedObject var model: MyFXEditorModel

    var body: some View {
        MyFXEditorView(model: model, title: "MyTemplate") {
            MyFXSubtitle("TEMPLATE")
        } faders: {
            ForEach(TemplateParameter.allCases, id: \.self) { parameter in
                MyFXFaderColumn(
                    parameter: parameter,
                    model: model,
                    fraction: { TemplateFaderTaper.fraction(for: parameter, value: $0) },
                    value: { TemplateFaderTaper.value(for: parameter, fraction: $0) }
                )
            }
        }
    }
}

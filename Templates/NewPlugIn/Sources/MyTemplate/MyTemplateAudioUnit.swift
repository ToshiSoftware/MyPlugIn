import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyTemplate. Everything Audio Unit-related comes from MyFXAudioUnit.
public final class MyTemplateAudioUnit: MyFXAudioUnit, @unchecked Sendable {
    /// 'aufx' 'Tmpl' 'Toka' (app extension, tests). Inside MyDAW it is
    /// registered under MyDAW's vendor by MyPlugInCatalog.
    public override class var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: MyFXFourCC("Tmpl"),
            componentManufacturer: MyFXFourCC("Toka"),
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    public override class var displayName: String { "MyTemplate" }

    public required init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(
            componentDescription: componentDescription,
            options: options,
            configuration: Configuration(kernel: TemplateKernel(), parameters: TemplateParameter.self,
                                         stateKey: "MyTemplateParameters")
        )
    }

    public override func makeEditorView(model: MyFXEditorModel) -> AnyView {
        AnyView(TemplateEditorView(model: model))
    }
}

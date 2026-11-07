import AppKit
import AudioToolbox
import CoreAudioKit

/// Principal class of an instrument's AUv3 app extension, like
/// MyFXExtensionViewController for effects. An extension subclasses it and
/// overrides `makeAudioUnit`.
open class MyFXInstrumentExtensionViewController: AUViewController, AUAudioUnitFactory {
    private var audioUnit: MyFXInstrumentAudioUnit?
    private var editor: MyFXEditorViewController?

    open func makeAudioUnit(componentDescription: AudioComponentDescription) throws -> MyFXInstrumentAudioUnit {
        fatalError("\(type(of: self)) must override makeAudioUnit")
    }

    /// The editor's size. A host reads it when the view connects, before the
    /// unit and its editor exist here, and later changes do not reach it.
    open var editorSize: NSSize { MyFXEditorViewController.preferredSize }

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try makeAudioUnit(componentDescription: componentDescription)
        audioUnit = unit
        DispatchQueue.main.async { self.installEditor() }
        return unit
    }

    open override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: editorSize))
        preferredContentSize = editorSize
    }

    open override func viewDidLoad() {
        super.viewDidLoad()
        installEditor()
    }

    /// Once both the view and the unit exist (in either order).
    private func installEditor() {
        guard isViewLoaded, editor == nil, let audioUnit else { return }
        let editor = audioUnit.makeEditorViewController()
        addChild(editor)
        editor.view.frame = view.bounds
        editor.view.autoresizingMask = [.width, .height]
        view.addSubview(editor.view)
        self.editor = editor
        preferredContentSize = editor.size
    }
}

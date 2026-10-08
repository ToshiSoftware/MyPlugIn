import AudioToolbox
import Foundation

public final class AudioUnitFactory: NSObject, AUAudioUnitFactory {
    public func beginRequest(with context: NSExtensionContext) {
    }

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        try MyReverbAudioUnit(componentDescription: componentDescription)
    }
}
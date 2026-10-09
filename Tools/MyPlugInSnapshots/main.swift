import AppKit
import AudioToolbox
import MyPlugInCatalog
import MyPlugInCore
import SwiftUI
#if canImport(MyMaximizer)
import MyMaximizer

/// Six seconds of drum-like bursts with quiet passages, so the graph shows
/// level, limiting and upward boost.
func fillHistory(_ kernel: MaximizerKernel, drive: Float?) {
    let rate = 48_000.0
    let inputGain = kernel.target(.inputGain)
    if let drive { kernel.setTarget(.inputGain, drive) }
    kernel.prepare(sampleRate: rate, maximumFrames: 512)
    let frames = Int(6 * rate)
    var signal = [Float](repeating: 0, count: frames)
    for frame in 0..<frames {
        let time = Double(frame) / rate
        let beat = time.truncatingRemainder(dividingBy: 0.5)
        let quiet = (2.5..<3.5).contains(time) ? 0.08 : 1.0
        let hit = exp(-beat * 18) * sin(2 * .pi * 70 * beat)
        let pad = 0.18 * sin(2 * .pi * 220 * time) * (0.6 + 0.4 * sin(2 * .pi * 0.7 * time))
        signal[frame] = Float(quiet * (0.55 * hit + pad))
    }
    var output = signal
    signal.withUnsafeBufferPointer { input in
        output.withUnsafeMutableBufferPointer { out in
            for start in stride(from: 0, to: frames, by: 512) {
                let count = min(512, frames - start)
                kernel.process(inputLeft: input.baseAddress! + start, inputRight: input.baseAddress! + start,
                               outputLeft: out.baseAddress! + start, outputRight: nil, frameCount: count)
            }
        }
    }
    kernel.setTarget(.inputGain, inputGain)
}
#endif

// Writes each effect's editor to <output folder>/<Name>.png, with sample
// meter levels, to check the look without a host:
//   swift run MyPlugInSnapshots <output folder>
// With --manual: the pictures for MyDAW's operation manual, named
// plugin-<name>.png, with channel names, typical settings and no CLIP.

let arguments = CommandLine.arguments.dropFirst()
let forManual = arguments.contains("--manual")
let outputFolder = URL(fileURLWithPath: arguments.first { !$0.hasPrefix("--") } ?? ".")

/// --manual: the channel each effect is shown on, and settings by identifier.
let manualSetups: [String: (channel: String, values: [String: Float])] = [
    "MyReverb": ("FX 1", ["rt": 2.2, "preDelay": 0.025]),
    "MyDelay": ("FX 2", ["time": 0.375, "feedback": 35]),
    "MyChannelStrip": ("Vocal", [
        "band1_type": 0, "band1_freq": 90,
        "band2_gain": -3, "band2_freq": 320, "band2_q": 1.4,
        "band3_gain": 2.5, "band3_freq": 3_200,
        "band4_gain": 2,
        "comp_on": 1, "comp_threshold": -20, "comp_ratio": 3
    ]),
    "MyMaximizer": ("MASTER", ["input_gain": 6, "threshold": -3])
]
try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

for plugIn in MyPlugInCatalog.plugIns {
    let unit = try plugIn.init(componentDescription: plugIn.componentDescription, options: [])
    let setup = forManual ? manualSetups[plugIn.displayName] : nil
    if let setup {
        unit.contextName = setup.channel
        for parameter in unit.parameterTree?.allParameters ?? [] {
            if let value = setup.values[parameter.identifier] { parameter.value = value }
        }
    }
    #if canImport(MyMaximizer)
    if let maximizer = unit as? MyMaximizerAudioUnit {
        fillHistory(maximizer.maximizerKernel, drive: forManual ? nil : 8)
    }
    #endif
    let controller = unit.makeEditorViewController()
    if forManual {
        let isMaximizer = plugIn.displayName == "MyMaximizer"
        controller.model.input = MyFXMeterState(left: 0.42, right: 0.38, holdLeft: 0.6, holdRight: 0.55, maximum: 0.63)
        controller.model.output = isMaximizer
            ? MyFXMeterState(left: 0.9, right: 0.86, holdLeft: 0.98, holdRight: 0.97, maximum: 0.988)
            : MyFXMeterState(left: 0.3, right: 0.33, holdLeft: 0.42, holdRight: 0.45, maximum: 0.5)
    } else {
        controller.model.input = MyFXMeterState(left: 0.5, right: 0.42, holdLeft: 0.7, holdRight: 0.6, maximum: 1.05,
                                                clipped: true)
        controller.model.output = MyFXMeterState(left: 0.25, right: 0.3, holdLeft: 0.35, holdRight: 0.4, maximum: 0.45)
    }
    let window = NSWindow(contentViewController: controller)
    window.setContentSize(controller.size)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let view = controller.view
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let name = forManual ? "plugin-\(plugIn.displayName.lowercased()).png" : "\(plugIn.displayName).png"
    let file = outputFolder.appendingPathComponent(name)
    try bitmap.representation(using: .png, properties: [:])?.write(to: file)
    print("Wrote \(file.path)")
}

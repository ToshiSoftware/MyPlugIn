import AppKit
import AudioToolbox
import MyPlugInCatalog
import MyPlugInCore
import SwiftUI

// Writes each effect's editor to <output folder>/<Name>.png, with sample
// meter levels, to check the look without a host:
//   swift run MyPlugInSnapshots <output folder>

let outputFolder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

for plugIn in MyPlugInCatalog.plugIns {
    let unit = try plugIn.init(componentDescription: plugIn.componentDescription, options: [])
    let controller = unit.makeEditorViewController()
    controller.model.input = MyFXMeterState(left: 0.5, right: 0.42, holdLeft: 0.7, holdRight: 0.6, maximum: 0.71)
    controller.model.output = MyFXMeterState(left: 0.25, right: 0.3, holdLeft: 0.35, holdRight: 0.4, maximum: 0.45)
    let window = NSWindow(contentViewController: controller)
    window.setContentSize(MyFXEditorViewController.preferredSize)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let view = controller.view
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let file = outputFolder.appendingPathComponent("\(plugIn.displayName).png")
    try bitmap.representation(using: .png, properties: [:])?.write(to: file)
    print("Wrote \(file.path)")
}

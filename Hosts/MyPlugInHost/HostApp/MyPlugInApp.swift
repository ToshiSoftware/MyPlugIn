import MyPlugInCatalog
import MyPlugInCore
import SwiftUI

/// Container of the MyPlugIn AUv3 extensions. Launching it once registers
/// them with macOS, so Logic and other hosts list them under "Toka".
@main
struct MyPlugInApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("MyPlugIn")
                    .font(.title2.bold())
                Text("These Audio Unit effects are now available to other hosts (manufacturer \"Toka\"):")
                    .foregroundStyle(.secondary)
                ForEach(MyPlugInCatalog.plugIns.map(\.displayName), id: \.self) { name in
                    Label(name, systemImage: "waveform")
                }
                Text("This app can be closed. Remove it from Applications to uninstall the effects.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(minWidth: 360)
        }
        .windowResizability(.contentSize)
    }
}

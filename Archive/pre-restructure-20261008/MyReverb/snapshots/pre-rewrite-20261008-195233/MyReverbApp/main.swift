import SwiftUI

@main
struct MyReverbApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("MyReverb")
                .font(.title)
            Text("AUv3 extension host")
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}
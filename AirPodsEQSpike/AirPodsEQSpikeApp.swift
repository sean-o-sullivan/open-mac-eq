import AppKit
import SwiftUI

@main
struct OpenEqApp: App {
    @StateObject private var model = SpikeViewModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("openEq", systemImage: model.isRunning ? "waveform.circle.fill" : "waveform.circle") {
            OpenEqMenu(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct OpenEqMenu: View {
    @ObservedObject var model: SpikeViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isRunning ? "EQ active" : "EQ stopped")
        if let profile = model.activeProfile {
            Text(profile.name)
        }
        Divider()
        if model.isRunning {
            Button("Close EQ") { model.stopButtonPressed() }
        } else {
            Button("Open EQ") { model.start() }
                .disabled(!model.canStart)
        }
        Button("Show Editor") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit openEq") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

import AppKit
import SwiftUI

@main
struct LAtelierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        WindowGroup("L’Atelier") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appSettings) {
                Button("Réglages…") { model.selection = .reglages }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Utile quand l'exécutable est lancé hors du paquet .app (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

import AppKit
import SwiftUI

@main
struct LAtelierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        WindowGroup("L’Atelier", id: "main") {
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

        MenuBarExtra(isInserted: Binding(get: { model.preferences.menuBarIcon }, set: { model.preferences.menuBarIcon = $0 })) {
            MenuBarContent().environment(model)
        } label: {
            Image(systemName: "wrench.adjustable")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Utile quand l'exécutable est lancé hors du paquet .app (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Avec l'icône de la barre des menus, fermer la fenêtre laisse L’Atelier tourner (alertes, vérifications).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "menuBarIcon") as? Bool ?? true)
    }
}

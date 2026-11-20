import AppKit
import SwiftUI
import LAtelierCore

@main
struct LAtelierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var model: AppModel

    init() {
        // Reprend réglages, historique et caches de l'ancien identifiant (local.latelier), avant tout le reste.
        LegacyMigration.run()
        _model = ViewState(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("L’Atelier", id: "main") {
            // Captures : LATELIER_MENU_PREVIEW=1 montre le menu de la barre des menus dans la fenêtre.
            if ProcessInfo.processInfo.environment["LATELIER_MENU_PREVIEW"] == "1" {
                MenuBarContent().environment(model)
            } else {
                RootView()
                    .environment(model)
                    .frame(minWidth: 960, minHeight: 620)
            }
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appSettings) {
                Button("Réglages…") { model.selection = .reglages }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Signaler un problème…") { model.reportIssue(.bug) }
                Button("Proposer une idée…") { model.reportIssue(.idea) }
                Divider()
                Button("Nouveautés de L’Atelier") {
                    if let url = URL(string: "https://github.com/\(model.repository)/releases") { NSWorkspace.shared.open(url) }
                }
                Button("Revoir l’accueil…") { model.showOnboarding = true }
            }
        }

        MenuBarExtra(isInserted: Binding(get: { model.preferences.menuBarIcon }, set: { model.preferences.menuBarIcon = $0 })) {
            MenuBarContent().environment(model)
        } label: {
            MenuBarLabel(model: model, delegate: appDelegate)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Icône de la barre des menus. Toujours en vie : elle donne au clic droit de quoi rouvrir la fenêtre.
private struct MenuBarLabel: View {
    let model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "wrench.adjustable")
            .onAppear {
                delegate.show = { [model] page in
                    model.selection = page
                    if page == .depots { model.openRepo = nil }
                    NSApp.activate()
                    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "main")
                    }
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Ouvre la fenêtre principale sur une page (fourni par l'icône de la barre des menus).
    var show: ((Page) -> Void)?
    private var rightClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Utile quand l'exécutable est lancé hors du paquet .app (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        installStatusItemMenu()
    }

    /// Clic droit (ou ctrl-clic) sur l'icône de la barre des menus : petit menu avec Quitter.
    private func installStatusItemMenu() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, let window = event.window,
                  String(describing: type(of: window)).contains("StatusBarWindow"),
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let view = window.contentView else { return event }
            NSMenu.popUpContextMenu(self.statusMenu(), with: event, for: view)
            return nil
        }
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Ouvrir L’Atelier", #selector(openMain)))
        menu.addItem(item("Moniteur", #selector(openMonitor)))
        menu.addItem(item("Réglages…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quitter L’Atelier", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openMain() { show?(.accueil) }
    @objc private func openMonitor() { show?(.moniteur) }
    @objc private func openSettings() { show?(.reglages) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Avec l'icône de la barre des menus, fermer la fenêtre laisse L’Atelier tourner (alertes, vérifications).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "menuBarIcon") as? Bool ?? true)
    }
}

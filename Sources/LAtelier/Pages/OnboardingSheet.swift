import AppKit
import LAtelierCore
import ServiceManagement
import SwiftUI

/// Premier lancement : ce que fait L’Atelier, ses promesses, puis les quelques réglages qui comptent.
struct OnboardingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var step = Step.welcome
    @ViewState private var fullDiskAccess = FullDiskAccess.granted
    @ViewState private var analyse = true

    enum Step: Int, CaseIterable {
        case welcome, promises, disk, projects, tools, ready
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .promises: promises
                case .disk: disk
                case .projects: projects
                case .tools: tools
                case .ready: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 36).padding(.top, 32)
            footer
        }
        .frame(width: 640, height: 560)
        .background { Backdrop(glass: model.preferences.glass) }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if step == .disk { fullDiskAccess = FullDiskAccess.granted }
        }
    }

    // MARK: Étapes

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Bienvenue dans L’Atelier").font(.system(size: 30, weight: .bold))
            Text(String(localized: "La boîte à outils des développeurs sur Mac : une machine propre, à jour et sûre."))
                .font(.system(size: 16)).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 10) {
                feature("internaldrive", String(localized: "Stockage"), String(localized: "Ce qui occupe le disque, et ce qu’on peut libérer sans risque."))
                feature("folder.badge.gearshape", String(localized: "Projets"), String(localized: "Vos dépôts git, leurs dépendances, leurs failles et leurs tests."))
                feature("externaldrive.connected.to.line.below", String(localized: "Serveurs"), String(localized: "Vos connexions SSH, leurs fichiers et leurs performances."))
                feature("cube.box", String(localized: "Paquets"), String(localized: "Tout ce qui est installé, et ce qui est à mettre à jour."))
                feature("gauge.with.dots.needle.67percent", "Performance", String(localized: "Processeur, mémoire, réseau et processus en direct."))
            }
            .padding(.top, 6)
        }
    }

    private var promises: some View {
        VStack(alignment: .leading, spacing: 16) {
            title(String(localized: "Rien ne se fait sans vous"), String(localized: "Quatre règles valent pour chaque écran de L’Atelier."))
            promise("eye", String(localized: "Un aperçu avant toute action"), String(localized: "Avant de supprimer, mettre à jour ou lancer une commande qui modifie quelque chose, vous voyez quoi, combien et avec quel risque."))
            promise("trash", String(localized: "La corbeille par défaut"), String(localized: "Ce qui est supprimé va à la corbeille (sur un serveur : ~/.latelier-corbeille). Le définitif reste une option."))
            promise("clock.arrow.circlepath", String(localized: "Tout est noté"), String(localized: "L’Historique garde chaque action, avec la sortie des commandes et l’explication des échecs."))
            promise("hand.raised", String(localized: "Aucune télémétrie"), String(localized: "L’Atelier n’envoie ni statistiques ni code. Il ne contacte que les registres de paquets, les bases de failles, les sources de news, GitHub pour ses mises à jour et vos serveurs quand vous les ouvrez."))
        }
    }

    private var disk: some View {
        VStack(alignment: .leading, spacing: 16) {
            title(String(localized: "Accès complet au disque"), String(localized: "Facultatif, mais recommandé."))
            Text(String(localized: "Sans cet accès, macOS cache à L’Atelier la corbeille et les données de certaines apps : leur taille ne peut pas être mesurée. Rien n’est jamais lu au-delà de ce qui sert à mesurer et à nettoyer."))
                .font(.system(size: 14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Image(systemName: fullDiskAccess ? "checkmark.circle.fill" : "lock.circle")
                    .font(.system(size: 28)).foregroundStyle(fullDiskAccess ? Theme.green : Theme.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fullDiskAccess ? String(localized: "Accès accordé") : String(localized: "Accès non accordé")).font(.system(size: 15, weight: .semibold))
                    Text(fullDiskAccess ? String(localized: "Tout le disque peut être mesuré.") : String(localized: "Ouvrez les Réglages Système, activez L’Atelier, puis revenez ici."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if !fullDiskAccess {
                    Button(String(localized: "Ouvrir les Réglages Système")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .buttonStyle(PillButtonStyle(kind: .smallFilled))
                }
            }
            .padding(16)
            .cardBackground(radius: 16)
            Text("Vous pourrez le faire plus tard depuis Réglages › Général.").font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 16) {
            title(String(localized: "Où sont vos projets ?"), String(localized: "L’Atelier y cherche vos dépôts git, leurs dépendances et leurs artefacts de build."))
            if model.projectRoots.isEmpty {
                Text("Aucun dossier pour l’instant.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            FolderList(folders: model.projectRoots.map { $0.abbreviatingHome() },
                       remove: { path in
                           if let url = model.projectRoots.first(where: { $0.abbreviatingHome() == path }) { model.removeProjectRoot(url) }
                       },
                       add: { model.addProjectRoot($0) })
            Text(String(localized: "Seuls ces dossiers sont parcourus. Vous pourrez les changer dans Réglages › Projets."))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    private var tools: some View {
        @Bindable var preferences = model.preferences
        return VStack(alignment: .leading, spacing: 16) {
            title(String(localized: "Vos outils"), String(localized: "Pour ouvrir un projet ou un serveur en un clic."))
            row("Langue") {
                HStack(spacing: 8) {
                    if preferences.language != preferences.launchLanguage {
                        Button(String(localized: "Redémarrer")) {
                            UserDefaults.standard.set(true, forKey: "onboardingDone")
                            model.relaunch()
                        }
                        .buttonStyle(PillButtonStyle(kind: .smallFilled))
                    }
                    Picker("Langue", selection: $preferences.language) {
                        Text(String(localized: "Système")).tag("system")
                        Text(verbatim: "Français").tag("fr")
                        Text(verbatim: "English").tag("en")
                    }
                    .labelsHidden().fixedSize()
                }
            }
            row("Terminal") {
                Picker("Terminal", selection: $preferences.terminal) {
                    ForEach(TerminalApp.installed, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            row(String(localized: "Éditeur")) {
                Picker(String(localized: "Éditeur"), selection: $preferences.editor) {
                    Text("Éditeur par défaut").tag(EditorApp?.none)
                    ForEach(EditorApp.installed, id: \.self) { Text($0.label).tag(EditorApp?.some($0)) }
                }
                .labelsHidden().fixedSize()
            }
            row(String(localized: "Icône dans la barre des menus")) {
                Toggle("", isOn: $preferences.menuBarIcon).toggleStyle(.switch).labelsHidden()
            }
            row(String(localized: "Rechercher les mises à jour de L’Atelier")) {
                Toggle("", isOn: $preferences.checkAppUpdates).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            title(String(localized: "C’est prêt"), String(localized: "L’Atelier peut faire un premier tour de la machine. Rien n’est supprimé pendant l’analyse."))
            Toggle(isOn: $analyse) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lancer une première analyse").font(.system(size: 14, weight: .semibold))
                    Text(String(localized: "Stockage, dépôts, paquets et failles connues : une à deux minutes, en arrière-plan."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            .toggleStyle(.checkbox)
            Text("Un souci, une idée ? Réglages › À propos › Signaler un problème.").font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Pied

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Circle().fill(item == step ? Theme.accent : Theme.muted.opacity(0.35)).frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome {
                Button(String(localized: "Retour")) { move(-1) }.buttonStyle(.small)
            } else {
                Button(String(localized: "Passer")) { finish(analyse: false) }.buttonStyle(.small)
            }
            if step == .ready {
                Button(String(localized: "Commencer")) { finish(analyse: analyse) }
                    .buttonStyle(PillButtonStyle(kind: .smallFilled)).keyboardShortcut(.defaultAction)
            } else {
                Button(String(localized: "Continuer")) { move(1) }
                    .buttonStyle(PillButtonStyle(kind: .smallFilled)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .background(Theme.headerFill)
    }

    private func move(_ delta: Int) {
        withAnimation(.snappy(duration: 0.2)) {
            step = Step(rawValue: step.rawValue + delta) ?? step
        }
    }

    private func finish(analyse: Bool) {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        dismiss()
        if analyse { model.scanEverything() }
    }

    // MARK: Éléments

    private func title(_ text: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 26, weight: .bold))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.muted)
        }
        .padding(.bottom, 4)
    }

    private func feature(_ symbol: String, _ name: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconChip(symbol: symbol, color: Theme.accent, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 14, weight: .semibold))
                Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func promise(_ symbol: String, _ name: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14, weight: .semibold))
                Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label).font(.system(size: 14, weight: .medium))
            Spacer()
            control()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .cardBackground(radius: 14)
    }
}

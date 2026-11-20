import AppKit
import LAtelierCore
import ServiceManagement
import SwiftUI

/// Réglages : six sections comme la maquette. Chaque réglage agit réellement sur l'app.
struct SettingsPage: View {
    enum Section: String, CaseIterable {
        case general, stockage, projets, verifs, notifs, privacy

        var label: String {
            switch self {
            case .general: "Général"
            case .stockage: "Stockage"
            case .projets: "Projets"
            case .verifs: "Vérifications"
            case .notifs: "Notifications"
            case .privacy: "Confidentialité"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @ViewState private var section = Section.general

    var body: some View {
        PageScaffold(page: .reglages, subtitle: "L’Atelier · version \(Self.version)") {
            EmptyView()
        } content: {
            GlassSegments(selection: $section, items: Section.allCases.map { ($0, $0.label) })
                .fixedSize()
            switch section {
            case .general: GeneralSettings()
            case .stockage: StorageSettings()
            case .projets: ProjectSettings()
            case .verifs: CheckSettings()
            case .notifs: NotificationSettings()
            case .privacy: PrivacySettings()
            }
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

// MARK: - Éléments communs

/// Carte de réglages : lignes séparées par un filet.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    subview
                }
            }
        }
        .cardBackground()
    }
}

/// Une ligne : intitulé et aide à gauche, contrôle à droite.
private struct SettingRow<Control: View>: View {
    let label: String
    var help: String = ""
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 14, weight: .semibold))
                if !help.isEmpty {
                    Text(help).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: 58)
    }
}

/// Choix parmi quelques valeurs : pastilles, la valeur choisie en bleu.
private struct Choice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = selection == option.0
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .padding(.horizontal, 11)
                        .frame(minHeight: 28)
                        .background { if selected { Capsule().fill(Theme.accent) } }
                        .contentShape(.capsule)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.cardFill, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
    }
}

private struct Switch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(label)
    }
}

/// Liste de dossiers : pastilles avec ×, « + Ajouter un dossier… ».
private struct FolderList: View {
    let folders: [String]
    let remove: (String) -> Void
    let add: (URL) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(folders, id: \.self) { folder in
                HStack(spacing: 4) {
                    Text(folder).font(.system(size: 12).monospaced())
                    Button { remove(folder) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 18, height: 18)
                            .background(Theme.hairline, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retirer \(folder)")
                }
                .padding(.leading, 10).padding(.trailing, 4)
                .frame(minHeight: 28)
                .background(Theme.raised, in: .capsule)
            }
            Button("+ Ajouter un dossier…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
                if panel.runModal() == .OK, let url = panel.url { add(url) }
            }
            .buttonStyle(PillButtonStyle(kind: .small))
        }
        .frame(maxWidth: 420, alignment: .trailing)
    }
}

// MARK: - Général

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var loginStatus = SMAppService.mainApp.status
    @ViewState private var loginError: String?
    @ViewState private var tools: [ToolProbe.Status] = []
    @ViewState private var fullDiskAccess = FullDiskAccess.granted

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsCard {
            SettingRow(label: "Apparence", help: "Suit le réglage du système par défaut") {
                Choice(selection: $preferences.appearance, options: [("system", "Système"), ("light", "Clair"), ("dark", "Sombre")])
            }
            SettingRow(label: "Transparence", help: "Intensité de l’effet verre") {
                Choice(selection: $preferences.glass, options: [("reduced", "Réduite"), ("normal", "Normale"), ("max", "Maximale")])
            }
            SettingRow(label: "Ouvrir à la connexion", help: loginError ?? loginHelp) {
                Switch(label: "Ouvrir à la connexion", isOn: Binding(get: { loginStatus == .enabled }, set: setLogin))
            }
            SettingRow(label: "Icône dans la barre des menus",
                       help: "CPU, mémoire, disque et alertes en un coup d’œil ; fermer la fenêtre laisse L’Atelier tourner") {
                Switch(label: "Icône dans la barre des menus", isOn: $preferences.menuBarIcon)
            }
            SettingRow(label: "Accès complet au disque",
                       help: fullDiskAccess ? "Accordé : la corbeille et tout ~/Library peuvent être mesurés"
                           : "Non accordé : la corbeille et certaines données d’apps ne sont pas mesurées") {
                Button("Ouvrir Réglages Système") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .buttonStyle(PillButtonStyle(kind: .small))
            }
        }
        .onAppear { fullDiskAccess = FullDiskAccess.granted }

        Card(title: "Outils de développement") {
            if tools.isEmpty {
                ProgressView("Recherche des outils…").frame(maxWidth: .infinity).padding()
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(tools) { status in
                        GridRow {
                            Image(systemName: status.installed ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(status.installed ? .green : .secondary)
                            Text(status.tool.name).font(.body.monospaced())
                            Text(status.version ?? (status.installed ? "version inconnue" : "non installé"))
                                .foregroundStyle(status.installed ? .primary : .secondary).lineLimit(1)
                            Text(status.path ?? "").font(.caption.monospaced()).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Text("\(tools.filter(\.installed).count) sur \(tools.count) installés · ceux qui manquent désactivent seulement les fonctions qui en dépendent")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { tools = await ToolProbe(runner: model.runner).probe() }

        Card(title: "À propos") {
            LabeledContent("Version", value: SettingsPage.version)
            LabeledContent("Identifiant", value: AppPaths.bundleIdentifier)
            LabeledContent("Données") {
                Button("Afficher dans le Finder") {
                    try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
                }
                .buttonStyle(.secondary)
            }
        }
    }

    private var loginHelp: String {
        switch loginStatus {
        case .requiresApproval: "À approuver dans Réglages Système › Général › Ouverture"
        default: "Lance L’Atelier à l’ouverture de session"
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Impossible : \(error.localizedDescription) (une app signée est nécessaire)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}

enum FullDiskAccess {
    /// La base des autorisations n'est lisible qu'avec l'accès complet au disque (aucune demande n'est affichée).
    static var granted: Bool {
        (try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")).close()) != nil
    }
}

// MARK: - Stockage

private struct StorageSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsCard {
            SettingRow(label: "Méthode de suppression par défaut",
                       help: "Proposée d’abord dans l’aperçu ; la corbeille permet d’annuler. Le Sonar n’utilise que la corbeille") {
                Choice(selection: $preferences.permanentByDefault, options: [(false, "Corbeille"), (true, "Définitive")])
            }
            SettingRow(label: "Projet considéré inactif après", help: "Ses artefacts de build sont cochés par défaut") {
                Choice(selection: Binding(get: { preferences.inactiveMonths }, set: {
                    preferences.inactiveMonths = $0
                    model.devScan.invalidate()
                }), options: [(1, "1 mois"), (3, "3 mois"), (6, "6 mois"), (12, "1 an")])
            }
            SettingRow(label: "Dossiers exclus", help: "Jamais proposés au nettoyage (Développement, Sonar)") {
                FolderList(folders: preferences.excludedFolders.map { ($0 as NSString).abbreviatingWithTildeInPath }) { folder in
                    let full = (folder as NSString).expandingTildeInPath
                    preferences.excludedFolders.removeAll { $0 == full }
                    model.devScan.invalidate()
                } add: { url in
                    guard !preferences.excludedFolders.contains(url.path) else { return }
                    preferences.excludedFolders.append(url.path)
                    model.devScan.invalidate()
                }
            }
            SettingRow(label: "Inclure Docker", help: "Lit docker system df dans la vue d’ensemble ; nécessite que Docker Desktop soit lancé") {
                Switch(label: "Inclure Docker", isOn: $preferences.includeDocker)
            }
            SettingRow(label: "Bureau, Documents, Téléchargements",
                       help: preferences.allowPersonalFolders ? "Inclus dans les analyses (autorisation de macOS)"
                           : "Exclus : macOS demandera l’autorisation si vous les incluez") {
                Switch(label: "Inclure Bureau, Documents, Téléchargements", isOn: Binding(get: { preferences.allowPersonalFolders }, set: { on in
                    if on {
                        model.allowPersonalFolders()
                    } else {
                        preferences.allowPersonalFolders = false
                        model.overview.invalidate()
                        model.explorer.invalidate()
                    }
                }))
            }
        }
    }
}

// MARK: - Projets

private struct ProjectSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsCard {
            SettingRow(label: "Dossiers de projets", help: "Où chercher les dépôts git") {
                FolderList(folders: model.projectRoots.map { $0.abbreviatingHome() }) { folder in
                    if let url = model.projectRoots.first(where: { $0.abbreviatingHome() == folder }) { model.removeProjectRoot(url) }
                } add: { url in
                    model.addProjectRoot(url)
                }
            }
            SettingRow(label: "Profondeur de recherche", help: "Sous-dossiers parcourus depuis chaque racine") {
                Choice(selection: Binding(get: { preferences.repoDepth }, set: {
                    preferences.repoDepth = $0
                    model.repos.invalidate()
                }), options: [(2, "2"), (4, "4"), (6, "6"), (8, "8")])
            }
            SettingRow(label: "Fetch automatique", help: "git fetch toutes les heures sur les dépôts avec un distant (noté dans l’Historique)") {
                Switch(label: "Fetch automatique", isOn: $preferences.autoFetch)
            }
            SettingRow(label: "Détecter les secrets commités", help: "Analyse locale, rien n’est envoyé") {
                Switch(label: "Détecter les secrets commités", isOn: Binding(get: { preferences.detectSecrets }, set: {
                    preferences.detectSecrets = $0
                    model.analysis.invalidate()
                }))
            }
            SettingRow(label: "Seuil de couverture", help: "En dessous, le projet est signalé") {
                Choice(selection: $preferences.coverageThreshold, options: [60, 70, 80, 90].map { ($0, "\($0) %") })
            }
            SettingRow(label: "Terminal", help: "Pour « Ouvrir dans Claude » et « Terminal »") {
                Picker("Terminal", selection: $preferences.terminal) {
                    ForEach(TerminalApp.allCases, id: \.self) { app in
                        Text(app.label + (app.installedURL == nil ? " (non installé)" : "")).tag(app)
                    }
                }
                .labelsHidden().fixedSize()
            }
            SettingRow(label: "Éditeur", help: "Pour « Ouvrir dans l’éditeur »") {
                Picker("Éditeur", selection: $preferences.editor) {
                    Text("App par défaut du Finder").tag(EditorApp?.none)
                    ForEach(EditorApp.installed, id: \.self) { Text($0.label).tag(EditorApp?.some($0)) }
                }
                .labelsHidden().fixedSize()
            }
            SettingRow(label: "Claude Code", help: model.runner.locator.locate("claude")?.path ?? "non trouvé : npm install -g @anthropic-ai/claude-code") {
                EmptyView()
            }
            SettingRow(label: "Enregistreur", help: "Quand un processus de dev démarre dans un projet") {
                Choice(selection: $preferences.recorderPolicy, options: RecorderPolicy.allCases.map { ($0, $0.label) })
            }
        }
    }
}

// MARK: - Vérifications

private struct CheckSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsCard {
            SettingRow(label: "Vérifier les mises à jour et failles",
                       help: "Paquets, dépendances des projets, OSV.dev — en arrière-plan tant que l’app tourne") {
                Choice(selection: $preferences.checkInterval, options: [("hourly", "Toutes les heures"), ("daily", "Chaque jour"), ("manual", "Manuellement")])
            }
            SettingRow(label: "Rafraîchir les news", help: "Le bouton ↻ de News relit tout de suite") {
                Choice(selection: $preferences.newsIntervalHours, options: [(1, "1 h"), (3, "3 h"), (6, "6 h"), (24, "1 jour")])
            }
            SettingRow(label: "Suspendre sur batterie", help: "Aucune vérification ni lecture de news hors secteur") {
                Switch(label: "Suspendre sur batterie", isOn: $preferences.pauseOnBattery)
            }
            SettingRow(label: "Proposer les mises à jour majeures", help: "Jamais cochées par défaut ; désactivé, elles sont masquées") {
                Switch(label: "Proposer les mises à jour majeures", isOn: Binding(get: { preferences.offerMajors }, set: {
                    preferences.offerMajors = $0
                    model.packages.offerMajors = $0
                }))
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsCard {
            SettingRow(label: "Failles critiques", help: "Quand une faille critique touche un paquet ou un projet de la machine (version vérifiée)") {
                Switch(label: "Failles critiques", isOn: $preferences.newsNotifications)
            }
            SettingRow(label: "Espace disque faible", help: "Sous 10 % d’espace libre, une fois par jour au plus") {
                Switch(label: "Espace disque faible", isOn: $preferences.notifyLowSpace)
            }
            SettingRow(label: "News « Vous concerne »", help: "Toute news qui touche la machine, même non critique") {
                Switch(label: "News « Vous concerne »", isOn: $preferences.notifyNews)
            }
            SettingRow(label: "Processus gourmand", help: "Plus de 80 % de CPU pendant 5 minutes (vos processus)") {
                Switch(label: "Processus gourmand", isOn: $preferences.notifyHeavyProcess)
            }
        }
        Text("macOS demande l’autorisation d’afficher des notifications la première fois qu’une alerte est envoyée.")
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
    }
}

// MARK: - Confidentialité

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var confirmClear = false
    @ViewState private var cacheBytes: Int64?

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsCard {
            SettingRow(label: "Interroger OSV.dev et GitHub Advisories",
                       help: "Envoie uniquement des noms et versions de paquets ; désactivé, les failles des dépendances ne sont plus vérifiées") {
                Switch(label: "Interroger OSV.dev et GitHub Advisories", isOn: Binding(get: { preferences.remoteAdvisories }, set: {
                    preferences.remoteAdvisories = $0
                    model.analysis.invalidate()
                }))
            }
            SettingRow(label: "Statistiques d’utilisation", help: "L’Atelier n’envoie aucune statistique ni télémétrie : il n’y a rien à activer") {
                Text("Aucune").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            SettingRow(label: "Historique des actions", help: "Conservé \(preferences.historyDays) jours sur cette machine · \(model.history.count) entrées") {
                HStack(spacing: 8) {
                    Choice(selection: Binding(get: { preferences.historyDays }, set: { days in
                        preferences.historyDays = days
                        Task {
                            try? await model.historyStore.prune(olderThan: days)
                            await model.reloadHistory()
                        }
                    }), options: [(30, "30 j"), (90, "90 j"), (365, "1 an")])
                    Button("Effacer l’historique…") { confirmClear = true }
                        .buttonStyle(PillButtonStyle(kind: .small))
                        .foregroundStyle(Theme.red)
                }
            }
            SettingRow(label: "Données de L’Atelier",
                       help: "Cache des analyses (registres, OSV, fin de vie) et scripts de lancement" + (cacheBytes.map { " · \(Format.bytes($0))" } ?? "")) {
                Button("Vider le cache…") { if let plan = clearCachePlan { model.preview(plan) } }
                    .buttonStyle(PillButtonStyle(kind: .small))
                    .disabled(clearCachePlan == nil)
            }
        }
        .confirmationDialog("Effacer tout l’historique des actions ?", isPresented: $confirmClear) {
            Button("Effacer l’historique", role: .destructive) { Task { await model.clearHistory() } }
        } message: {
            Text("Le journal des suppressions, mises à jour et commandes sera vidé. Cela ne défait aucune action.")
        }
        .task { cacheBytes = cacheTargets.reduce(0) { $0 + DiskUsage.measure($1).bytes } }
        Text("Réseau : uniquement les registres de paquets, OSV.dev, GitHub Advisories et les sources de news. Aucun code, chemin ni nom de projet n’est envoyé.")
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
    }

    private var cacheTargets: [URL] {
        // Les news gardées restent : la page News les gère (le magasin les réécrirait de toute façon).
        [DiskCache<RegistryInfo>.defaultDirectory]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var clearCachePlan: ActionPlan? {
        let targets = cacheTargets
        guard !targets.isEmpty else { return nil }
        return ActionPlan(
            title: "Vider le cache de L’Atelier",
            summary: "Les versions et failles seront redemandées à la prochaine analyse. L’historique, les news, les réglages et les sessions de l’Enregistreur sont gardés.",
            kind: .nettoyage, risk: .safe, reversible: true,
            steps: targets.map { .remove($0, bytes: DiskUsage.measure($0).bytes, permanently: false) }
        )
    }
}

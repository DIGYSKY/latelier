import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
        } detail: {
            PageContainer(page: model.selection)
                .id(model.selection)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background { Backdrop(glass: model.preferences.glass) }
        .onAppear { applyAppearance(model.preferences.appearance) }
        .onChange(of: model.preferences.appearance) { _, value in applyAppearance(value) }
        .tint(Theme.accent)
        .sheet(item: $model.pendingPlan) { plan in
            PlanSheet(plan: plan)
        }
        .sheet(item: $model.processDetail) { request in
            ProcessDetailSheet(pid: request.pid)
                .id(request.pid)
        }
        .sheet(item: $model.pendingClaude) { request in
            ClaudeSheet(request: request)
        }
        .alert("Action impossible", isPresented: Binding(get: { model.actionNotice != nil }, set: { if !$0 { model.actionNotice = nil } })) {
            Button("OK") { model.actionNotice = nil }
        } message: {
            Text(model.actionNotice ?? "")
        }
        .alert("Ouverture impossible", isPresented: Binding(get: { model.launchError != nil }, set: { if !$0 { model.launchError = nil } })) {
            Button("OK") { model.launchError = nil }
        } message: {
            Text(model.launchError ?? "")
        }
    }
}

/// Réglages › Général › Apparence.
@MainActor
func applyAppearance(_ value: String) {
    NSApp.appearance = switch value {
    case "light": NSAppearance(named: .aqua)
    case "dark": NSAppearance(named: .darkAqua)
    default: nil
    }
}

/// Choisit l'écran à afficher.
struct PageContainer: View {
    let page: Page

    var body: some View {
        switch page {
        case .accueil: HomePage()
        case .historique: HistoryPage()
        case .reglages: SettingsPage()
        case .systeme: SystemPage()
        case .dev: DevPage()
        case .depots: ReposPage()
        case .modifications: BackToProjects { ModificationsPage() }
        case .majs: UpdatesPage()
        case .inventaire: InventoryPage()
        case .runtimes: RuntimesPage()
        case .services: ServicesPage()
        case .dependances: BackToProjects { DependenciesPage() }
        case .securite: BackToProjects { SecurityPage() }
        case .perfVue: PerformancePage()
        case .processus: ProcessesPage()
        case .reseau: NetworkPage()
        case .demarrage: StartupPage()
        case .commandes: BackToProjects { CommandsPage() }
        case .couverture: BackToProjects { CoveragePage() }
        case .enregistreur: RecorderPage()
        case .moniteur: MonitorPage()
        case .pourVous, .cyber, .langages, .favoris: NewsPage(page: page)
        case .sources: NewsSourcesPage()
        case .stockageVue: StorageOverviewPage()
        case .appsNettoyage: AppsCleanupPage()
        case .desinstalleur: UninstallerPage()
        case .docker: DockerPage()
        case .caches: CachesPage()
        case .explorateur: ExplorerPage()
        case .sonar: SonarPage()
        }
    }
}

/// Vues « tous les projets » : un retour vers la liste des dépôts.
struct BackToProjects<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.openRepo = nil
                model.selection = .depots
            } label: { Label("Projets", systemImage: "chevron.left") }
                .buttonStyle(PillButtonStyle(kind: .small))
                .padding(.leading, 22)
                .padding(.top, 4)
            content
        }
    }
}

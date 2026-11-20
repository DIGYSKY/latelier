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
        .background { Backdrop() }
        .tint(Theme.accent)
        .sheet(item: $model.pendingPlan) { plan in
            PlanSheet(plan: plan)
        }
        .sheet(item: $model.pendingClaude) { request in
            ClaudeSheet(request: request)
        }
        .alert("Ouverture impossible", isPresented: Binding(get: { model.launchError != nil }, set: { if !$0 { model.launchError = nil } })) {
            Button("OK") { model.launchError = nil }
        } message: {
            Text(model.launchError ?? "")
        }
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
        case .modifications: ModificationsPage()
        case .majs: UpdatesPage()
        case .inventaire: InventoryPage()
        case .runtimes: RuntimesPage()
        case .services: ServicesPage()
        case .dependances: DependenciesPage()
        case .securite: SecurityPage()
        case .perfVue: PerformancePage()
        case .processus: ProcessesPage()
        case .reseau: NetworkPage()
        case .demarrage: StartupPage()
        case .commandes: CommandsPage()
        case .couverture: CoveragePage()
        case .enregistreur: RecorderPage()
        case .pourVous, .cyber, .langages, .favoris: NewsPage(page: page)
        case .sources: NewsSourcesPage()
        default: PlaceholderPage(page: page)
        }
    }
}

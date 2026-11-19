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
        .background { Backdrop() }
        .tint(Theme.accent)
        .sheet(item: $model.pendingPlan) { plan in
            PlanSheet(plan: plan)
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
        default: PlaceholderPage(page: page)
        }
    }
}

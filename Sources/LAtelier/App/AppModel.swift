import LAtelierCore
import Observation
import SwiftUI

/// État global : écran affiché, historique, action en attente d'aperçu.
@Observable
final class AppModel {
    var selection: Page = .accueil
    var history: [HistoryEntry] = []
    var historyError: String?
    /// Action montrée dans la feuille d'aperçu. Toute action qui modifie passe par là.
    var pendingPlan: ActionPlan?

    let runner = CommandRunner()
    let historyStore: HistoryStore

    init(historyStore: HistoryStore = HistoryStore()) {
        self.historyStore = historyStore
        // Ouvre directement un écran (captures, développement) : LATELIER_PAGE=sonar
        if let raw = ProcessInfo.processInfo.environment["LATELIER_PAGE"], let page = Page(rawValue: raw) {
            selection = page
        }
        Task { await reloadHistory() }
    }

    func preview(_ plan: ActionPlan) {
        pendingPlan = plan
    }

    func reloadHistory() async {
        do {
            history = try await historyStore.all()
            historyError = nil
        } catch {
            historyError = "Historique illisible : \(error.localizedDescription)"
        }
    }

    func record(_ entry: HistoryEntry) async {
        do {
            try await historyStore.append(entry)
        } catch {
            historyError = "Impossible d’enregistrer l’historique : \(error.localizedDescription)"
        }
        await reloadHistory()
    }

    func clearHistory() async {
        do {
            try await historyStore.clear()
        } catch {
            historyError = "Impossible de vider l’historique : \(error.localizedDescription)"
        }
        await reloadHistory()
    }
}

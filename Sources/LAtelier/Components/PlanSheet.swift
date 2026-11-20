import LAtelierCore
import SwiftUI

/// Aperçu obligatoire avant toute action qui modifie quelque chose (maquette « Aperçu ») :
/// ce qui va se passer, puis la progression, puis le résultat, noté dans l'Historique.
struct PlanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var plan: ActionPlan
    @ViewState private var run = PlanRun()

    init(plan: ActionPlan) {
        _plan = ViewState(initialValue: plan)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch run.phase {
            case .preview: preview
            case .running: running
            case .finished(let entry): finished(entry)
            }
        }
        .frame(width: 640)
        .interactiveDismissDisabled(run.phase == .running)
    }

    // MARK: - Aperçu

    private var preview: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.title).font(.system(size: 21, weight: .bold))
                Text(plan.summary).foregroundStyle(Theme.muted)
            }

            HStack(spacing: 10) {
                if let bytes = plan.estimatedBytes, bytes > 0 {
                    stat("Espace libéré", Format.bytes(bytes), color: Theme.accent, big: true)
                }
                stat("Éléments", plan.removesFiles ? "\(plan.removals.count) élément\(plan.removals.count > 1 ? "s" : "")" : "\(plan.steps.count) commande\(plan.steps.count > 1 ? "s" : "")")
                stat("Risque", plan.risk == .safe ? "Tout sans risque" : plan.risk.label, color: RiskBadge(risk: plan.risk).color)
            }

            stepList

            if !plan.skipped.isEmpty {
                Callout(symbol: "exclamationmark.triangle", tint: .orange) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(plan.skipped.count) élément\(plan.skipped.count > 1 ? "s" : "") ignoré\(plan.skipped.count > 1 ? "s" : "") : en cours d’utilisation.").bold()
                        ForEach(plan.skipped.prefix(3), id: \.self) { Text($0) }
                    }
                }
            }

            if plan.removesFiles { methodPicker }

            if !plan.reversible {
                Text(plan.removesPermanently
                     ? "La suppression définitive ne passe pas par la corbeille. Elle ne pourra pas être annulée."
                     : "Cette action ne pourra pas être annulée.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.red)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer(note: "Ajouté à l’historique après l’opération") {
                Button("Annuler") { dismiss() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(ctaLabel) { run.start(plan, model: model) }
                    .buttonStyle(.primary(tint: plan.reversible ? Theme.accent : Theme.red))
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.risk == .protected)
            }
        }
    }

    private var ctaLabel: String {
        if plan.removesFiles { return plan.removesPermanently ? "Supprimer définitivement" : "Mettre à la corbeille" }
        return plan.reversible ? "Exécuter" : "Exécuter quand même"
    }

    /// Les chemins les plus lourds, ou les commandes.
    private var stepList: some View {
        let rows: [(String, String?)] = plan.removesFiles
            ? plan.removals.sorted { $0.bytes > $1.bytes }.map { ($0.url.abbreviatingHome(), Format.bytes($0.bytes)) }
            : plan.steps.filter(\.isCommandLike).map { ($0.displayString, nil) }
        let extraCommands = plan.removesFiles ? plan.steps.filter(\.isCommandLike).map { ($0.displayString, String?.none) } : []
        let shown = Array(rows.prefix(6)) + extraCommands
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, row in
                if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                HStack(spacing: 12) {
                    Text(row.0)
                        .font(.system(size: 12).monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let size = row.1 { Text(size).font(.system(size: 13, weight: .semibold).monospacedDigit()) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            if rows.count > 6 {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text("et \(rows.count - 6) autre\(rows.count - 6 > 1 ? "s" : "")")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .background(Theme.raised.opacity(0.75), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardBorder))
    }

    private var methodPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Méthode").font(.system(size: 13, weight: .semibold)).padding(.bottom, 2)
            methodRow(permanent: false, label: "Mettre à la corbeille", note: "récupérable depuis le Finder")
            if plan.allowsPermanent {
                methodRow(permanent: true, label: "Supprimer définitivement", note: "irréversible")
            }
        }
    }

    private func methodRow(permanent: Bool, label: String, note: String) -> some View {
        let selected = plan.removesPermanently == permanent
        let tint = permanent ? Theme.red : Theme.accent
        return Button {
            plan = plan.removing(permanently: permanent)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? tint : Theme.muted)
                (Text(label).bold() + Text(" · \(note)").foregroundStyle(permanent ? Theme.red : Theme.muted))
                    .font(.system(size: 14))
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .background(selected ? tint.opacity(0.08) : Theme.raised.opacity(0.5), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? tint.opacity(0.4) : Theme.hairline))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - En cours

    private var running: some View {
        VStack(spacing: 16) {
            Text(plan.removesFiles ? "Nettoyage en cours…" : "Exécution en cours…").font(.system(size: 21, weight: .bold))
            Text(run.current ?? " ")
                .font(.system(size: 12).monospaced())
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: run.progress(of: plan))
                .progressViewStyle(.linear)
                .tint(plan.reversible ? Theme.accent : Theme.red)
                .frame(maxWidth: 420)
            Text("\(Int(run.progress(of: plan) * 100)) %").font(.system(size: 13)).foregroundStyle(Theme.muted)
            if !plan.removesFiles { console }
            Button("Arrêter") { run.stop() }.buttonStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 40)
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(run.lines) { line in
                        Text(line.text)
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(line.isError ? Theme.orange : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(10)
            }
            .frame(height: 180)
            .background(Color.black.opacity(0.06), in: .rect(cornerRadius: 12))
            .onChange(of: run.lines.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    // MARK: - Terminé

    private func finished(_ entry: HistoryEntry) -> some View {
        let success = entry.outcome == .success
        return VStack(spacing: 14) {
            Image(systemName: success ? "checkmark" : entry.outcome == .cancelled ? "stop.fill" : "exclamationmark")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(success ? Color(hex: 0x1E8A45) : entry.outcome == .cancelled ? Theme.muted : Theme.orange))
                .shadow(color: (success ? Color(hex: 0x1E8A45) : Theme.orange).opacity(0.35), radius: 12, y: 10)
            Text(doneTitle(entry)).font(.system(size: 22, weight: .bold))
            Text(doneText(entry))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if let hint = FailureAdvisor.hint(for: entry) {
                FailureHintCard(hint: hint) { dismiss() }
                    .frame(maxWidth: 480)
            }
            HStack(spacing: 10) {
                Button("Voir l’historique") {
                    model.selection = .historique
                    dismiss()
                }
                .buttonStyle(.secondary)
                Button("Fermer") { dismiss() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 28)
    }

    private func doneTitle(_ entry: HistoryEntry) -> String {
        switch entry.outcome {
        case .success: entry.bytesFreed.map { "\(Format.bytes($0)) libérés" } ?? "Terminé"
        case .partial: entry.bytesFreed.map { "\(Format.bytes($0)) libérés, en partie" } ?? "Fait en partie"
        case .failure: "Échec"
        case .cancelled: "Annulé"
        }
    }

    private func doneText(_ entry: HistoryEntry) -> String {
        switch entry.outcome {
        case .success:
            if plan.removesFiles {
                return plan.removesPermanently
                    ? "\(plan.removals.count) élément(s) supprimé(s) définitivement."
                    : "\(plan.removals.count) élément(s) mis à la corbeille. Vous pouvez les récupérer depuis le Finder tant qu’elle n’est pas vidée."
            }
            return "Toutes les commandes ont réussi."
        case .partial(let message), .failure(let message): return message
        case .cancelled: return "Rien n’a été modifié."
        }
    }

    // MARK: - Morceaux

    private func stat(_ label: String, _ value: String, color: Color = .primary, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text(value)
                .font(.system(size: big ? 22 : 15, weight: big ? .bold : .semibold))
                .foregroundStyle(color)
                .padding(.top, big ? 0 : 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
        .background(Theme.raised.opacity(0.75), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardBorder))
    }

    private func footer<Buttons: View>(note: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
            buttons()
        }
        .padding(.leading, 28)
        .padding(.trailing, 20)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.4))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// Encadré coloré (avertissement, information).
struct Callout<Content: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            content.font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tint.opacity(0.16), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.35)))
    }
}

/// Déroulement d'une exécution : progression, ligne en cours, console.
@Observable
final class PlanRun {
    enum Phase: Equatable {
        case preview, running, finished(HistoryEntry)
    }

    struct Line: Identifiable {
        let id: Int
        let text: String
        let isError: Bool
    }

    private(set) var phase: Phase = .preview
    private(set) var lines: [Line] = []
    private(set) var current: String?
    private(set) var completedSteps = 0
    private var task: Task<Void, Never>?
    private static let maxLines = 5_000

    func progress(of plan: ActionPlan) -> Double {
        plan.steps.isEmpty ? 1 : min(1, Double(completedSteps) / Double(plan.steps.count))
    }

    func start(_ plan: ActionPlan, model: AppModel) {
        guard phase == .preview else { return }
        phase = .running
        let (events, continuation) = AsyncStream<(Int, CommandEvent)>.makeStream()
        let executor = PlanExecutor(runner: model.runner)

        task = Task {
            let consumer = Task {
                for await (index, event) in events { self.handle(index, event, plan: plan) }
            }
            let entry = await executor.execute(plan) { index, event in continuation.yield((index, event)) }
            continuation.finish()
            await consumer.value
            await model.record(entry)
            phase = .finished(entry)
        }
    }

    func stop() {
        task?.cancel()
    }

    private func handle(_ index: Int, _ event: CommandEvent, plan: ActionPlan) {
        switch event {
        case .stdout(let text):
            if case .remove = plan.steps[index] {
                current = URL(fileURLWithPath: text).abbreviatingHome()
            } else {
                current = plan.steps[index].displayString
                append(text, isError: false)
            }
        case .stderr(let text):
            append(text, isError: true)
        case .exited:
            completedSteps += 1
        }
    }

    private func append(_ text: String, isError: Bool) {
        lines.append(Line(id: (lines.last?.id ?? -1) + 1, text: text, isError: isError))
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }
}

/// Explication d'un échec connu et sa correction (fenêtre de fin et Historique).
struct FailureHintCard: View {
    @Environment(AppModel.self) private var model
    let hint: FailureHint
    /// Appelé avant d'ouvrir la correction (fermer la feuille).
    var leave: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(hint.title, systemImage: "lightbulb").font(.system(size: 14, weight: .semibold))
            Text(hint.explanation).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let fix = hint.fix, let label = hint.fixLabel {
                    Button(label) {
                        leave()
                        let plan = ActionPlan(title: label.replacingOccurrences(of: "…", with: ""), summary: hint.explanation,
                                              kind: .paquet, risk: .safe, reversible: true, commands: [fix])
                        // La feuille actuelle se ferme d'abord.
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            model.preview(plan)
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .smallFilled))
                }
                if let raw = hint.page, let page = Page(rawValue: raw) {
                    Button("Ouvrir \(page.title)") {
                        leave()
                        model.selection = page
                    }
                    .buttonStyle(PillButtonStyle(kind: .small))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xFF9500).opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

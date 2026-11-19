import LAtelierCore
import SwiftUI

/// Aperçu obligatoire avant toute action qui modifie quelque chose,
/// puis exécution avec la sortie en direct, puis résultat noté dans l'Historique.
struct PlanSheet: View {
    let plan: ActionPlan
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var run = PlanRun()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Text(plan.summary).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Ce qui va être exécuté").font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.commands.enumerated()), id: \.offset) { index, spec in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            commandStatus(index)
                            Text(spec.displayString)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.06), in: .rect(cornerRadius: 12))
                Label(
                    plan.reversible ? "Réversible : les fichiers vont à la corbeille." : "Irréversible.",
                    systemImage: plan.reversible ? "arrow.uturn.backward" : "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(plan.reversible ? Color.secondary : Color.orange)
            }

            if run.phase != .preview { console }
            footer
        }
        .padding(24)
        .frame(width: 640)
        .frame(minHeight: 300)
        .interactiveDismissDisabled(run.phase == .running)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: plan.kind.symbol)
                .font(.title2)
                .foregroundStyle(plan.kind.tint)
                .frame(width: 40, height: 40)
                .glassEffect(.regular.tint(plan.kind.tint.opacity(0.15)), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title).font(.title2.weight(.semibold))
                if let bytes = plan.estimatedBytes {
                    Text("\(Format.bytes(bytes)) à libérer").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            RiskBadge(risk: plan.risk)
        }
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(run.lines) { line in
                        Text(line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.isError ? Color.orange : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(10)
            }
            .frame(height: 200)
            .background(.black.opacity(0.08), in: .rect(cornerRadius: 12))
            .onChange(of: run.lines.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if case .finished(let entry) = run.phase {
                OutcomeBadge(outcome: entry.outcome)
                if case .partial(let message) = entry.outcome {
                    Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                } else if case .failure(let message) = entry.outcome {
                    Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            switch run.phase {
            case .preview:
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                Button(plan.risk == .danger ? "Exécuter quand même" : "Exécuter") {
                    run.start(plan, model: model)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(plan.risk == .danger ? .red : .accentColor)
                .disabled(plan.risk == .protected)
            case .running:
                ProgressView().controlSize(.small)
                Button("Arrêter", role: .destructive) { run.stop() }
                    .buttonStyle(.glass)
            case .finished:
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
    }

    @ViewBuilder
    private func commandStatus(_ index: Int) -> some View {
        switch run.status(of: index) {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// Déroulement d'une exécution : lignes de console et état de chaque commande.
@Observable
final class PlanRun {
    enum Phase: Equatable {
        case preview, running, finished(HistoryEntry)
    }

    enum CommandStatus { case waiting, running, done, failed }

    struct Line: Identifiable {
        let id: Int
        let text: String
        let isError: Bool
    }

    private(set) var phase: Phase = .preview
    private(set) var lines: [Line] = []
    private var statuses: [Int: CommandStatus] = [:]
    private var task: Task<Void, Never>?
    private static let maxLines = 5_000

    func status(of index: Int) -> CommandStatus { statuses[index] ?? .waiting }

    func start(_ plan: ActionPlan, model: AppModel) {
        guard phase == .preview else { return }
        phase = .running
        let (events, continuation) = AsyncStream<(Int, CommandEvent)>.makeStream()
        let executor = PlanExecutor(runner: model.runner)

        task = Task {
            let consumer = Task { for await (index, event) in events { self.handle(index, event) } }
            let entry = await executor.execute(plan) { index, event in continuation.yield((index, event)) }
            continuation.finish()
            await consumer.value
            for (index, _) in plan.commands.enumerated() where statuses[index] == .running {
                statuses[index] = .failed
            }
            await model.record(entry)
            phase = .finished(entry)
        }
    }

    func stop() {
        task?.cancel()
    }

    private func handle(_ index: Int, _ event: CommandEvent) {
        if statuses[index] == nil { statuses[index] = .running }
        switch event {
        case .stdout(let text): append(text, isError: false)
        case .stderr(let text): append(text, isError: true)
        case .exited(let status, let signaled):
            statuses[index] = status == 0 && !signaled ? .done : .failed
        }
    }

    private func append(_ text: String, isError: Bool) {
        lines.append(Line(id: (lines.last?.id ?? -1) + 1, text: text, isError: isError))
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }
}

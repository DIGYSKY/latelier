import LAtelierCore
import SwiftUI

struct HistoryPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var kind: HistoryEntry.Kind?
    @ViewState private var search = ""
    @ViewState private var expanded: Set<UUID> = []
    @ViewState private var confirmClear = false

    var body: some View {
        PageScaffold(page: .historique, subtitle: "Tout ce que L’Atelier a fait, avec les commandes et leur sortie.") {
            Button("Vider", systemImage: "trash") { confirmClear = true }
                .buttonStyle(.secondary)
                .disabled(model.history.isEmpty)
        } content: {
            HStack(spacing: 12) {
                Picker("Type", selection: $kind) {
                    Text("Tout").tag(HistoryEntry.Kind?.none)
                    ForEach(HistoryEntry.Kind.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Rechercher", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                if let freed = totalFreed, freed > 0 {
                    Text("\(Format.bytes(freed)) libérés au total")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.historyError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }

            Card(padding: 8) {
                if filtered.isEmpty {
                    EmptyState(
                        symbol: "clock",
                        title: model.history.isEmpty ? "Aucune action pour l’instant" : "Aucun résultat",
                        message: model.history.isEmpty ? "Nettoyages, commandes git et mises à jour apparaîtront ici." : nil
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedByDay, id: \.day) { section in
                            Text(section.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(section.entries) { entry in
                                HistoryRow(entry: entry, expanded: expanded.contains(entry.id))
                                    .padding(.horizontal, 12)
                                    .contentShape(.rect)
                                    .onTapGesture { toggle(entry.id) }
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Vider l’historique ?", isPresented: $confirmClear) {
            Button("Vider", role: .destructive) { Task { await model.clearHistory() } }
        } message: {
            Text("Les \(model.history.count) entrées seront supprimées. Les actions elles-mêmes ne sont pas annulées.")
        }
    }

    private var filtered: [HistoryEntry] {
        model.history.filter { entry in
            (kind == nil || entry.kind == kind)
                && (search.isEmpty
                    || entry.title.localizedCaseInsensitiveContains(search)
                    || entry.summary.localizedCaseInsensitiveContains(search)
                    || entry.commands.contains { $0.command.localizedCaseInsensitiveContains(search) })
        }
    }

    private var groupedByDay: [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var result: [(day: Date, entries: [HistoryEntry])] = []
        for entry in filtered {
            let day = calendar.startOfDay(for: entry.date)
            if result.last?.day == day {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append((day, [entry]))
            }
        }
        return result
    }

    private var totalFreed: Int64? {
        let values = model.history.compactMap(\.bytesFreed)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private func toggle(_ id: UUID) {
        withAnimation(.snappy) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }
}

struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: HistoryEntry
    let expanded: Bool
    /// Version courte (Accueil) : sans résumé ni taille.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: entry.kind.symbol)
                    .foregroundStyle(entry.kind.tint)
                    .frame(width: 28, height: 28)
                    .background(entry.kind.tint.opacity(0.12), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.body.weight(.medium))
                    if !compact, !entry.summary.isEmpty {
                        Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if !compact, let bytes = entry.bytesFreed {
                    Text(Format.bytes(bytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                OutcomeBadge(outcome: entry.outcome)
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if expanded {
                if case .partial(let message) = entry.outcome {
                    Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                } else if case .failure(let message) = entry.outcome {
                    Label(message, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red)
                }
                if let hint = FailureAdvisor.hint(for: entry) { FailureHintCard(hint: hint) }
                if entry.outcome != .success && entry.outcome != .cancelled {
                    HStack {
                        Spacer()
                        Button("Signaler ce problème…", systemImage: "ladybug") {
                            let output = entry.commands.map { "$ \($0.command)\n\($0.output)" }.joined(separator: "\n\n")
                            model.reportIssue(.bug, details: "\(entry.title)\n\(output)")
                        }
                        .buttonStyle(PillButtonStyle(kind: .small))
                        .help("Ouvre une issue GitHub pré-remplie ; votre dossier personnel et votre nom de compte sont masqués. Relisez avant de publier.")
                    }
                }
                ForEach(Array(entry.commands.enumerated()), id: \.offset) { _, log in
                    CommandLogView(log: log)
                }
                if entry.commands.isEmpty {
                    Text("Aucune commande externe.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
    }
}

private struct CommandLogView: View {
    let log: CommandLog

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("$ " + log.command).font(.callout.monospaced()).textSelection(.enabled)
                Spacer()
                Text(statusText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !log.output.isEmpty {
                ScrollView {
                    Text(log.output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(10)
        .background(.black.opacity(0.06), in: .rect(cornerRadius: 10))
        .padding(.leading, 40)
    }

    private var statusText: String {
        let status = log.exitStatus.map { "code \($0)" } ?? "interrompue"
        return "\(status) · \(Format.duration(log.duration))"
    }
}

struct OutcomeBadge: View {
    let outcome: HistoryEntry.Outcome

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: .capsule)
    }

    private var label: String {
        switch outcome {
        case .success: "Réussi"
        case .partial: "Partiel"
        case .failure: "Échec"
        case .cancelled: "Annulé"
        }
    }

    private var color: Color {
        switch outcome {
        case .success: .green
        case .partial: .orange
        case .failure: .red
        case .cancelled: .gray
        }
    }
}

extension HistoryEntry.Kind {
    var symbol: String {
        switch self {
        case .nettoyage: "sparkles"
        case .git: "arrow.triangle.branch"
        case .paquet: "cube.box"
        case .commande: "terminal"
        case .systeme: "gearshape.2"
        case .processus: "xmark.octagon"
        case .serveur: "server.rack"
        }
    }

    var tint: Color {
        switch self {
        case .nettoyage: .blue
        case .git: .orange
        case .paquet: .purple
        case .commande: .teal
        case .systeme: .gray
        case .processus: .red
        case .serveur: .indigo
        }
    }
}

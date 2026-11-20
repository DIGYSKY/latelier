import LAtelierCore
import SwiftUI

/// Projets › Couverture : rapports existants (lcov, Cobertura, JaCoCo, llvm-cov, go) ou tests lancés avec couverture.
struct CoveragePage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.projectScope) private var scope
    @ViewState private var selected: URL?

    var body: some View {
        @Bindable var preferences = model.preferences
        let store = model.coverage
        PageScaffold(page: .couverture, subtitle: String(localized: "Lue depuis les rapports existants (lcov, Cobertura, JaCoCo, llvm-cov) ou générée en lançant les tests")) {
            if store.loading { ProgressView().controlSize(.small) }
            Picker(String(localized: "Seuil"), selection: $preferences.coverageThreshold) {
                ForEach([60, 70, 80, 90], id: \.self) { Text("\($0) %").tag($0) }
            }
            .fixedSize()
        } content: {
            if let all = store.value {
                let entries = scope.map { project in all.filter { $0.project.standardizedFileURL == project.standardizedFileURL } } ?? all
                if scope != nil, let entry = entries.first {
                    CoverageDetail(entry: entry, threshold: preferences.coverageThreshold)
                } else if scope != nil {
                    Card { EmptyState(symbol: "checkmark.seal", title: String(localized: "Pas de couverture pour ce projet"),
                                      message: String(localized: "Aucun outil de test reconnu (Vitest, Jest, pytest, cargo, go, JaCoCo, swift test).")) }
                } else if entries.isEmpty {
                    Card { EmptyState(symbol: "checkmark.seal", title: String(localized: "Aucun projet testable"), message: String(localized: "Aucun outil de test reconnu dans les projets détectés.")) }
                } else {
                    let current = entries.first { $0.project == selected } ?? entries[0]
                    HStack(alignment: .top, spacing: 14) {
                        ProjectList(entries: entries, selected: current.project, threshold: preferences.coverageThreshold) { selected = $0 }
                            .frame(width: 320)
                        CoverageDetail(entry: current, threshold: preferences.coverageThreshold)
                            .frame(maxWidth: .infinity)
                    }
                    summary(entries, threshold: preferences.coverageThreshold)
                }
            } else {
                ScanningCard(label: String(localized: "Recherche des rapports de couverture…"))
            }
        }
        .onAppear {
            model.ensureRepos()
            if store.stale && !store.loading && !model.repos.repos.isEmpty { model.scanCoverage() }
        }
        .onChange(of: model.repos.repos.count) { if store.stale && !store.loading { model.scanCoverage() } }
        .onChange(of: store.stale) { _, stale in if stale && !store.loading { model.scanCoverage() } }
    }

    private func summary(_ entries: [CoverageEntry], threshold: Int) -> some View {
        let measured = entries.filter { $0.report != nil }
        let below = measured.filter { $0.report!.lines < Double(threshold) }.count
        return Text((measured.count > 1 ? String(localized: "\(measured.count) projets mesurés sur \(entries.count) · \(below) sous le seuil de \(threshold) % · historique des mesures gardé sur ce Mac") : String(localized: "\(measured.count) projet mesuré sur \(entries.count) · \(below) sous le seuil de \(threshold) % · historique des mesures gardé sur ce Mac")))
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
    }
}

/// Couleur selon le seuil : vert au-dessus, orange jusqu'à 15 points dessous, rouge ensuite.
func coverageColor(_ value: Double, threshold: Int) -> Color {
    if value >= Double(threshold) { return Tag.green.0 }
    if value >= Double(threshold - 15) { return Tag.orange.0 }
    return Tag.red.0
}

private struct ProjectList: View {
    @Environment(AppModel.self) private var model
    let entries: [CoverageEntry]
    let selected: URL
    let threshold: Int
    let pick: (URL) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(entries) { entry in
                let isSelected = entry.project == selected
                Button { pick(entry.project) } label: {
                    HStack(spacing: 12) {
                        Ring(value: entry.report?.lines, threshold: threshold)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.projectName(entry.project)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text("\(entry.setup.tool) · " + (entry.report.map { FrenchDate.relative($0.date) } ?? String(localized: "jamais mesuré")))
                                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        trend(entry)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isSelected ? Theme.raised : Theme.cardFill, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(isSelected ? Theme.accent.opacity(0.4) : Theme.cardBorder))
                    .shadow(color: Theme.shadow.opacity(isSelected ? 0.12 : 0), radius: 7, y: 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func trend(_ entry: CoverageEntry) -> some View {
        if entry.report == nil {
            Text("aucun rapport").font(.system(size: 11)).foregroundStyle(Theme.muted)
        } else if let delta = entry.trend, abs(delta) >= 0.5 {
            Text(delta > 0 ? String(localized: "▲ \(Int(delta.rounded())) pts") : String(localized: "▼ \(Int((-delta).rounded())) pts"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(delta > 0 ? Tag.green.0 : Tag.red.0)
        } else {
            Text("=").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
        }
    }
}

/// Anneau de pourcentage.
private struct Ring: View {
    let value: Double?
    let threshold: Int

    var body: some View {
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: 4)
            if let value {
                Circle()
                    .trim(from: 0, to: value / 100)
                    .stroke(coverageColor(value, threshold: threshold), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
        }
        .frame(width: 40, height: 40)
        .accessibilityLabel(value.map { String(localized: "\(Int($0)) % de lignes couvertes") } ?? String(localized: "Pas de rapport"))
    }
}

private struct CoverageDetail: View {
    @Environment(AppModel.self) private var model
    let entry: CoverageEntry
    let threshold: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.projectName(entry.project)).font(.system(size: 19, weight: .bold))
                    if let command = entry.setup.command {
                        Text("$ " + ([command.tool] + command.arguments).map(ShellQuote.quote).joined(separator: " "))
                            .font(.system(size: 12).monospaced()).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if entry.setup.missing != nil, let plan = CoverageDetector.installPlan(project: entry.project, setup: entry.setup, thenRun: true) {
                    Button(String(localized: "Ajouter et mesurer…")) { model.preview(plan) }
                        .buttonStyle(PillButtonStyle(kind: .smallFilled))
                } else if let plan = CoverageDetector.runPlan(project: entry.project, setup: entry.setup) {
                    Button(String(localized: "Lancer les tests avec couverture…")) { model.preview(plan) }
                        .buttonStyle(PillButtonStyle(kind: .smallFilled))
                        .disabled(model.runner.locator.locate(entry.setup.command!.tool) == nil && !entry.setup.command!.tool.hasPrefix("./"))
                }
            }

            if let missing = entry.setup.missing {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(missing.package) n’est pas installé", systemImage: "puzzlepiece.extension")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.orange)
                    Text(missing.why).font(.system(size: 13))
                    HStack(spacing: 8) {
                        Text("$ " + ([missing.install.tool] + missing.install.arguments).joined(separator: " "))
                            .font(.system(size: 12).monospaced()).foregroundStyle(Theme.muted).textSelection(.enabled)
                        Spacer()
                        if let plan = CoverageDetector.installPlan(project: entry.project, setup: entry.setup, thenRun: false) {
                            Button(String(localized: "Ajouter seulement…")) { model.preview(plan) }.buttonStyle(PillButtonStyle(kind: .small))
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0xFF9500).opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
            }
            if let report = entry.report {
                HStack(spacing: 10) {
                    metric(String(localized: "Lignes"), report.lines)
                    if let branches = report.branches { metric("Branches", branches) }
                    if let functions = report.functions { metric(String(localized: "Fonctions"), functions) }
                }
                weakest(report)
                HStack(spacing: 8) {
                    Text(String(localized: "Rapport \(report.format.label) · \(report.file) · \(FrenchDate.relative(report.date))"))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if report.lines < Double(threshold) {
                        Button("Demander à Claude d’ajouter des tests", systemImage: "sparkles") {
                            model.askClaude(entry.project, prompt: ClaudePrompts.coverage(weakest: report.weakest(), threshold: threshold),
                                            context: String(localized: "Couverture de \(entry.project.lastPathComponent) : \(Int(report.lines)) %"))
                        }
                        .buttonStyle(.small)
                    }
                }
            } else {
                Text(entry.setup.command == nil
                     ? String(localized: "Aucun outil de couverture reconnu pour ce projet.")
                     : String(localized: "Aucun rapport de couverture trouvé. Lancez les tests avec couverture pour en générer un : la commande est montrée avant d’être exécutée."))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.raised.opacity(0.5), in: .rect(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func metric(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
            Text("\(Format.decimal(value, decimals: value >= 99.95 || value.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1)) %")
                .font(.system(size: 24, weight: .bold)).monospacedDigit()
                .foregroundStyle(coverageColor(value, threshold: threshold))
            Bar(value: value, color: coverageColor(value, threshold: threshold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised.opacity(0.6), in: .rect(cornerRadius: 16, style: .continuous))
    }

    private func weakest(_ report: CoverageReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fichiers les moins couverts").font(.system(size: 14, weight: .semibold))
            ForEach(report.weakest(8), id: \.path) { file in
                HStack(spacing: 12) {
                    Text(file.path).font(.system(size: 12).monospaced()).lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Bar(value: file.percent, color: coverageColor(file.percent, threshold: threshold)).frame(width: 140)
                    Text("\(Int(file.percent.rounded())) %").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(coverageColor(file.percent, threshold: threshold)).frame(width: 44, alignment: .trailing)
                    Text("\(file.linesCovered) / \(file.linesTotal) lignes").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .frame(width: 110, alignment: .trailing)
                }
            }
            if report.files.isEmpty {
                Text("Le rapport ne détaille pas les fichiers.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct Bar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(color).frame(width: max(3, geometry.size.width * min(1, value / 100)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

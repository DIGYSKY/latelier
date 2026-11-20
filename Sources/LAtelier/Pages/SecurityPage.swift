import AppKit
import LAtelierCore
import SwiftUI

/// Projets › Sécurité : failles connues (OSV) par gravité, secrets commités, runtimes en fin de vie, hygiène.
struct SecurityPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.projectScope) private var scope
    @ViewState private var severity: Severity?
    @ViewState private var directOnly = false
    @ViewState private var project: URL?
    @ViewState private var open: String?
    @ViewState private var limit = 25
    @ViewState private var allSecrets = false

    var body: some View {
        let store = model.analysis
        PageScaffold(page: .securite, subtitle: subtitle) {
            Button(String(localized: "Analyser maintenant")) { model.scanAnalysis(force: true) }
                .buttonStyle(.secondary)
                .disabled(store.loading)
        } content: {
            if let analysis = store.value {
                content(scope.map { Self.limited(analysis, to: $0) } ?? analysis)
            } else {
                ScanningCard(label: String(localized: "Lecture des dépendances de chaque projet et interrogation d’OSV.dev…"))
            }
        }
        .onAppear {
            focus()
            if store.stale && !store.loading { model.scanAnalysis() }
            if model.packages.stale && !model.packages.scanning { model.scanPackages() }
        }
        .onChange(of: store.stale) { _, stale in if stale && !store.loading { model.scanAnalysis() } }
        .onChange(of: store.finishedAt) { focus() }
        .onChange(of: severity) { limit = 25 }
        .onChange(of: directOnly) { limit = 25 }
        .onChange(of: project) { limit = 25 }
    }

    private var subtitle: String {
        guard let analysis = model.analysis.value else { return String(localized: "Seuls des noms et versions de paquets sont envoyés à OSV.dev") }
        if model.analysis.loading { return String(localized: "Analyse en cours…") }
        let ago = analysis.checkedAt.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(Locale.current))
        return String(localized: "\(analysis.projectCount) projets analysés via OSV.dev · \(ago) · seuls noms et versions de paquets sont envoyés")
    }

    /// Arrivée depuis une news : la faille de cette dépendance est dépliée.
    private func focus() {
        guard let name = model.securityFocus, let analysis = model.analysis.value else { return }
        let packages = analysis.vulnerablePackages.filter { scope == nil || $0.project?.standardizedFileURL == scope?.standardizedFileURL }
        if let package = packages.first(where: { $0.dependency.name == name }) {
            open = package.id
            severity = nil
            directOnly = false
            model.securityFocus = nil
        }
    }

    /// La même analyse, limitée à un projet (page d'un dépôt).
    static func limited(_ analysis: ProjectAnalysis, to project: URL) -> ProjectAnalysis {
        var copy = analysis
        let path = project.standardizedFileURL
        let name = project.lastPathComponent
        copy.manifests = analysis.manifests.filter { $0.project.standardizedFileURL == path }
        copy.vulnerabilities = analysis.vulnerabilities.filter { $0.project?.standardizedFileURL == path }
        copy.secrets = analysis.secrets.filter { $0.project.standardizedFileURL == path }
        copy.endOfLife = analysis.endOfLife.compactMap { pin in
            var pin = pin
            pin.uses = pin.uses.filter { $0.project == name }
            return pin.uses.isEmpty ? nil : pin
        }
        var hygiene = analysis.hygiene
        hygiene.withoutRemote = hygiene.withoutRemote.filter { $0 == name }
        hygiene.withoutLockfile = hygiene.withoutLockfile.filter { $0.project == name }
        hygiene.duplicateLockfiles = hygiene.duplicateLockfiles.filter { $0.project == name }
        hygiene.trackedEnvFiles = hygiene.trackedEnvFiles.filter { $0.project.standardizedFileURL == path }
        copy.hygiene = hygiene
        copy.projectCount = 1
        return copy
    }

    @ViewBuilder
    private func content(_ analysis: ProjectAnalysis) -> some View {
        let names = analysis.projectNames
        let all = analysis.vulnerablePackages
        let scoped = all
            .filter { !directOnly || $0.dependency.direct }
            .filter { scope != nil || project == nil || $0.project == project }
        let visible = scoped.filter { severity == nil || $0.severity == severity }

        severityTiles(scoped)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Vulnérabilités dans les dépendances").font(.system(size: 15, weight: .semibold))
                Text(String(localized: "\(scoped.reduce(0) { $0 + $1.findings.count }) failles dans \(scoped.count) paquets"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                if scope == nil { projectMenu(analysis, names: names) }
                Toggle(String(localized: "Directes seulement"), isOn: $directOnly)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            if !analysis.problems.isEmpty {
                Label(analysis.problems.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.orange)
            }
            if visible.isEmpty {
                Card {
                    EmptyState(symbol: "checkmark.shield", title: all.isEmpty ? String(localized: "Aucune faille connue") : String(localized: "Rien pour ce filtre"),
                               message: all.isEmpty ? String(localized: "OSV.dev ne connaît aucune faille pour les versions utilisées.") : nil)
                }
            }
            LazyVStack(spacing: 8) {
                ForEach(visible.prefix(limit)) { package in
                    VulnerabilityRow(package: package, name: package.project.flatMap { names[$0] } ?? package.projectName,
                                     open: open == package.id) {
                        withAnimation(.snappy(duration: 0.2)) { open = open == package.id ? nil : package.id }
                    }
                }
            }
            HStack(spacing: 10) {
                if visible.count > limit {
                    Button(String(localized: "Afficher \(min(25, visible.count - limit)) de plus")) { limit += 25 }.buttonStyle(.small)
                }
                Spacer()
                let fixable = visible.prefix(limit).filter { DependencyFix.canFix($0) }
                if fixable.count > 1, let plan = DependencyFix.fixPlan(Array(fixable)) {
                    Button(String(localized: "Corriger les \(fixable.count) paquets affichés…")) { model.preview(plan) }
                        .buttonStyle(.small)
                }
            }
        }

        if scope == nil { installedPackages }

        HStack(alignment: .top, spacing: 14) {
            secretsCard(analysis, names: names)
            endOfLifeCard(analysis)
            hygieneCard(analysis)
        }
    }

    // MARK: Tuiles

    private func severityTiles(_ packages: [VulnerablePackage]) -> some View {
        let levels: [Severity] = [.critical, .high, .moderate, .low] + (packages.contains { $0.severity == .unknown } ? [.unknown] : [])
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
            ForEach(levels, id: \.self) { level in
                let selected = severity == level
                Button { severity = selected ? nil : level } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(level.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(level.colors.ink)
                        Text("\(packages.filter { $0.severity == level }.count)").font(.system(size: 24, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(selected ? Theme.raised : Theme.cardFill, in: .rect(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(selected ? level.colors.ink.opacity(0.5) : Theme.cardBorder, lineWidth: selected ? 1.5 : 1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityLabel(String(localized: "\(level.label) : \(packages.filter { $0.severity == level }.count) paquets"))
            }
        }
    }

    private func projectMenu(_ analysis: ProjectAnalysis, names: [URL: String]) -> some View {
        let projects = Set(analysis.vulnerabilities.compactMap(\.project)).sorted { (names[$0] ?? "") < (names[$1] ?? "") }
        return Menu(project.flatMap { names[$0] } ?? String(localized: "Tous les projets")) {
            Button(String(localized: "Tous les projets")) { project = nil }
            Divider()
            ForEach(projects, id: \.self) { url in
                Button("\(names[url] ?? url.lastPathComponent) (\(analysis.vulnerabilityCount(project: url)))") { project = url }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12))
    }

    // MARK: Paquets globaux

    @ViewBuilder
    private var installedPackages: some View {
        let vulnerable = model.packages.packages.filter { !$0.vulnerabilities.isEmpty }
        if !vulnerable.isEmpty {
            Card(title: String(localized: "Paquets installés globalement"), trailing: String(localized: "npm -g et cargo")) {
                ForEach(vulnerable) { package in
                    let worst = package.vulnerabilities.map(\.severity).max() ?? .unknown
                    HStack(spacing: 12) {
                        worst.tag
                        VStack(alignment: .leading, spacing: 2) {
                            Text(package.vulnerabilities[0].summary).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text("\(package.name)@\(package.version) · \(package.vulnerabilities.map(\.displayID).joined(separator: ", "))")
                                .font(.system(size: 12).monospaced()).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer()
                        if package.hasUpdate {
                            Button(String(localized: "Voir la mise à jour")) { model.selection = .majs }.buttonStyle(.small)
                        }
                    }
                }
            }
        }
    }

    // MARK: Cartes du bas

    private func secretsCard(_ analysis: ProjectAnalysis, names: [URL: String]) -> some View {
        let secrets = analysis.secrets
        let red = Color(hex: 0xFF3B30)
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Secrets commités · \(secrets.count)"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(secrets.isEmpty ? Color.primary : Tag.red.0)
            if secrets.isEmpty {
                Text("Aucune clé ni .env sensible dans les fichiers suivis.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ForEach(allSecrets ? secrets : Array(secrets.prefix(5))) { secret in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        (Text(names[secret.project] ?? secret.projectName).bold()
                            + Text(" · ")
                            + Text(secret.file + (secret.line.map { ":\($0)" } ?? "")).font(.system(size: 12).monospaced()))
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Text(secret.isEnvFile ? String(localized: "suivi par git, contient \(secret.detail)") : "\(secret.kind) : \(secret.detail)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if secret.isEnvFile {
                        Button(String(localized: "Ne plus suivre")) { model.preview(SecretScanner.untrackPlan(secret)) }
                            .buttonStyle(.small)
                            .help(String(localized: "git rm --cached, puis ajout au .gitignore (aperçu avant)"))
                    } else {
                        Button("Ouvrir") { NSWorkspace.shared.open(secret.project.appending(path: secret.file)) }
                            .buttonStyle(.small)
                    }
                }
            }
            if secrets.count > 5 {
                Button(allSecrets ? String(localized: "Réduire") : String(localized: "Afficher les \(secrets.count - 5) autres")) { allSecrets.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            if !secrets.isEmpty {
                Text(String(localized: "À faire : changer la clé chez le fournisseur ; elle reste dans l’historique git."))
                    .font(.system(size: 12)).foregroundStyle(Tag.red.0.opacity(0.85))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(secrets.isEmpty ? Theme.cardFill : red.opacity(0.1), in: .rect(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(secrets.isEmpty ? Theme.cardBorder : red.opacity(0.3))
        }
    }

    private func endOfLifeCard(_ analysis: ProjectAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runtimes en fin de vie · \(analysis.endOfLife.count)").font(.system(size: 15, weight: .semibold))
            if analysis.endOfLife.isEmpty {
                Text(String(localized: "Aucun projet ne fixe une version de Node ou Python arrivée en fin de vie."))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ForEach(analysis.endOfLife) { pin in
                (Text("\(pin.language) \(pin.cycle)").bold()
                    + Text(" · \(pin.uses.map(\.project).joined(separator: ", ")) ")
                    + Text("(\(Set(pin.uses.map(\.file)).sorted().joined(separator: ", ")))").foregroundStyle(Tag.orange.0))
                    .font(.system(size: 13))
            }
            Button(String(localized: "Voir les runtimes installés →")) { model.selection = .runtimes }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardBackground(radius: 20)
    }

    private func hygieneCard(_ analysis: ProjectAnalysis) -> some View {
        let hygiene = analysis.hygiene
        return VStack(alignment: .leading, spacing: 8) {
            Text("Hygiène").font(.system(size: 15, weight: .semibold))
            if hygiene.isEmpty {
                Text("Rien à signaler.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            if !hygiene.withoutRemote.isEmpty {
                line((hygiene.withoutRemote.count > 1 ? String(localized: "\(plural(hygiene.withoutRemote.count, String(localized: "dépôt"))) sans remote (non sauvegardés)") : String(localized: "\(plural(hygiene.withoutRemote.count, String(localized: "dépôt"))) sans remote (non sauvegardé)")),
                     help: hygiene.withoutRemote.joined(separator: ", "))
            }
            if !hygiene.withoutLockfile.isEmpty {
                line(String(localized: "\(plural(hygiene.withoutLockfile.count, "projet")) sans lockfile"),
                     help: hygiene.withoutLockfile.map { "\($0.project) (\($0.manifest))" }.joined(separator: ", "))
            }
            if !hygiene.duplicateLockfiles.isEmpty {
                line(String(localized: "\(plural(hygiene.duplicateLockfiles.count, "projet")) avec deux lockfiles"),
                     help: hygiene.duplicateLockfiles.map { "\($0.project) : \($0.files.joined(separator: " + "))" }.joined(separator: "\n"))
            }
            if !hygiene.trackedEnvFiles.isEmpty {
                line((hygiene.trackedEnvFiles.count > 1 ? String(localized: "\(plural(hygiene.trackedEnvFiles.count, "fichier")) .env suivis par git, sans valeur sensible") : String(localized: "\(plural(hygiene.trackedEnvFiles.count, "fichier")) .env suivi par git, sans valeur sensible")),
                     help: hygiene.trackedEnvFiles.map { "\($0.projectName)/\($0.file)" }.joined(separator: "\n"))
            }
            Button(String(localized: "Voir les modifications →")) { model.selection = .modifications }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardBackground(radius: 20)
    }

    private func line(_ text: String, help: String) -> some View {
        Text(text).font(.system(size: 13)).help(help)
    }

    private func plural(_ count: Int, _ word: String) -> String {
        "\(count) \(word)\(count > 1 ? "s" : "")"
    }
}

private struct VulnerabilityRow: View {
    @Environment(AppModel.self) private var model
    let package: VulnerablePackage
    let name: String
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let colors = package.severity.colors
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                package.severity.tag
                Button(action: toggle) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 0) {
                            Text(name).fontWeight(.semibold).foregroundStyle(Theme.accent)
                            Text(" · ")
                            Text("\(package.dependency.name)@\(package.dependency.version) · \(package.headline.vulnerability.displayID)")
                                .font(.system(size: 12).monospaced())
                            if !package.dependency.direct {
                                Text(package.requiredBy.first.map { String(localized: " · sous-paquet de \($0.parent)") } ?? String(localized: " · indirecte"))
                            }
                            if package.dependency.dev { Text(" · dev") }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? String(localized: "déplié") : String(localized: "replié"))
                action
                if let project = package.project {
                    Button("Corriger avec Claude", systemImage: "sparkles") {
                        model.askClaude(project, prompt: ClaudePrompts.fixVulnerability(
                            package: package.dependency.name, version: package.dependency.version, fixed: package.fixedVersion,
                            ids: package.findings.map(\.vulnerability.displayID), manifest: package.file
                        ), context: String(localized: "Faille dans \(package.dependency.name)"))
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.small)
                    .help(String(localized: "Corriger avec Claude : la consigne est montrée avant l’ouverture"))
                }
            }
            if let chain { chain }
            if open { details }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.cardFill, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(colors.fill.opacity(1.6), lineWidth: 1)
        }
    }

    private var title: String {
        let extra = package.findings.count - 1
        return package.headline.vulnerability.summary + (extra > 0 ? (extra > 1 ? String(localized: " (+\(extra) autres)") : String(localized: " (+\(extra) autre)")) : "")
    }

    /// Sous-paquet : qui le demande, et si cet intervalle empêche la correction.
    private var chain: Text? {
        guard !package.dependency.direct, !package.requiredBy.isEmpty else { return nil }
        let parents = package.requiredBy.prefix(3).map(\.label).joined(separator: ", ")
            + (package.requiredBy.count > 3 ? String(localized: " et \(package.requiredBy.count - 3) autres") : "")
        var text = Text(String(localized: "Absent de package.json : installé parce que \(parents) le demande."))
        if let fixed = package.fixedVersion, !package.blockers.isEmpty {
            let blockers = package.blockers.map(\.parent).joined(separator: ", ")
            text = text + Text(" ") + Text(DependencyFix.canForce(package)
                ? String(localized: "Cet intervalle exclut \(fixed) : une simple mise à jour ne change rien tant que \(blockers) ne suit pas, il faut forcer la version.")
                : (DependencyFix.blockedReason(package) ?? String(localized: "Cet intervalle exclut \(fixed).")))
                .foregroundStyle(Tag.orange.0)
        }
        return text.font(.system(size: 12)).foregroundStyle(Theme.muted)
    }

    @ViewBuilder
    private var action: some View {
        if let fixed = package.fixedVersion {
            if DependencyFix.canForce(package) {
                Button(String(localized: "Forcer \(fixed)…")) {
                    if let plan = DependencyFix.fixPlan([package]) { model.preview(plan) }
                }
                .buttonStyle(PillButtonStyle(kind: .smallFilled))
                .disabled(!toolAvailable)
                .help(toolAvailable
                      ? String(localized: "Ajoute la version dans « \(package.manager.flatMap(DependencyOverride.field) ?? "") » de package.json, puis réinstalle. Aperçu avant.")
                      : String(localized: "\(toolName) introuvable sur cette machine"))
            } else if !package.blockers.isEmpty {
                Text(String(localized: "Bloqué par \(package.blockers.map(\.parent).joined(separator: ", "))"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Tag.orange.0)
            } else if DependencyFix.canFix(package) {
                Button(String(localized: "Mettre à jour vers \(fixed)")) {
                    if let plan = DependencyFix.fixPlan([package]) { model.preview(plan) }
                }
                .buttonStyle(PillButtonStyle(kind: .smallFilled))
                .disabled(!toolAvailable)
                .help(toolAvailable
                      ? (DependencyFix.canRelock(package)
                         ? String(localized: "Sous-paquet : son entrée est retirée du yarn.lock, puis « yarn install » prend la version corrigée. Aperçu avant.")
                         : (DependencyFix.fix(package)?.displayString ?? ""))
                      : String(localized: "\(toolName) introuvable sur cette machine"))
            } else {
                Text(String(localized: "Corrigé en \(fixed) · à changer dans \(package.file)"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        } else {
            Text("Pas encore de correctif").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tag.red.0)
        }
    }

    private var toolName: String { DependencyFix.tool(for: package) ?? "" }
    private var toolAvailable: Bool { ToolLocator.standard.locate(toolName) != nil }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(package.findings) { finding in
                HStack(spacing: 10) {
                    Text(finding.severity.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(finding.severity.colors.ink)
                        .frame(width: 70, alignment: .leading)
                    Link(finding.vulnerability.displayID, destination: finding.vulnerability.url)
                        .font(.system(size: 12).monospaced())
                        .frame(width: 170, alignment: .leading)
                    Text(finding.vulnerability.summary).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(finding.fixedVersion.map { String(localized: "corrigé en \($0)") } ?? String(localized: "sans correctif"))
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(Theme.muted)
                }
            }
            Text("\(package.file) · \(package.project?.abbreviatingHome() ?? "")")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .padding(.leading, 4)
    }
}

import LAtelierCore
import SwiftUI

/// News › Pour vous, Cybersécurité, Langages, Favoris : même mise en page que la maquette.
struct NewsPage: View {
    enum Mode { case forYou, cyber, languages, favorites }

    @Environment(AppModel.self) private var model
    let page: Page
    @ViewState private var filter = "main"
    @ViewState private var expanded: String?
    @ViewState private var limit = 60

    private var mode: Mode {
        switch page {
        case .cyber: .cyber
        case .langages: .languages
        case .favoris: .favorites
        default: .forYou
        }
    }

    var body: some View {
        let news = model.news!
        let base = baseItems(news)
        let items = filtered(base, news)
        let unread = base.filter { !news.isRead($0) }.count
        PageScaffold(page: page, subtitle: subtitle(unread: unread, news)) {
            Button {
                Task { await news.refresh() }
            } label: {
                if news.refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(PillButtonStyle(kind: .small))
            .disabled(news.refreshing)
            .help("Relire les sources")
            Button("Tout marquer comme lu") { news.markAllRead(items) }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(items.allSatisfy { news.isRead($0) })
        } content: {
            if mode == .forYou || mode == .cyber, let alert = news.topAlert {
                AlertBanner(item: alert, matches: news.matches[alert.id] ?? [])
            }
            if let message = news.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.orange)
            }
            chips(base, news)
            HStack(alignment: .top, spacing: 14) {
                articles(items, news)
                    .frame(maxWidth: .infinity, alignment: .top)
                SourcesPanel(category: mode)
                    .frame(width: 250)
            }
        }
        .onAppear {
            model.ensureRepos()
            Task { await model.reloadNewsInventory() }
        }
    }

    private func subtitle(unread: Int, _ news: NewsStore) -> String {
        var text = "\(unread) non lue\(unread > 1 ? "s" : "")"
        switch mode {
        case .forYou: text += " · sujets choisis d’après vos projets et paquets"
        case .cyber: text += " · avis de sécurité croisés avec vos dépendances et paquets"
        case .languages: text += " · blogs officiels des langages et outils"
        case .favorites: text = "\(news.favorites.count) article\(news.favorites.count > 1 ? "s" : "") gardé\(news.favorites.count > 1 ? "s" : "")"
        }
        if let last = news.state.lastRefresh { text += " · lu \(FrenchDate.relative(last))" }
        return text
    }

    // MARK: Filtres

    private func baseItems(_ news: NewsStore) -> [NewsItem] {
        switch mode {
        case .forYou: filter == "all" ? news.all : news.forYou
        case .cyber: news.cyber
        case .languages: news.languages + news.general
        case .favorites: news.favorites
        }
    }

    private func filtered(_ items: [NewsItem], _ news: NewsStore) -> [NewsItem] {
        switch (mode, filter) {
        case (_, "main"), (.forYou, _): items
        case (_, "unread"): items.filter { !news.isRead($0) }
        case (.cyber, "mine"): items.filter(news.concerns)
        case (.cyber, "critical"): items.filter(\.isCritical)
        case (.cyber, "kev"): items.filter(\.exploited)
        default: items.filter { $0.topic == filter }
        }
    }

    private func chips(_ items: [NewsItem], _ news: NewsStore) -> some View {
        var list: [(id: String, label: String)] = []
        switch mode {
        case .forYou:
            list = [("main", "Pour vous"), ("all", "Tout")]
        case .cyber:
            list = [("main", "Tous les avis"), ("mine", "Vous concernent"), ("critical", "Critiques"), ("kev", "Activement exploitées")]
        case .languages, .favorites:
            list = [("main", mode == .favorites ? "★ Favoris" : "Tous")]
            var counts: [String: Int] = [:]
            for item in items { counts[item.topic, default: 0] += 1 }
            list += counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { ($0.key, $0.key) }
        }
        if mode != .forYou { list.append(("unread", "Non lues")) }
        return GlassSegments(selection: Binding(get: { filter }, set: { filter = $0; limit = 60 }), items: list, compact: true)
    }

    // MARK: Articles

    @ViewBuilder
    private func articles(_ items: [NewsItem], _ news: NewsStore) -> some View {
        if !news.loaded || (news.state.lastRefresh == nil && news.refreshing) {
            ScanningCard(label: "Lecture des sources…")
        } else if items.isEmpty {
            Card {
                EmptyState(
                    symbol: mode == .favorites ? "star" : "newspaper",
                    title: emptyTitle(news),
                    message: emptyMessage(news)
                )
            }
        } else {
            LazyVStack(spacing: 8) {
                ForEach(items.prefix(limit)) { item in
                    ArticleRow(item: item, expanded: expanded == item.id) {
                        withAnimation(.snappy(duration: 0.2)) { expanded = expanded == item.id ? nil : item.id }
                        news.markRead(item)
                    }
                }
                if items.count > limit {
                    Button("Afficher \(min(60, items.count - limit)) de plus (\(items.count - limit) restants)") { limit += 60 }
                        .buttonStyle(PillButtonStyle(kind: .small))
                        .padding(.top, 4)
                }
            }
        }
    }

    private func emptyTitle(_ news: NewsStore) -> String {
        if news.state.lastRefresh == nil { return "Pas encore de news" }
        return switch mode {
        case .favorites: "Aucun favori"
        case .cyber: filter == "mine" ? "Aucun avis ne vous concerne" : "Aucun avis"
        default: "Rien de nouveau"
        }
    }

    private func emptyMessage(_ news: NewsStore) -> String {
        if news.state.lastRefresh == nil { return "Les sources seront lues dès que la connexion le permet. Le bouton ↻ relance la lecture." }
        return switch mode {
        case .favorites: "L’étoile d’un article le garde ici, même quand il quitte le flux."
        case .cyber: "Les avis qui touchent une dépendance d’un projet ou un paquet installé sont signalés ici."
        default: "Aucun article pour ce filtre. Les sujets suivis se règlent dans News › Sources."
        }
    }
}

/// Couleurs d'étiquette par sujet, comme dans la maquette.
func newsTopicColors(_ topic: String) -> (Color, Color) {
    switch topic {
    case "Cyber": Tag.red
    case "Rust", "Swift": Tag.orange
    case "Go", "Docker", "PostgreSQL", ".NET": Tag.blue
    case "Python", "Ruby": Tag.green
    case "JS / TS", "Java", "Kotlin", "PHP":
        (Color.adaptive(light: NSColor(hex: 0x5C4A00), dark: NSColor(hex: 0xFFE07A)), Color(hex: 0xFFCC00).opacity(0.28))
    default: Tag.grey
    }
}

// MARK: - Bandeau d'alerte

private struct AlertBanner: View {
    @Environment(AppModel.self) private var model
    let item: NewsItem
    let matches: [NewsMatch]

    var body: some View {
        let match = matches.first { $0.confirmed } ?? matches.first
        Button {
            model.news.markRead(item)
            if let match { model.fix(match) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Tag.red.0)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vous êtes concerné : \(item.title)")
                        .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text(detail(match))
                        .font(.system(size: 13)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(match.map(AppModel.fixLabel) ?? "Voir →")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Tag.red.0)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color(hex: 0xFF3B30).opacity(0.14), in: .rect(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: 0xFF3B30).opacity(0.35)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func detail(_ match: NewsMatch?) -> String {
        guard let match else { return "" }
        var text = "\(match.package) \(match.version ?? "")"
        if let project = match.project { text += " dans \(model.projectName(project))" } else { text += " · \(match.place)" }
        if let fixed = match.fixed { text += ". Corrigé en \(fixed)." }
        let others = Set(matches.compactMap(\.project)).count - (match.project == nil ? 0 : 1)
        if others > 0 { text += " Et \(others) autre\(others > 1 ? "s" : "") projet\(others > 1 ? "s" : "")." }
        return text
    }
}

// MARK: - Article

private struct ArticleRow: View {
    @Environment(AppModel.self) private var model
    let item: NewsItem
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let news = model.news!
        let read = news.isRead(item)
        let matches = news.matches[item.id] ?? []
        let confirmed = matches.contains(where: \.confirmed)
        let starred = news.isStarred(item)
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(read ? Color.clear : Theme.accent)
                .frame(width: 8, height: 8)
                .padding(.top, 7)
                .accessibilityLabel(read ? "" : "Non lu")
            VStack(alignment: .leading, spacing: 4) {
                meta(matches: matches, confirmed: confirmed)
                Button(action: toggle) {
                    Text(item.title)
                        .font(.system(size: 15, weight: read ? .medium : .bold))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "déplié" : "replié")
                if !expanded, let first = matches.first(where: \.confirmed) ?? matches.first {
                    HStack(spacing: 8) {
                        Text("\(first.package) \(first.version ?? "")" + (first.project.map { " · \(model.projectName($0))" } ?? " · \(first.place)")
                             + (matches.count > 1 ? " et \(matches.count - 1) autre\(matches.count > 2 ? "s" : "")" : ""))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        Button(AppModel.fixLabel(first)) {
                            model.news.markRead(item)
                            model.fix(first)
                        }
                        .buttonStyle(PillButtonStyle(kind: first.confirmed ? .smallFilled : .small))
                    }
                }
                if expanded { details(matches: matches) }
            }
            Button { news.toggleStar(item) } label: {
                Image(systemName: starred ? "star.fill" : "star")
                    .font(.system(size: 16))
                    .foregroundStyle(starred ? Color(hex: 0xE8A400) : Theme.muted)
                    .frame(width: 36, height: 36)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(starred ? "Retirer des favoris" : "Ajouter aux favoris")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(matches.isEmpty || read ? Theme.cardFill : Theme.raised, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.cardBorder))
        .contextMenu {
            Button(read ? "Marquer comme non lu" : "Marquer comme lu") {
                if read { model.news.markUnread(item) } else { model.news.markRead(item) }
            }
            if let link = item.link {
                Link("Ouvrir dans le navigateur", destination: link)
                Button("Copier le lien") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                }
            }
        }
    }

    private func meta(matches: [NewsMatch], confirmed: Bool) -> some View {
        let colors = newsTopicColors(item.topic)
        return HStack(spacing: 8) {
            Tag(text: item.topic, foreground: colors.0, background: colors.1)
            Text(model.news.sourceName(item.sourceID))
            Text("·")
            Text(FrenchDate.relative(item.date))
            if let severity = item.severity, item.category == .cyber {
                Text("·")
                Text(item.exploited ? "exploitée" : severityLabel(severity))
                    .fontWeight(.semibold)
                    .foregroundStyle(item.isSevere ? Tag.red.0 : Theme.muted)
            }
            if !matches.isEmpty {
                Text(confirmed ? "· Vous concerne" : "· Peut vous concerner")
                    .fontWeight(.bold)
                    .foregroundStyle(confirmed ? Tag.red.0 : Tag.orange.0)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
        .lineLimit(1)
    }

    private func severityLabel(_ severity: String) -> String {
        switch severity {
        case "critical": "critique"
        case "high": "élevée"
        case "moderate", "medium": "moyenne"
        case "low": "faible"
        default: severity
        }
    }

    @ViewBuilder
    private func details(matches: [NewsMatch]) -> some View {
        if !item.summary.isEmpty {
            Text(item.summary)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.8))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(matches.contains(where: \.confirmed) ? "Présent sur cette machine" : "Cité dans l’avis, à vérifier")
                    .font(.system(size: 12, weight: .semibold))
                ForEach(matches.prefix(8)) { match in
                    MatchRow(match: match)
                }
                if matches.count > 8 {
                    Text("et \(matches.count - 8) autres").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))
        }
        HStack(spacing: 14) {
            if let link = item.link {
                Link("Lire l’article complet ↗", destination: link)
                    .font(.system(size: 13, weight: .semibold))
            }
            if let cve = item.cve {
                Text(cve).font(.system(size: 12).monospaced()).foregroundStyle(Theme.muted).textSelection(.enabled)
            }
        }
    }
}

private struct MatchRow: View {
    @Environment(AppModel.self) private var model
    let match: NewsMatch

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: match.project != nil ? "folder" : "shippingbox")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            Text(label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            if let fixed = match.fixed {
                Text("corrigé en \(fixed)").font(.system(size: 12)).foregroundStyle(Tag.green.0)
            }
            Spacer(minLength: 4)
            Button(AppModel.fixLabel(match)) { model.fix(match) }
                .buttonStyle(PillButtonStyle(kind: match.confirmed ? .smallFilled : .small))
            if let project = match.project { OpenInMenu(project: project) }
        }
    }

    private var label: String {
        var text = "\(match.package) \(match.version ?? "")"
        if let project = match.project {
            text += " · \(model.projectName(project)) (\(match.place)\(match.direct ? "" : ", indirecte"))"
        } else {
            text += " · \(match.place)"
        }
        return text
    }
}

// MARK: - Panneau des sources

private struct SourcesPanel: View {
    @Environment(AppModel.self) private var model
    let category: NewsPage.Mode

    var body: some View {
        let news = model.news!
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources").font(.system(size: 15, weight: .semibold)).padding(.bottom, 6)
            ForEach(sources(news)) { source in
                let status = news.state.status[source.id]
                Toggle(isOn: Binding(get: { news.isEnabled(source) }, set: { news.setEnabled(source, $0) })) {
                    HStack(spacing: 6) {
                        Text(source.name).font(.system(size: 13)).lineLimit(1)
                        if status?.error != nil && news.isEnabled(source) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Tag.red.0)
                                .help(status?.error ?? "")
                        }
                        Spacer(minLength: 4)
                        Text(source.category.label).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
                .toggleStyle(.checkbox)
                .frame(minHeight: 30)
            }
            Button("+ Ajouter un flux RSS") { model.selection = .sources }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, minHeight: 34)
                .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Theme.hairline.opacity(2.5)))
                .padding(.top, 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .cardBackground()
    }

    private func sources(_ news: NewsStore) -> [NewsSource] {
        switch category {
        case .cyber: news.sources.filter { $0.category == .cyber }
        case .languages: news.sources.filter { $0.category != .cyber }
        case .forYou, .favorites:
            // Actives d'abord, puis les autres.
            news.sources.filter(news.isEnabled) + news.sources.filter { !news.isEnabled($0) && $0.category != .langage }
        }
    }
}

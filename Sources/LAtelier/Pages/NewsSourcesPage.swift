import LAtelierCore
import SwiftUI

/// News › Sources : sujets suivis (automatiques ou ajoutés) et état de chaque flux.
struct NewsSourcesPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var newTopic = ""
    @ViewState private var address = ""
    @ViewState private var adding = false
    @ViewState private var addError: String?

    var body: some View {
        let news = model.news!
        PageScaffold(page: .sources, subtitle: String(localized: "D’où viennent les news, et quels sujets suivre")) {
            Button {
                Task { await news.refresh() }
            } label: {
                if news.refreshing { ProgressView().controlSize(.small) } else { Label("Tout relire", systemImage: "arrow.clockwise") }
            }
            .buttonStyle(PillButtonStyle(kind: .secondary))
            .disabled(news.refreshing)
        } content: {
            topics(news)
            feeds(news)
            Text(String(localized: "Seules des requêtes de lecture partent vers ces adresses : aucun nom de projet, chemin ni code n’est envoyé. Les avis GitHub sont lus sans compte (60 requêtes par heure)."))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .onAppear {
            model.ensureRepos()
            Task { await model.reloadNewsInventory() }
        }
    }

    // MARK: Sujets

    private func topics(_ news: NewsStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sujets suivis").font(.system(size: 15, weight: .semibold))
            FlowLayout(spacing: 8) {
                ForEach(news.followed) { topic in
                    HStack(spacing: 6) {
                        Text(topic.name).font(.system(size: 13))
                        if topic.auto {
                            Text("auto" + (topic.reason.map { " · \($0)" } ?? ""))
                                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        Button { news.removeTopic(topic) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 22, height: 22)
                                .background(Theme.hairline, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Retirer \(topic.name)"))
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 5)
                    .frame(minHeight: 32)
                    .background(Theme.raised, in: .capsule)
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                }
                TextField(String(localized: "+ Ajouter un sujet (ex. Kubernetes)"), text: $newTopic)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(width: 240, height: 32)
                    .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Theme.muted.opacity(0.5)))
                    .onSubmit {
                        news.addTopic(newTopic)
                        newTopic = ""
                    }
            }
            let hidden = news.state.hiddenTopics.sorted()
            HStack(spacing: 6) {
                Text(String(localized: "Les sujets « auto » sont déduits de vos projets et paquets ; un sujet ajouté à la main est cherché dans les titres et résumés."))
                if !hidden.isEmpty {
                    Text(String(localized: "Retirés : \(hidden.joined(separator: ", "))."))
                    Button(String(localized: "Rétablir")) { for topic in hidden { news.addTopic(topic) } }
                        .buttonStyle(.link)
                }
            }
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
            if !news.inventoryReady {
                Label("Lecture des projets et paquets…", systemImage: "hourglass").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    // MARK: Flux

    private func feeds(_ news: NewsStore) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Flux et API").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let addError {
                    Text(addError).font(.system(size: 12)).foregroundStyle(Tag.red.0).lineLimit(1)
                }
                TextField("https://exemple.dev/feed.xml", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(width: 300, height: 34)
                    .background(Theme.raised, in: .capsule)
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                    .onSubmit(add)
                Button(action: add) {
                    if adding { ProgressView().controlSize(.small) } else { Text(String(localized: "Ajouter")) }
                }
                .buttonStyle(PillButtonStyle(kind: .smallFilled))
                .disabled(adding || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.raised.opacity(0.4))

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    Text(String(localized: "Actif"))
                    Text("Source")
                    Text(String(localized: "Catégorie"))
                    Text("Type")
                    Text(String(localized: "Dernière lecture"))
                    Text(String(localized: "État"))
                    Color.clear.frame(width: 1, height: 1)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)
                .padding(.vertical, 8)
                ForEach(news.sources) { source in
                    Divider().gridCellColumns(7).opacity(0.6)
                    row(source, news)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
        .cardBackground()
    }

    private func row(_ source: NewsSource, _ news: NewsStore) -> some View {
        let on = news.isEnabled(source)
        let status = news.state.status[source.id]
        let state = stateTag(on: on, status: status)
        return GridRow {
            Toggle("", isOn: Binding(get: { on }, set: { news.setEnabled(source, $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(String(localized: "Activer \(source.name)"))
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name).font(.system(size: 13, weight: .semibold))
                Text(source.displayURL).font(.system(size: 11).monospaced()).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(source.category.label + (source.topic.map { source.category == .langage ? " · \($0)" : "" } ?? ""))
                .font(.system(size: 13))
            Text(kind(source, status)).font(.system(size: 12))
            Text(lastRead(status)).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Tag(text: state.0, foreground: state.1.0, background: state.1.1)
                .help(status?.error ?? "")
            if source.builtIn {
                Color.clear.frame(width: 22, height: 1)
            } else {
                Button { news.removeSource(source) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Retirer ce flux (ses favoris sont gardés)"))
                .accessibilityLabel(String(localized: "Retirer \(source.name)"))
            }
        }
        .padding(.vertical, 7)
        .opacity(on ? 1 : 0.55)
    }

    private func kind(_ source: NewsSource, _ status: NewsSourceStatus?) -> String {
        switch source.kind {
        case .githubAdvisories: "API"
        case .cisaKEV: "JSON"
        case .feed: status?.format ?? "RSS / Atom"
        }
    }

    private func lastRead(_ status: NewsSourceStatus?) -> String {
        guard let status, let attempt = status.lastAttempt else { return "—" }
        if status.error != nil, status.lastSuccess != attempt { return String(localized: "échec \(FrenchDate.relative(attempt))") }
        return FrenchDate.relative(attempt) + (status.count > 0 ? " · \(status.count)" : "")
    }

    private func stateTag(on: Bool, status: NewsSourceStatus?) -> (String, (Color, Color)) {
        if !on { return (String(localized: "Désactivée"), Tag.grey) }
        guard let status, status.lastAttempt != nil else { return (String(localized: "Pas encore lue"), Tag.grey) }
        if let error = status.error {
            return (status.lastSuccess == status.lastAttempt ? String(localized: "Partielle") : error, status.lastSuccess == status.lastAttempt ? Tag.orange : Tag.red)
        }
        return ("OK", Tag.green)
    }

    private func add() {
        let text = address
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !adding else { return }
        adding = true
        addError = nil
        Task {
            let error = await model.news.addSource(text)
            adding = false
            addError = error
            if error == nil { address = "" }
        }
    }
}

/// Disposition en lignes qui passent à la ligne (pastilles de sujets).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty && current.width + spacing + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

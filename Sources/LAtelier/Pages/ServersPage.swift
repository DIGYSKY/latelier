import AppKit
import LAtelierCore
import SwiftUI

/// Serveurs : les connexions de ~/.ssh/config, puis une page par serveur (fichiers, configuration).
struct ServersPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ssh = model.ssh
        Group {
            if let alias = ssh.openHost, let host = ssh.host(alias) {
                ServerPage(host: host)
            } else {
                ServerListPage()
            }
        }
        .sheet(item: $ssh.draft) { draft in
            HostEditorSheet(draft: draft)
        }
        .onAppear { model.ssh.reload() }
    }
}

// MARK: - Liste

private struct ServerListPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var query = ""

    var body: some View {
        let ssh = model.ssh
        PageScaffold(title: "Serveurs", subtitle: subtitle) {
            SearchField(prompt: "Rechercher un serveur", text: $query).frame(maxWidth: 260)
            Button("Ajouter un serveur", systemImage: "plus") { ssh.draft = HostDraft() }
                .buttonStyle(.primary)
                .fixedSize()
        } content: {
            if ssh.hosts.isEmpty {
                Card {
                    VStack(spacing: 14) {
                        EmptyState(symbol: "externaldrive.connected.to.line.below", title: "Aucune connexion enregistrée",
                                   message: "Les connexions viennent de ~/.ssh/config. Ajoutez votre premier serveur : il sera disponible ici, dans le terminal (ssh nom) et dans tous vos outils.")
                        Button("Ajouter un serveur", systemImage: "plus") { ssh.draft = HostDraft() }.buttonStyle(.primary)
                    }
                    .padding(.bottom, 16)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                    ForEach(visible) { host in
                        HostCard(host: host)
                    }
                }
                if visible.isEmpty {
                    Card { EmptyState(symbol: "magnifyingglass", title: "Aucun serveur ne correspond") }
                }
                footnote
            }
        }
    }

    private var visible: [SSHHost] {
        let q = query.lowercased()
        return model.ssh.hosts.filter { host in
            q.isEmpty || ([host.alias, host.hostName ?? "", host.user ?? "", host.note ?? ""] + host.otherAliases).contains { $0.lowercased().contains(q) }
        }
    }

    private var subtitle: String {
        let count = model.ssh.hosts.count
        return count == 0 ? "Connexions SSH de ~/.ssh/config" : "\(count) connexion\(count > 1 ? "s" : "") dans ~/.ssh/config"
    }

    private var footnote: some View {
        let config = model.ssh.config
        var parts: [String] = []
        if !config.wildcardPatterns.isEmpty {
            parts.append("Réglages communs : Host \(config.wildcardPatterns.joined(separator: ", "))")
        }
        if !config.includes.isEmpty {
            parts.append("Fichiers inclus (lecture seule) : \(config.includes.map { $0.abbreviatingHome() }.joined(separator: ", "))")
        }
        return HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Theme.muted)
            Text(parts.isEmpty ? "Chaque modification passe par un aperçu ; l’ancienne version de ~/.ssh/config va à la corbeille." : parts.joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
            Button("Ouvrir ~/.ssh/config") { NSWorkspace.shared.activateFileViewerSelecting([config.url]) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.link)
        }
        .padding(.horizontal, 4)
    }
}

/// Couleur stable par serveur (dérivée du nom).
private func hostColor(_ alias: String) -> Color {
    let palette: [UInt32] = [0x0A6CDB, 0x6E4BD8, 0x00879E, 0x1E8A45, 0xC2410C, 0xB4237A, 0x4F46E5, 0x0E7490]
    let sum = alias.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    return Color(hex: palette[sum % palette.count])
}

private struct HostAvatar: View {
    let alias: String
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: "server.rack")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [hostColor(alias).opacity(0.85), hostColor(alias)], startPoint: .top, endPoint: .bottom),
                in: .rect(cornerRadius: size * 0.28, style: .continuous)
            )
            .shadow(color: hostColor(alias).opacity(0.3), radius: 5, y: 3)
    }
}

/// Point d'état (en ligne / en échec / test en cours).
struct HostStatusDot: View {
    let status: HostStatus?

    var body: some View {
        switch status {
        case .checking: ProgressView().controlSize(.mini)
        case .online: Circle().fill(Theme.green).frame(width: 8, height: 8).help("Connexion réussie")
        case .failed(let title, _): Circle().fill(Theme.red).frame(width: 8, height: 8).help(title)
        case nil: EmptyView()
        }
    }
}

private struct HostCard: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost
    @ViewState private var hovering = false

    var body: some View {
        let ssh = model.ssh
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                HostAvatar(alias: host.alias)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(host.alias).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        HostStatusDot(status: ssh.status[host.alias])
                    }
                    Text(host.destination).font(.system(size: 12).monospaced()).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                HostMenu(host: host)
            }
            if let note = host.note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            HStack(spacing: 6) {
                if let key = host.identityFile {
                    Tag(text: "🔑 " + (key as NSString).lastPathComponent, foreground: Tag.grey.0, background: Tag.grey.1)
                }
                if let jump = host.proxyJump {
                    Tag(text: "via \(jump)", foreground: Tag.blue.0, background: Tag.blue.1)
                }
                if !host.otherAliases.isEmpty {
                    Tag(text: "aussi : " + host.otherAliases.joined(separator: ", "), foreground: Tag.grey.0, background: Tag.grey.1)
                }
                if !host.editable {
                    Tag(text: "lecture seule", foreground: Tag.orange.0, background: Tag.orange.1)
                }
            }
            HStack(spacing: 8) {
                TerminalButton(alias: host.alias)
                Button("Fichiers", systemImage: "folder") { ssh.open(host.alias, tab: .files) }
                    .buttonStyle(.small)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(radius: 20)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.accent.opacity(hovering ? 0.35 : 0), lineWidth: 1.5))
        .contentShape(.rect)
        .onTapGesture { ssh.open(host.alias) }
        .onHover { hovering = $0 }
        .contextMenu { HostMenuItems(host: host) }
    }
}

/// « Terminal » : ouvre la connexion dans le terminal choisi (Réglages), ou un autre.
struct TerminalButton: View {
    @Environment(AppModel.self) private var model
    let alias: String
    var directory: String?
    var filled = true

    var body: some View {
        Menu {
            ForEach(TerminalApp.installed, id: \.self) { terminal in
                Button("Ouvrir dans \(terminal.label)") { open(terminal) }
            }
            Divider()
            Button("Copier la commande") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SSHCommands(alias: alias).interactive(directory: directory).map(ShellQuote.quote).joined(separator: " "), forType: .string)
            }
        } label: {
            Label("Terminal", systemImage: "terminal")
        } primaryAction: {
            open(nil)
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle(kind: filled ? .smallFilled : .small))
        .fixedSize()
        .help("Se connecter dans \(model.preferences.terminal.label)")
    }

    private func open(_ terminal: TerminalApp?) {
        if let error = model.ssh.openTerminal(alias, directory: directory, terminal: terminal) { model.launchError = error }
    }
}

private struct HostMenu: View {
    let host: SSHHost

    var body: some View {
        Menu {
            HostMenuItems(host: host)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(BareButtonStyle())
        .fixedSize()
    }
}

private struct HostMenuItems: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost

    var body: some View {
        let ssh = model.ssh
        Button("Moniteur", systemImage: "waveform.path.ecg.rectangle") { ssh.open(host.alias, tab: .monitor) }
        Button("Ouvrir les fichiers", systemImage: "folder") { ssh.open(host.alias, tab: .files) }
        Button("Tester la connexion", systemImage: "bolt.horizontal") { ssh.test(host.alias) }
        Button("Installer ma clé sur le serveur…", systemImage: "key") {
            if let error = ssh.installKey(host.alias) { model.launchError = error }
        }
        Button("Copier « ssh \(host.alias) »", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("ssh \(host.alias)", forType: .string)
        }
        Divider()
        if host.editable {
            Button("Modifier…", systemImage: "pencil") { ssh.draft = HostDraft(host) }
        }
        Button("Dupliquer…", systemImage: "plus.square.on.square") { ssh.draft = HostDraft(host, duplicate: true) }
        if host.editable {
            Divider()
            Button("Supprimer la connexion…", systemImage: "trash", role: .destructive) { ssh.delete(host.alias) }
        }
    }
}

// MARK: - Page d'un serveur

private struct ServerPage: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost

    var body: some View {
        @Bindable var ssh = model.ssh
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button { ssh.close() } label: { Label("Serveurs", systemImage: "chevron.left") }
                        .buttonStyle(PillButtonStyle(kind: .small))
                    HostAvatar(alias: host.alias, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(host.alias).font(.system(size: 24, weight: .bold))
                            statusLabel
                        }
                        Text(host.destination + (host.proxyJump.map { " · via \($0)" } ?? "") + (host.note.map { " · \($0)" } ?? ""))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    TerminalButton(alias: host.alias, directory: ssh.browser?.path)
                    HostMenu(host: host)
                }
                GlassSegments(selection: $ssh.tab, items: ServerTab.allCases.map { ($0, $0.label) }).fixedSize()
            }
            .padding(.leading, 22)
            .padding(.trailing, 30)
            .padding(.top, 6)
            .padding(.bottom, 12)
            switch ssh.tab {
            case .monitor:
                if let monitor = ssh.monitor, monitor.alias == host.alias {
                    RemoteMonitorView(monitor: monitor, host: host)
                }
            case .files:
                if let browser = ssh.browser, browser.alias == host.alias {
                    RemoteFilesView(browser: browser, host: host)
                }
            case .configuration:
                ScrollView {
                    HostConfigurationView(host: host)
                        .padding(.leading, 22).padding(.trailing, 30).padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch model.ssh.status[host.alias] {
        case .checking:
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("connexion…") }
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        case .online:
            Label("connecté", systemImage: "circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.green)
                .labelStyle(DotLabelStyle())
        case .failed(let title, _):
            Label(title, systemImage: "circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.red)
                .labelStyle(DotLabelStyle())
        case nil:
            EmptyView()
        }
    }
}

private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}

/// Onglet Configuration : ce qui est écrit, et ce que ssh utilisera vraiment (`ssh -G`).
private struct HostConfigurationView: View {
    @Environment(AppModel.self) private var model
    let host: SSHHost

    var body: some View {
        let ssh = model.ssh
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "Connexion") {
                fact("Nom", ([host.alias] + host.otherAliases).joined(separator: ", "))
                fact("Adresse", host.hostName ?? "—")
                fact("Utilisateur", host.user ?? "par défaut (\(ssh.effective["user"] ?? NSUserName()))")
                fact("Port", host.port.map(String.init) ?? "22")
                fact("Clé", host.identityFile ?? "clés par défaut et agent SSH")
                if let jump = host.proxyJump { fact("Rebond", jump) }
                ForEach(host.extra, id: \.self) { option in fact(option.key, option.value) }
                HStack(spacing: 8) {
                    if host.editable {
                        Button("Modifier…", systemImage: "pencil") { ssh.draft = HostDraft(host) }.buttonStyle(.small)
                    }
                    Button("Tester la connexion", systemImage: "bolt.horizontal") { ssh.test(host.alias) }.buttonStyle(.small)
                    Button("Installer ma clé…", systemImage: "key") {
                        if let error = ssh.installKey(host.alias) { model.launchError = error }
                    }
                    .buttonStyle(.small)
                    .help("Lance ssh-copy-id dans le terminal : le mot de passe est demandé une fois, ensuite la clé suffit.")
                }
                .padding(.top, 4)
            }
            if case .failed(let title, let advice) = ssh.status[host.alias] {
                Card {
                    Label(title, systemImage: "exclamationmark.triangle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.red)
                    Text(advice).font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            if let block = ssh.config.blockText(host.alias) ?? (host.editable ? nil : host.render().joined(separator: "\n")) {
                Card(title: "Dans ~/.ssh/config", trailing: host.editable ? nil : host.source.abbreviatingHome()) {
                    Text(block).font(.system(size: 12).monospaced()).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.hairline.opacity(0.5), in: .rect(cornerRadius: 10))
                }
            }
            if !ssh.effective.isEmpty {
                Card(title: "Ce que ssh utilisera", trailing: "ssh -G \(host.alias)") {
                    ForEach(["hostname", "user", "port", "identityfile", "proxyjump", "forwardagent", "stricthostkeychecking", "serveraliveinterval"], id: \.self) { key in
                        if let value = ssh.effective[key] { fact(key, value) }
                    }
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.muted).frame(width: 160, alignment: .leading)
            Text(value).font(.system(size: 13).monospaced()).textSelection(.enabled)
            Spacer()
        }
    }
}

// MARK: - Ajouter / modifier

private struct HostEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft: HostDraft
    @ViewState private var showAdvanced = false

    init(draft: HostDraft) {
        _draft = ViewState(wrappedValue: draft)
    }

    var body: some View {
        let ssh = model.ssh
        let problems = ssh.problems(draft)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HostAvatar(alias: draft.alias.isEmpty ? "?" : draft.alias, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.original == nil ? "Nouveau serveur" : "Modifier « \(draft.original!) »").font(.system(size: 18, weight: .bold))
                    Text("Enregistré dans ~/.ssh/config : utilisable aussi avec « ssh \(draft.alias.isEmpty ? "nom" : draft.alias) ».")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            .padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Nom", "prod, nas, vps…", text: $draft.alias, help: "Le nom court à taper après ssh.")
                    field("Adresse", "exemple.fr ou 203.0.113.10", text: $draft.hostName)
                    HStack(spacing: 12) {
                        field("Utilisateur", NSUserName(), text: $draft.user)
                        field("Port", "22", text: $draft.port).frame(width: 110)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Clé").font(.system(size: 12, weight: .semibold))
                        HStack(spacing: 6) {
                            TextField("clés par défaut et agent SSH", text: $draft.identityFile).textFieldStyle(.roundedBorder)
                            Menu("Choisir") {
                                Button("Clés par défaut") { draft.identityFile = "" }
                                if !ssh.keys.isEmpty { Divider() }
                                ForEach(ssh.keys, id: \.self) { key in Button(key) { draft.identityFile = key } }
                            }
                            .fixedSize()
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Passer par (rebond)").font(.system(size: 12, weight: .semibold))
                        HStack(spacing: 6) {
                            TextField("aucun", text: $draft.proxyJump).textFieldStyle(.roundedBorder)
                            Menu("Choisir") {
                                Button("Aucun") { draft.proxyJump = "" }
                                Divider()
                                ForEach(ssh.hosts.filter { $0.alias != draft.original }) { host in Button(host.alias) { draft.proxyJump = host.alias } }
                            }
                            .fixedSize()
                        }
                        Text("Un serveur intermédiaire (bastion) par lequel passer, s’il en faut un.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    field("Note", "facultatif : à quoi sert ce serveur", text: $draft.note)
                    DisclosureGroup("Options avancées", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 5) {
                            TextEditor(text: $draft.extra)
                                .font(.system(size: 12).monospaced())
                                .frame(minHeight: 80)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(Theme.hairline.opacity(0.5), in: .rect(cornerRadius: 8))
                            Text("Une option par ligne, par exemple « ForwardAgent yes » ou « LocalForward 5433 localhost:5432 ».")
                                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        .padding(.top, 6)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Sera écrit").font(.system(size: 12, weight: .semibold))
                        Text(draft.host.render().joined(separator: "\n"))
                            .font(.system(size: 12).monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Theme.hairline.opacity(0.5), in: .rect(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 20)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let first = problems.first, !draft.alias.isEmpty || !draft.hostName.isEmpty {
                    Label(first, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Theme.orange)
                }
                HStack {
                    Spacer()
                    Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.small)
                    Button(draft.original == nil ? "Ajouter…" : "Enregistrer…") { ssh.save(draft) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(PillButtonStyle(kind: .smallFilled))
                        .disabled(!problems.isEmpty)
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 640)
        .background { Backdrop(glass: model.preferences.glass) }
        .onAppear { showAdvanced = !draft.extra.isEmpty }
    }

    private func field(_ label: String, _ prompt: String, text: Binding<String>, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12, weight: .semibold))
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
            if let help { Text(help).font(.system(size: 11)).foregroundStyle(Theme.muted) }
        }
    }
}

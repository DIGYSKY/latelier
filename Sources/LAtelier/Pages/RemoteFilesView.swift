import AppKit
import LAtelierCore
import SwiftUI
import UniformTypeIdentifiers

/// Explorateur d'un serveur, façon stockage en ligne : fil d'Ariane, grille ou liste,
/// glisser-déposer pour importer, barre d'actions sur la sélection, transferts en bas.
struct RemoteFilesView: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: RemoteBrowser
    let host: SSHHost
    @ViewState private var dropTargeted = false
    @ViewState private var renaming: RemoteFile?
    @ViewState private var newName = ""
    @ViewState private var creatingFolder = false
    @ViewState private var folderName = ""
    @ViewState private var confirmPermanent: [RemoteFile]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let edit = browser.editing {
                RemoteEditorView(browser: browser, edit: edit)
            } else {
                if browser.path != nil { toolbar }
                banners
                content
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 30)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nouveau nom", text: $newName)
            Button("Annuler", role: .cancel) { renaming = nil }
            Button("Renommer") {
                if let file = renaming { browser.rename(file, to: newName.trimmingCharacters(in: .whitespaces)) }
                renaming = nil
            }
        } message: {
            Text("Le nom ne doit pas déjà exister dans ce dossier : rien n’est jamais remplacé.")
        }
        .alert("Nouveau dossier", isPresented: $creatingFolder) {
            TextField("Nom du dossier", text: $folderName)
            Button("Annuler", role: .cancel) {}
            Button("Créer") { browser.makeDirectory(folderName.trimmingCharacters(in: .whitespaces)) }
        } message: {
            Text("Dans \(browser.path ?? "le dossier courant").")
        }
        .alert("Supprimer définitivement ?", isPresented: Binding(get: { confirmPermanent != nil }, set: { if !$0 { confirmPermanent = nil } })) {
            Button("Annuler", role: .cancel) { confirmPermanent = nil }
            Button("Voir l’aperçu…", role: .destructive) {
                if let files = confirmPermanent { browser.deletePermanently(files) }
                confirmPermanent = nil
            }
        } message: {
            Text("Sans passer par la corbeille du serveur. Préférez « Supprimer », qui déplace dans ~/.latelier-corbeille.")
        }
        .onAppear { browser.start() }
        .onDisappear { if model.ssh.openHost == nil { browser.stop() } }
    }

    // MARK: Barre d'outils

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                roundButton("chevron.left", "Précédent") { browser.goBack() }.disabled(!browser.canGoBack)
                roundButton("arrow.up", "Dossier parent") { browser.goUp() }.disabled(browser.path == nil || browser.path == "/")
                roundButton("house", "Dossier personnel") { browser.goHome() }.disabled(browser.home == nil)
            }
            breadcrumbs
            Spacer(minLength: 8)
            if browser.loading { ProgressView().controlSize(.small) }
            roundButton(browser.showHidden ? "eye" : "eye.slash", browser.showHidden ? "Masquer les fichiers cachés" : "Afficher les fichiers cachés") {
                browser.showHidden.toggle()
            }
            roundButton("arrow.clockwise", "Actualiser") { browser.refresh() }
            GlassSegments(selection: $browser.layout, items: [(.grid, "Grille"), (.list, "Liste")], compact: true).fixedSize()
            Button("Nouveau dossier", systemImage: "folder.badge.plus") { folderName = ""; creatingFolder = true }
                .buttonStyle(.small).fixedSize().disabled(browser.path == nil)
            Button("Importer", systemImage: "square.and.arrow.up") { browser.chooseUploads() }
                .buttonStyle(PillButtonStyle(kind: .smallFilled)).fixedSize().disabled(browser.path == nil)
                .help("Envoyer des fichiers ou des dossiers du Mac dans ce dossier (ou glissez-les dans la fenêtre)")
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                if let path = browser.path {
                    let crumbs = RemotePath.crumbs(path)
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        Button {
                            browser.load(crumb.path)
                        } label: {
                            Text(index == 0 ? host.alias : crumb.name)
                                .font(.system(size: 13, weight: index == crumbs.count - 1 ? .semibold : .regular))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(index == crumbs.count - 1 ? Theme.raised : .clear, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .dropDestination(for: URL.self) { urls, _ in browser.upload(urls, into: crumb.path); return true }
                    }
                }
            }
            .padding(4)
        }
        .scrollIndicators(.never)
        .background(Theme.cardFill, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
        .frame(maxWidth: 520)
    }

    private func roundButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Theme.raised, in: .circle)
                .overlay(Circle().strokeBorder(Theme.hairline))
                .contentShape(.circle)
        }
        .buttonStyle(BareButtonStyle())
        .help(help)
    }

    // MARK: Bandeaux

    @ViewBuilder
    private var banners: some View {
        if let notice = browser.notice {
            banner(notice, symbol: "info.circle.fill", color: Theme.accent) {
                Button("OK") { browser.notice = nil }.buttonStyle(.small)
            }
        }
        let _ = browser.tick
        ForEach(browser.pendingExternal) { edit in
            banner("« \(edit.file.name) » a été modifié dans votre éditeur.", symbol: "pencil.circle.fill", color: Theme.orange) {
                Button("Ne plus suivre") { browser.stopWatching(edit) }.buttonStyle(.small)
                Button("Envoyer sur le serveur…") { browser.save(edit) }.buttonStyle(PillButtonStyle(kind: .smallFilled))
            }
        }
    }

    private func banner<Actions: View>(_ text: String, symbol: String, color: Color, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.system(size: 13)).lineLimit(3)
            Spacer()
            actions()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(color.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.25)))
    }

    // MARK: Contenu

    @ViewBuilder
    private var content: some View {
        if let error = browser.error {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label(error.title, systemImage: "bolt.horizontal.circle").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.red)
                    Text(error.advice).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        Button("Réessayer", systemImage: "arrow.clockwise") { browser.retry() }.buttonStyle(PillButtonStyle(kind: .smallFilled))
                        TerminalButton(alias: host.alias, filled: false)
                        Button("Installer ma clé…", systemImage: "key") {
                            if let message = model.ssh.installKey(host.alias) { model.launchError = message }
                        }
                        .buttonStyle(.small)
                    }
                }
                .padding(4)
            }
        } else if browser.path == nil {
            Card { ScanningLabel(text: "Connexion à \(host.alias)…") }
        } else {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    ScrollView {
                        Group {
                            if browser.visibleFiles.isEmpty {
                                EmptyState(symbol: "tray", title: "Dossier vide",
                                           message: "Glissez des fichiers ici, ou utilisez « Importer ».")
                                    .padding(.top, 40)
                            } else if browser.layout == .grid {
                                grid
                            } else {
                                list
                            }
                        }
                        .padding(14)
                        .padding(.bottom, browser.selection.isEmpty ? 0 : 60)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .contentShape(.rect)
                    .onTapGesture { browser.selection = [] }
                    footer
                }
                .cardBackground(radius: 20)
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                            .background(Theme.accent.opacity(0.08), in: .rect(cornerRadius: 20, style: .continuous))
                            .overlay {
                                Label("Déposer pour envoyer dans \(browser.path.map { ($0 as NSString).lastPathComponent } ?? "")", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 18).padding(.vertical, 10)
                                    .background(Theme.raised, in: .capsule)
                            }
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    browser.upload(urls)
                    return true
                } isTargeted: { dropTargeted = $0 }
                if !browser.selection.isEmpty {
                    selectionBar.padding(.bottom, 44)
                }
            }
            .frame(maxHeight: .infinity)
            if !browser.transfers.isEmpty { transfers }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 10)], spacing: 10) {
            ForEach(browser.visibleFiles) { file in
                FileTile(file: file, selected: browser.selection.contains(file.id))
                    .modifier(FileInteractions(browser: browser, file: file, actions: actions(for:)))
            }
        }
    }

    private var list: some View {
        VStack(spacing: 2) {
            HStack(spacing: 12) {
                Text("Nom").frame(maxWidth: .infinity, alignment: .leading)
                Text("Taille").frame(width: 90, alignment: .trailing)
                Text("Modifié").frame(width: 150, alignment: .leading)
                Text("Droits").frame(width: 96, alignment: .leading)
                Text("Propriétaire").frame(width: 100, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(browser.visibleFiles) { file in
                FileRowView(file: file, selected: browser.selection.contains(file.id))
                    .modifier(FileInteractions(browser: browser, file: file, actions: actions(for:)))
            }
        }
    }

    private var footer: some View {
        let files = browser.visibleFiles
        let bytes = files.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
        let folders = files.filter(\.isDirectory).count
        return HStack(spacing: 8) {
            Text("\(folders) dossier\(folders > 1 ? "s" : "") · \(files.count - folders) fichier\(files.count - folders > 1 ? "s" : "") · \(Format.bytes(bytes))")
            if !browser.showHidden, browser.files.contains(where: \.isHidden) {
                Text("· \(browser.files.filter(\.isHidden).count) cachés").foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(browser.path ?? "").font(.system(size: 11).monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.head)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.headerFill)
    }

    /// Barre flottante quand des éléments sont sélectionnés (comme un service de stockage en ligne).
    private var selectionBar: some View {
        let files = browser.selectedFiles
        let single = files.count == 1 ? files.first : nil
        return HStack(spacing: 6) {
            Text("\(files.count) sélectionné\(files.count > 1 ? "s" : "")").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 8)
            Divider().frame(height: 20)
            barButton("Télécharger", "arrow.down.circle") { browser.download(files) }
            if let single, single.kind == .file {
                barButton("Modifier", "pencil") { browser.edit(single) }
            }
            if let single {
                barButton("Renommer", "character.cursor.ibeam") { newName = single.name; renaming = single }
            }
            barButton("Supprimer", "trash", tint: Theme.red) { browser.trash(files) }
            Divider().frame(height: 20)
            Button { browser.selection = [] } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26) }
                .buttonStyle(BareButtonStyle()).help("Tout désélectionner")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
        .shadow(color: Theme.shadow.opacity(0.25), radius: 14, y: 6)
    }

    private func barButton(_ label: String, _ symbol: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
                .padding(.horizontal, 10).padding(.vertical, 6).contentShape(.capsule)
        }
        .buttonStyle(BareButtonStyle())
    }

    /// Menu contextuel d'un fichier (s'applique à la sélection si le fichier en fait partie).
    @ViewBuilder
    private func actions(for file: RemoteFile) -> some View {
        let group = browser.selection.contains(file.id) && browser.selection.count > 1 ? browser.selectedFiles : [file]
        if group.count == 1 {
            if file.kind != .file {
                Button("Ouvrir", systemImage: "folder") { browser.open(file) }
                Button("Ouvrir le terminal ici", systemImage: "terminal") {
                    if let error = model.ssh.openTerminal(host.alias, directory: file.path) { model.launchError = error }
                }
            } else {
                Button("Modifier", systemImage: "pencil") { browser.edit(file) }
                Button("Ouvrir dans \(model.preferences.editor?.label ?? "l’éditeur par défaut")", systemImage: "arrow.up.forward.app") {
                    browser.editExternally(file, editor: model.preferences.editor)
                }
            }
            Divider()
        }
        Button("Télécharger", systemImage: "arrow.down.circle") { browser.download(group) }
        Button("Télécharger vers…", systemImage: "folder.badge.questionmark") { browser.chooseDownloadFolder(group) }
        if group.count == 1 {
            Button("Renommer…", systemImage: "character.cursor.ibeam") { newName = file.name; renaming = file }
            Button("Copier le chemin", systemImage: "doc.on.doc") { browser.copyPath(file) }
        }
        Divider()
        Button("Supprimer (corbeille du serveur)…", systemImage: "trash") { browser.trash(group) }
        Button("Supprimer définitivement…", systemImage: "trash.slash", role: .destructive) { confirmPermanent = group }
    }

    // MARK: Transferts

    private var transfers: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Transferts").font(.system(size: 12, weight: .semibold))
                Spacer()
                if browser.transfers.contains(where: { $0.state != .running }) {
                    Button("Effacer les terminés") { browser.clearFinishedTransfers() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.link)
                }
            }
            ForEach(browser.transfers.prefix(4)) { transfer in
                HStack(spacing: 10) {
                    Image(systemName: transfer.upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(transfer.upload ? Theme.accent : Theme.green)
                    Text(transfer.names.count == 1 ? transfer.names[0] : "\(transfer.names[0]) et \(transfer.names.count - 1) autre\(transfer.names.count > 2 ? "s" : "")")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let bytes = transfer.bytes { Text(Format.bytes(bytes)).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                    Spacer()
                    switch transfer.state {
                    case .running:
                        ProgressView().controlSize(.small)
                        Text(transfer.upload ? "envoi…" : "téléchargement…").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    case .done:
                        if let folder = transfer.localFolder {
                            Button("Afficher") {
                                NSWorkspace.shared.activateFileViewerSelecting(transfer.names.map { folder.appendingPathComponent($0) })
                            }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.link)
                        }
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    case .failed(let reason):
                        Text(reason).font(.system(size: 11)).foregroundStyle(Theme.red).lineLimit(1).help(reason)
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red)
                    }
                }
            }
        }
        .padding(12)
        .cardBackground(radius: 16)
    }
}

/// Clic : sélection (⌘ pour ajouter) ; double-clic : ouvrir ; menu contextuel ; dépôt sur un dossier.
private struct FileInteractions<Menu: View>: ViewModifier {
    let browser: RemoteBrowser
    let file: RemoteFile
    let actions: (RemoteFile) -> Menu
    @ViewState private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2)
                }
            }
            .contentShape(.rect)
            .onTapGesture(count: 2) { browser.open(file) }
            .simultaneousGesture(TapGesture().onEnded {
                let flags = NSEvent.modifierFlags
                if flags.contains(.command) || flags.contains(.shift) {
                    if browser.selection.contains(file.id) { browser.selection.remove(file.id) } else { browser.selection.insert(file.id) }
                } else {
                    browser.selection = [file.id]
                }
            })
            .contextMenu { actions(file) }
            .dropDestination(for: URL.self) { urls, _ in
                guard file.isDirectory else { return false }
                browser.upload(urls, into: file.path)
                return true
            } isTargeted: { targeted = $0 && file.isDirectory }
            .help(file.linkTarget.map { "\(file.name) → \($0)" } ?? file.name)
    }
}

private struct FileTile: View {
    let file: RemoteFile
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: RemoteBrowser.icon(for: file))
                .resizable().interpolation(.high)
                .frame(width: 56, height: 56)
                .overlay(alignment: .bottomTrailing) {
                    if file.kind == .link {
                        Image(systemName: "arrow.turn.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(3).background(Theme.accent, in: .circle)
                    }
                }
            Text(file.name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                .frame(height: 30, alignment: .top)
            Text(file.isDirectory ? "Dossier" : file.kind == .link ? "Lien" : Format.bytes(file.size))
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(selected ? Theme.accent.opacity(0.16) : Color.clear, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.accent.opacity(0.5) : .clear))
        .opacity(file.isHidden ? 0.65 : 1)
    }
}

private struct FileRowView: View {
    let file: RemoteFile
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: RemoteBrowser.icon(for: file)).resizable().frame(width: 20, height: 20)
                Text(file.name).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                if let target = file.linkTarget {
                    Text("→ \(target)").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(file.isDirectory ? "—" : Format.bytes(file.size)).monospacedDigit().frame(width: 90, alignment: .trailing)
            Text(file.modified.map(Self.date) ?? "—").frame(width: 150, alignment: .leading)
            Text(file.permissions).font(.system(size: 11).monospaced()).frame(width: 96, alignment: .leading)
            Text(file.owner).lineLimit(1).frame(width: 100, alignment: .leading)
        }
        .font(.system(size: 12))
        .foregroundStyle(file.isHidden ? Theme.muted : .primary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Theme.accent.opacity(0.16) : Color.clear, in: .rect(cornerRadius: 8, style: .continuous))
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "fr_FR")))
    }
}

private struct ScanningLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - Éditeur intégré

private struct RemoteEditorView: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: RemoteBrowser
    let edit: RemoteEdit

    var body: some View {
        let changed = (browser.editing?.text ?? "") != edit.originalText
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    browser.editing = nil
                } label: { Label("Fichiers", systemImage: "chevron.left") }
                    .buttonStyle(PillButtonStyle(kind: .small))
                Image(nsImage: RemoteBrowser.icon(for: edit.file)).resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(edit.file.name).font(.system(size: 15, weight: .semibold))
                        if changed { Tag(text: "modifié", foreground: Tag.orange.0, background: Tag.orange.1) }
                    }
                    Text(edit.file.path).font(.system(size: 11).monospaced()).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let notice = browser.notice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(Theme.orange).lineLimit(2).frame(maxWidth: 320, alignment: .trailing)
                }
                Button("Ouvrir dans \(model.preferences.editor?.label ?? "l’éditeur")", systemImage: "arrow.up.forward.app") {
                    browser.editing = nil
                    browser.editExternally(edit.file, editor: model.preferences.editor)
                }
                .buttonStyle(.small).fixedSize()
                Button("Annuler les changements") { browser.editing?.text = edit.originalText }
                    .buttonStyle(.small).fixedSize().disabled(!changed)
                Button("Enregistrer sur le serveur…", systemImage: "square.and.arrow.up") {
                    if let current = browser.editing { browser.save(current) }
                }
                .buttonStyle(PillButtonStyle(kind: .smallFilled)).fixedSize()
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!changed)
            }
            TextEditor(text: Binding(get: { browser.editing?.text ?? "" }, set: { browser.editing?.text = $0 }))
                .font(.system(size: 13).monospaced())
                .scrollContentBackground(.hidden)
                .padding(10)
                .cardBackground(radius: 16)
            Text("⌘S pour enregistrer : un aperçu montre ce qui sera remplacé. Si le fichier change sur le serveur entre-temps, l’envoi est refusé.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .frame(maxHeight: .infinity)
    }
}

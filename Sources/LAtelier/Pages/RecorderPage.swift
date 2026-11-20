import AppKit
import LAtelierCore
import SwiftUI

/// Performance › Enregistreur : processus de dev détectés dans les projets, sessions enregistrées et comparées.
struct RecorderPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var compared: Set<UUID> = []

    var body: some View {
        let recorder = model.recorder!
        PageScaffold(page: .enregistreur, subtitle: String(localized: "Les processus lancés dans vos projets sont détectés et enregistrés selon votre choix")) {
            policyPicker
        } content: {
            ForEach(recorder.pending.prefix(2)) { process in AskBanner(process: process) }
            DetectedCard()
            LiveCard()
            SessionsCard(compared: $compared)
        }
        .onAppear { model.ensureRepos() }
    }

    private var policyPicker: some View {
        @Bindable var preferences = model.preferences
        return ChoiceChips(
            selection: Binding(get: { preferences.recorderPolicy }, set: { if let value = $0 { preferences.recorderPolicy = value } }),
            items: RecorderPolicy.allCases.map { ($0, $0.label, nil) }
        )
        .accessibilityLabel(String(localized: "Quand un processus démarre dans un projet"))
    }
}

private struct AskBanner: View {
    @Environment(AppModel.self) private var model
    let process: DetectedProcess

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Theme.accent).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nouveau processus dans \(process.project.lastPathComponent)").font(.system(size: 13, weight: .semibold))
                Text(String(localized: "\(process.command) · \(process.name) (PID \(String(process.pid))) · \(process.project.abbreviatingHome())"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(String(localized: "Enregistrer")) { model.recorder.record(process, auto: false) }.buttonStyle(PillButtonStyle(kind: .smallFilled))
            Button(String(localized: "Toujours pour ce projet")) { model.recorder.always(process) }.buttonStyle(.small)
            Button(String(localized: "Ignorer")) { model.recorder.ignore(process) }.buttonStyle(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.accent.opacity(0.1), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.3)))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}

private struct DetectedCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recorder = model.recorder!
        let preferences = model.preferences
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Processus détectés dans vos projets").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(String(localized: "surveillance de \(model.knownProjects.count) projets · ignore ce qui dure moins de 5 s (git, lint…)"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            if preferences.recorderPolicy == .off {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text(String(localized: "Détection désactivée. « Exécuter et enregistrer » reste possible depuis la page d’un projet, onglet Commandes."))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(18)
            } else if recorder.detected.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text(String(localized: "Aucun processus de dev ne tourne dans vos projets en ce moment."))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(18)
            }
            ForEach(recorder.detected) { process in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                row(process)
            }
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .cardBackground()
    }

    private func row(_ process: DetectedProcess) -> some View {
        let recorder = model.recorder!
        let live = recorder.live[process.id]
        let excluded = model.preferences.neverRecord.contains(process.project.path)
        let pending = recorder.pending.contains { $0.id == process.id }
        let state: String = if let live {
            String(localized: "● Enregistrement \(Clock.format(live.session.duration))")
        } else if pending {
            String(localized: "En attente de votre choix")
        } else if excluded {
            String(localized: "Ignoré (projet exclu)")
        } else if recorder.isIgnored(process) {
            String(localized: "Ignoré")
        } else {
            String(localized: "Détecté, non enregistré")
        }
        return HStack(spacing: 12) {
            Group {
                if live != nil { Circle().fill(Tag.red.0) } else { RoundedRectangle(cornerRadius: 3).fill(Theme.muted) }
            }
            .frame(width: 9, height: 9)
            Button(process.project.lastPathComponent) { model.showRepository(process.project) }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.command).font(.system(size: 12).monospaced()).lineLimit(1).truncationMode(.middle)
                Text(String(localized: "\(process.name) · PID \(String(process.pid))") + (process.children > 0 ? (process.children > 1 ? String(localized: " · \(process.children) processus enfants") : String(localized: " · \(process.children) processus enfant")) : "")
                     + (process.fromAtelier ? String(localized: " · lancé depuis L’Atelier") : ""))
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(state).font(.system(size: 12, weight: live != nil ? .semibold : .regular))
                .foregroundStyle(live != nil ? Tag.red.0 : Theme.muted)
                .frame(width: 190, alignment: .trailing)
            Group {
                if live != nil {
                    Button(String(localized: "Arrêter")) { recorder.stop(process.id) }.buttonStyle(.small)
                } else if !pending {
                    Button(String(localized: "Enregistrer")) { recorder.record(process, auto: false) }.buttonStyle(.small)
                }
            }
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(live != nil ? Tag.red.1.opacity(0.25) : .clear)
        .contextMenu {
            if excluded {
                Button(String(localized: "Ne plus exclure \(process.project.lastPathComponent)")) { model.preferences.neverRecord.remove(process.project.path) }
            } else {
                Button(String(localized: "Ne jamais enregistrer \(process.project.lastPathComponent)")) { model.preferences.neverRecord.insert(process.project.path) }
            }
            if model.preferences.alwaysRecord.contains(process.project.path) {
                Button(String(localized: "Ne plus enregistrer automatiquement ce projet")) { model.preferences.alwaysRecord.remove(process.project.path) }
            }
        }
    }
}

enum Clock {
    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private struct LiveCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recorder = model.recorder!
        let ids = recorder.live.keys.sorted()
        let id = recorder.focus.flatMap { recorder.live[$0] != nil ? $0 : nil } ?? ids.first
        let live = id.flatMap { recorder.live[$0] }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if ids.isEmpty {
                    Text("Session en cours").font(.system(size: 15, weight: .semibold))
                } else {
                    GlassSegments(selection: Binding(get: { id ?? ids[0] }, set: { recorder.focus = $0 }),
                                  items: ids.map { ($0, recorder.live[$0]!.process.project.lastPathComponent) }, compact: true)
                }
                if let live {
                    Text(Clock.format(live.session.duration)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                }
                Button("Ajouter un repère", systemImage: "flag") { recorder.addMark() }
                    .buttonStyle(.small)
                    .disabled(live == nil)
                Spacer()
                if let last = live?.session.samples.last {
                    legend(color: Theme.accent, "CPU \(Format.percent(last.cpu))")
                    legend(color: Color(hex: 0x8A4FD8), String(localized: "Mémoire \(Format.memory(last.memory))"))
                }
            }
            ZStack {
                if let live, live.session.samples.count > 1 {
                    SessionChart(session: live.session)
                } else {
                    RoundedRectangle(cornerRadius: 14).fill(Theme.raised.opacity(0.4))
                    Text(live == nil ? String(localized: "Aucun enregistrement en cours. Lancez un processus dans un projet.") : String(localized: "Premières mesures…"))
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            .frame(height: 180)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func legend(color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 14, height: 4)
            Text(text).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }
}

/// Courbes CPU et mémoire d'une session, avec ses repères.
struct SessionChart: View {
    let session: RecordingSession

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let span = max(120, session.duration)
            let cpuTop = max(100, (session.samples.map(\.cpu).max() ?? 100) * 1.1)
            let memTop = Double(max(1, session.maxMemory)) * 1.15
            ZStack(alignment: .topLeading) {
                ForEach([0.25, 0.5, 0.75], id: \.self) { y in
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: size.height * y))
                        p.addLine(to: CGPoint(x: size.width, y: size.height * y))
                    }
                    .stroke(Theme.hairline, lineWidth: 1)
                }
                line(\.memory, top: memTop, span: span, size: size).stroke(Color(hex: 0x8A4FD8), lineWidth: 2)
                line(\.cpu, top: cpuTop, span: span, size: size).stroke(Theme.accent, lineWidth: 2)
                ForEach(Array(session.marks.enumerated()), id: \.offset) { _, mark in
                    let x = size.width * mark.t / span
                    Rectangle().fill(mark.auto ? Tag.orange.0 : Theme.muted).frame(width: 1, height: size.height).offset(x: x)
                    Text(mark.label)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.raised, in: .capsule)
                        .offset(x: min(x + 3, size.width - 120), y: 2)
                }
            }
        }
        .accessibilityLabel(String(localized: "Courbes CPU et mémoire de la session"))
    }

    private func line(_ key: KeyPath<RecordingSample, Double>, top: Double, span: Double, size: CGSize) -> Path {
        Path { path in
            for (index, sample) in session.samples.enumerated() {
                let point = CGPoint(x: size.width * sample.t / span, y: size.height * (1 - min(1, sample[keyPath: key] / top)))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    private func line(_ key: KeyPath<RecordingSample, Int64>, top: Double, span: Double, size: CGSize) -> Path {
        Path { path in
            for (index, sample) in session.samples.enumerated() {
                let point = CGPoint(x: size.width * sample.t / span, y: size.height * (1 - min(1, Double(sample[keyPath: key]) / top)))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}

private struct SessionsCard: View {
    @Environment(AppModel.self) private var model
    @Binding var compared: Set<UUID>

    var body: some View {
        let sessions = model.recorder.sessions
        let chosen = sessions.filter { compared.contains($0.id) }
        // Référence : la plus ancienne des sessions cochées.
        let reference = chosen.count >= 2 ? chosen.min { $0.start < $1.start } : nil
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sessions enregistrées").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(reference.map { String(localized: "Écarts par rapport à « \($0.name) » (la plus ancienne cochée)") } ?? String(localized: "Cochez deux sessions pour les comparer"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            HStack(spacing: 0) {
                Text(String(localized: "Comparer")).frame(width: 76, alignment: .leading)
                Text("Session").frame(maxWidth: .infinity, alignment: .leading)
                Text(String(localized: "Durée")).frame(width: 70, alignment: .leading)
                Text(String(localized: "CPU moy. / max")).frame(width: 120, alignment: .leading)
                Text(String(localized: "Mémoire max")).frame(width: 100, alignment: .leading)
                Text(String(localized: "Écart vs référence")).frame(width: 170, alignment: .leading)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
            if sessions.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text("Aucune session pour l’instant.").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(18)
            }
            ForEach(sessions) { session in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                row(session, reference: reference)
            }
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .cardBackground()
    }

    private func row(_ session: RecordingSession, reference: RecordingSession?) -> some View {
        HStack(spacing: 0) {
            Toggle(String(localized: "Comparer \(session.name)"), isOn: Binding(
                get: { compared.contains(session.id) },
                set: { if $0 { compared.insert(session.id) } else { compared.remove(session.id) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(session.auto ? "auto" : String(localized: "manuel")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 1).overlay(Capsule().strokeBorder(Theme.hairline))
                }
                Text("\(session.projectName) · \(session.command) · \(session.start.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale.current)))")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Clock.format(session.duration)).font(.system(size: 13).monospacedDigit()).frame(width: 70, alignment: .leading)
            Text("\(Format.percent(session.averageCPU)) / \(Format.percent(session.maxCPU))").font(.system(size: 13).monospacedDigit())
                .frame(width: 120, alignment: .leading)
            Text(Format.memory(session.maxMemory)).font(.system(size: 13).monospacedDigit()).frame(width: 100, alignment: .leading)
            deltaView(session, reference: reference).frame(width: 170, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .contextMenu {
            Button(String(localized: "Exporter en JSON…")) { model.recorder.export(session, csv: false) }
            Button(String(localized: "Exporter en CSV…")) { model.recorder.export(session, csv: true) }
            Button(String(localized: "Afficher dans le Finder")) {
                Task { NSWorkspace.shared.activateFileViewerSelecting([await model.recorder.url(for: session)]) }
            }
            Divider()
            Button(String(localized: "Supprimer la session…")) {
                Task {
                    let url = await model.recorder.url(for: session)
                    let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    model.preview(ActionPlan(
                        title: String(localized: "Supprimer la session « \(session.name) »"),
                        summary: String(localized: "\(session.projectName) · \(Clock.format(session.duration)). Le fichier de la session part à la corbeille."),
                        kind: .nettoyage, risk: .safe, reversible: true, steps: [.remove(url, bytes: bytes, permanently: false)], estimatedBytes: bytes
                    ))
                }
            }
        }
    }

    @ViewBuilder
    private func deltaView(_ session: RecordingSession, reference: RecordingSession?) -> some View {
        if let reference, compared.contains(session.id) {
            if reference.id == session.id {
                Text("référence").font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                let delta = session.delta(from: reference)
                HStack(spacing: 8) {
                    deltaText("CPU", delta.cpu)
                    deltaText(String(localized: "Mém."), delta.memory)
                }
            }
        } else {
            Text("—").foregroundStyle(Theme.muted)
        }
    }

    private func deltaText(_ label: String, _ value: Double?) -> some View {
        let v = value ?? 0
        // Moins de CPU ou de mémoire, c'est mieux : vert.
        let color: Color = abs(v) < 2 ? Theme.muted : (v < 0 ? Tag.green.0 : Tag.red.0)
        return Text("\(label) \(v >= 0 ? "+" : "−")\(Int(abs(v).rounded())) %")
            .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(color)
    }
}

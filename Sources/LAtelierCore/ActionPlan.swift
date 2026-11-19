import Foundation

/// Niveau de risque, commun à tous les onglets (badges vert / orange / rouge / protégé).
public enum Risk: String, Sendable, Codable, CaseIterable {
    case safe, caution, danger, protected

    public var label: String {
        switch self {
        case .safe: "Sans risque"
        case .caution: "À vérifier"
        case .danger: "Risqué"
        case .protected: "Protégé"
        }
    }
}

/// Une action proposée, montrée en aperçu avant d'être exécutée (règle n° 1).
public struct ActionPlan: Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var summary: String
    public var kind: HistoryEntry.Kind
    public var risk: Risk
    /// Vrai si l'action peut être défaite (par exemple, envoi à la corbeille).
    public var reversible: Bool
    public var commands: [CommandSpec]
    public var estimatedBytes: Int64?

    public init(
        id: UUID = UUID(), title: String, summary: String, kind: HistoryEntry.Kind, risk: Risk,
        reversible: Bool, commands: [CommandSpec], estimatedBytes: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.kind = kind
        self.risk = risk
        self.reversible = reversible
        self.commands = commands
        self.estimatedBytes = estimatedBytes
    }
}

/// Exécute les commandes d'un plan une par une ; s'arrête à la première erreur
/// et rend une entrée d'historique qui dit exactement ce qui a été fait.
public struct PlanExecutor: Sendable {
    public let runner: CommandRunner
    public let outputLimit: Int

    public init(runner: CommandRunner = CommandRunner(), outputLimit: Int = 64_000) {
        self.runner = runner
        self.outputLimit = outputLimit
    }

    public func execute(
        _ plan: ActionPlan,
        onEvent: @escaping @Sendable (_ commandIndex: Int, _ event: CommandEvent) -> Void = { _, _ in }
    ) async -> HistoryEntry {
        let total = plan.commands.count
        var logs: [CommandLog] = []
        var outcome = HistoryEntry.Outcome.success

        for (index, spec) in plan.commands.enumerated() {
            if Task.isCancelled {
                outcome = Self.cancelledOutcome(done: index, total: total)
                break
            }
            let start = Date()
            var output = OutputTail(limit: outputLimit)
            var status: Int32?
            var launchError: String?
            do {
                for try await event in runner.stream(spec) {
                    onEvent(index, event)
                    switch event {
                    case .stdout(let line), .stderr(let line): output.append(line)
                    case .exited(let code, let signaled): status = signaled ? nil : code
                    }
                }
            } catch {
                launchError = error.localizedDescription
                output.append(launchError!)
            }
            logs.append(CommandLog(
                command: spec.displayString, exitStatus: status, output: output.text,
                duration: Date().timeIntervalSince(start)
            ))

            if Task.isCancelled {
                outcome = Self.cancelledOutcome(done: index, total: total)
                break
            }
            if status != 0 {
                let reason = launchError
                    ?? status.map { "« \(spec.displayString) » a échoué (code \($0))." }
                    ?? "« \(spec.displayString) » s’est arrêtée de façon inattendue."
                outcome = index == 0
                    ? .failure(reason)
                    : .partial("\(reason) \(index) commande(s) sur \(total) avaient réussi.")
                break
            }
        }

        return HistoryEntry(
            kind: plan.kind, title: plan.title, summary: plan.summary, commands: logs,
            outcome: outcome, bytesFreed: outcome == .success ? plan.estimatedBytes : nil
        )
    }

    private static func cancelledOutcome(done: Int, total: Int) -> HistoryEntry.Outcome {
        done == 0 ? .cancelled : .partial("Arrêté par l’utilisateur après \(done) commande(s) sur \(total).")
    }
}

/// Garde la fin d'une sortie longue.
struct OutputTail {
    let limit: Int
    private var buffer = ""
    private var truncated = false

    init(limit: Int) { self.limit = limit }

    mutating func append(_ line: String) {
        buffer += line + "\n"
        if buffer.utf8.count > limit * 2 {
            buffer = String(buffer.suffix(limit))
            truncated = true
        }
    }

    var text: String {
        var result = buffer.utf8.count > limit ? String(buffer.suffix(limit)) : buffer
        if result.hasSuffix("\n") { result.removeLast() }
        return (truncated || buffer.utf8.count > limit ? "…\n" : "") + result
    }
}

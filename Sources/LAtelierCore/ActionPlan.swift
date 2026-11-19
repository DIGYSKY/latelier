import Foundation

/// Niveau de risque, commun à tous les onglets (badges vert / orange / rouge / protégé).
public enum Risk: String, Sendable, Codable, CaseIterable, Comparable {
    case safe, caution, danger, protected

    public var label: String {
        switch self {
        case .safe: "Sans risque"
        case .caution: "À vérifier"
        case .danger: "Données"
        case .protected: "Protégé"
        }
    }

    private var rank: Int { Risk.allCases.firstIndex(of: self)! }
    public static func < (a: Risk, b: Risk) -> Bool { a.rank < b.rank }
}

/// Une étape d'action : une commande externe, ou un élément à retirer du disque.
public enum ActionStep: Sendable, Hashable {
    case command(CommandSpec)
    /// Corbeille par défaut (règle n° 2) ; `permanently` pour une suppression définitive.
    case remove(URL, bytes: Int64, permanently: Bool)

    public var displayString: String {
        switch self {
        case .command(let spec): spec.displayString
        case .remove(let url, _, _): url.path
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
    public var steps: [ActionStep]
    public var estimatedBytes: Int64?
    /// Ce qui a été volontairement laissé de côté (en cours d'utilisation…), affiché dans l'aperçu.
    public var skipped: [String]
    /// Faux : une commande qui échoue n'arrête pas les suivantes (fetch de tous les dépôts).
    public var stopOnFailure: Bool

    public init(
        id: UUID = UUID(), title: String, summary: String, kind: HistoryEntry.Kind, risk: Risk,
        reversible: Bool, steps: [ActionStep], estimatedBytes: Int64? = nil, skipped: [String] = [],
        stopOnFailure: Bool = true
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.kind = kind
        self.risk = risk
        self.reversible = reversible
        self.steps = steps
        self.estimatedBytes = estimatedBytes
        self.skipped = skipped
        self.stopOnFailure = stopOnFailure
    }

    public init(
        id: UUID = UUID(), title: String, summary: String, kind: HistoryEntry.Kind, risk: Risk,
        reversible: Bool, commands: [CommandSpec], estimatedBytes: Int64? = nil
    ) {
        self.init(
            id: id, title: title, summary: summary, kind: kind, risk: risk, reversible: reversible,
            steps: commands.map(ActionStep.command), estimatedBytes: estimatedBytes
        )
    }

    public var commands: [CommandSpec] {
        steps.compactMap { if case .command(let spec) = $0 { spec } else { nil } }
    }

    public var removals: [(url: URL, bytes: Int64)] {
        steps.compactMap { if case .remove(let url, let bytes, _) = $0 { (url, bytes) } else { nil } }
    }

    public var removesFiles: Bool { !removals.isEmpty }

    public var removesPermanently: Bool {
        steps.contains { if case .remove(_, _, true) = $0 { true } else { false } }
    }

    /// Même plan, en corbeille ou en suppression définitive.
    public func removing(permanently: Bool) -> ActionPlan {
        var plan = self
        plan.steps = steps.map {
            if case .remove(let url, let bytes, _) = $0 { .remove(url, bytes: bytes, permanently: permanently) } else { $0 }
        }
        plan.reversible = !permanently && commands.isEmpty
        return plan
    }
}

/// Exécute un plan étape par étape et rend une entrée d'historique qui dit exactement
/// ce qui a été fait. Une commande qui échoue arrête le plan ; un fichier qui ne peut
/// pas être retiré est noté et on continue avec les autres (règle n° 6 : c'est signalé).
public struct PlanExecutor: Sendable {
    public let runner: CommandRunner
    public let safety: SafetyGuard
    public let outputLimit: Int

    public init(runner: CommandRunner = CommandRunner(), safety: SafetyGuard = .standard, outputLimit: Int = 64_000) {
        self.runner = runner
        self.safety = safety
        self.outputLimit = outputLimit
    }

    public func execute(
        _ plan: ActionPlan,
        onEvent: @escaping @Sendable (_ stepIndex: Int, _ event: CommandEvent) -> Void = { _, _ in }
    ) async -> HistoryEntry {
        let total = plan.steps.count
        var logs: [CommandLog] = []
        var outcome = HistoryEntry.Outcome.success
        var stoppedEarly = false
        var completed = 0
        var commandFailures: [String] = []

        var removal = RemovalLog(limit: outputLimit)
        var freed: Int64 = 0

        stepLoop: for (index, step) in plan.steps.enumerated() {
            if Task.isCancelled {
                stoppedEarly = true
                break
            }
            switch step {
            case .remove(let url, let bytes, let permanently):
                removal.permanently = permanently
                do {
                    try safety.check(url)
                    onEvent(index, .stdout(url.path))
                    if permanently {
                        try FileManager.default.removeItem(at: url)
                    } else {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                    freed += bytes
                    completed += 1
                    removal.succeeded(url, bytes: bytes)
                    onEvent(index, .exited(status: 0, uncaughtSignal: false))
                } catch {
                    removal.failed(url, reason: Self.describe(error))
                    onEvent(index, .stderr("\(url.path) : \(Self.describe(error))"))
                    onEvent(index, .exited(status: 1, uncaughtSignal: false))
                }

            case .command(let spec):
                if let log = removal.flush() { logs.append(log) }
                let (log, status, launchError) = await run(spec, index: index, onEvent: onEvent)
                logs.append(log)
                if Task.isCancelled {
                    stoppedEarly = true
                    break stepLoop
                }
                if status != 0, !plan.stopOnFailure {
                    commandFailures.append(launchError ?? "« \(spec.displayString) » a échoué (code \(status.map(String.init) ?? "?")).")
                    continue
                }
                if status != 0 {
                    let reason = launchError
                        ?? status.map { "« \(spec.displayString) » a échoué (code \($0))." }
                        ?? "« \(spec.displayString) » s’est arrêtée de façon inattendue."
                    outcome = completed == 0
                        ? .failure(reason)
                        : .partial("\(reason) \(completed) étape(s) sur \(total) avaient été faites.")
                    break stepLoop
                }
                completed += 1
            }
        }
        let removalFailures = removal.failures
        let removalSuccesses = removal.successes
        if let log = removal.flush() { logs.append(log) }

        if case .success = outcome {
            if stoppedEarly {
                outcome = completed == 0
                    ? .cancelled
                    : .partial("Arrêté par l’utilisateur après \(completed) étape(s) sur \(total).")
            } else if !commandFailures.isEmpty {
                let message = commandFailures.count == 1 ? commandFailures[0] : "\(commandFailures.count) commandes sur \(total) ont échoué, voir le détail."
                outcome = completed == 0 ? .failure(message) : .partial(message)
            } else if removalFailures > 0 {
                let message = "\(removalFailures) élément(s) n’ont pas pu être retirés, voir le détail."
                outcome = removalSuccesses == 0 && plan.commands.isEmpty ? .failure(message) : .partial(message)
            }
        }

        let bytes: Int64? = plan.removesFiles ? (freed > 0 ? freed : nil)
            : (outcome == .success ? plan.estimatedBytes : nil)
        return HistoryEntry(
            kind: plan.kind, title: plan.title, summary: plan.summary, commands: logs,
            outcome: outcome, bytesFreed: bytes
        )
    }

    private func run(
        _ spec: CommandSpec, index: Int, onEvent: @escaping @Sendable (Int, CommandEvent) -> Void
    ) async -> (CommandLog, Int32?, String?) {
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
            output.append(error.localizedDescription)
            onEvent(index, .stderr(error.localizedDescription))
        }
        let log = CommandLog(
            command: spec.displayString, exitStatus: status, output: output.text,
            duration: Date().timeIntervalSince(start)
        )
        return (log, status, launchError)
    }

    static func describe(_ error: Error) -> String {
        if let refusal = error as? SafetyGuard.Refusal { return refusal.localizedDescription }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return ns.localizedDescription
    }
}

/// Résume une série de retraits de fichiers en une seule entrée d'historique.
private struct RemovalLog {
    var permanently = false
    private(set) var successes = 0
    private(set) var failures = 0
    private var bytes: Int64 = 0
    private var output: OutputTail
    private let start = Date()

    init(limit: Int) { output = OutputTail(limit: limit) }

    mutating func succeeded(_ url: URL, bytes: Int64) {
        successes += 1
        self.bytes += bytes
        output.append("✓ \(url.path)")
    }

    mutating func failed(_ url: URL, reason: String) {
        failures += 1
        output.append("✗ \(url.path) — \(reason)")
    }

    /// Rend l'entrée et remet à zéro.
    mutating func flush() -> CommandLog? {
        guard successes + failures > 0 else { return nil }
        let verb = permanently ? "Suppression définitive" : "Mise à la corbeille"
        let count = successes + failures
        let log = CommandLog(
            command: "\(verb) de \(count) élément(s)",
            exitStatus: failures == 0 ? 0 : 1,
            output: output.text,
            duration: Date().timeIntervalSince(start)
        )
        self = RemovalLog(limit: output.limit)
        return log
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

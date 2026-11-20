import Foundation

/// Ce qu'un processus produit, ligne par ligne, puis sa fin.
public enum CommandEvent: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    /// `uncaughtSignal` : le processus a été tué (par exemple par « Arrêter »).
    case exited(status: Int32, uncaughtSignal: Bool)
}

public struct CommandResult: Sendable {
    public let spec: CommandSpec
    /// `nil` si le processus n'a pas terminé normalement (annulation).
    public let exitStatus: Int32?
    public let stdout: [String]
    public let stderr: [String]
    public let duration: TimeInterval

    public var succeeded: Bool { exitStatus == 0 }
}

public enum CommandError: Error, LocalizedError, Equatable {
    case toolNotFound(String)
    case launchFailed(String, reason: String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool): "« \(tool) » est introuvable sur ce Mac."
        case .launchFailed(let command, let reason): "Impossible de lancer « \(command) » : \(reason)"
        case .timedOut(let command): "« \(command) » n’a pas répondu à temps."
        }
    }
}

/// Lance des processus avec `Process`, sans shell, et diffuse leur sortie en direct.
public struct CommandRunner: Sendable {
    public let locator: ToolLocator

    public init(locator: ToolLocator = .standard) {
        self.locator = locator
    }

    /// Sortie en direct. Arrêter d'itérer (ou annuler la tâche) termine le processus.
    public func stream(_ spec: CommandSpec) -> AsyncThrowingStream<CommandEvent, Error> {
        let locator = self.locator
        return AsyncThrowingStream { continuation in
            guard let executable = locator.locate(spec.tool) else {
                continuation.finish(throwing: CommandError.toolNotFound(spec.tool))
                return
            }

            let box = ProcessBox()
            let process = box.process
            process.executableURL = executable
            process.arguments = spec.arguments
            if let directory = spec.workingDirectory { process.currentDirectoryURL = directory }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = locator.pathVariable
            environment.merge(spec.environment) { _, new in new }
            process.environment = environment

            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice

            let group = DispatchGroup()
            group.enter()
            process.terminationHandler = { _ in group.leave() }

            continuation.onTermination = { reason in
                guard case .cancelled = reason, box.process.isRunning else { return }
                // `npm run dev` lance node, qui lance vite… : on arrête tout l'arbre, enfants d'abord.
                let root = box.process.processIdentifier
                for child in ProcessTree.descendants(of: root).reversed() { kill(child, SIGTERM) }
                box.process.terminate()
            }

            do {
                try process.run()
            } catch {
                continuation.finish(
                    throwing: CommandError.launchFailed(spec.displayString, reason: error.localizedDescription)
                )
                return
            }

            Self.pump(out.fileHandleForReading, group: group) { continuation.yield(.stdout($0)) }
            Self.pump(err.fileHandleForReading, group: group) { continuation.yield(.stderr($0)) }

            group.notify(queue: .global()) {
                let process = box.process
                continuation.yield(.exited(
                    status: process.terminationStatus,
                    uncaughtSignal: process.terminationReason == .uncaughtSignal
                ))
                continuation.finish()
            }
        }
    }

    /// Lance et attend la fin. Avec `timeout`, le processus est tué s'il dépasse.
    public func run(_ spec: CommandSpec, timeout: Duration? = nil) async throws -> CommandResult {
        guard let timeout else { return try await collect(spec) }
        return try await withThrowingTaskGroup(of: CommandResult.self) { group in
            group.addTask { try await collect(spec) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CommandError.timedOut(spec.displayString)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    private func collect(_ spec: CommandSpec) async throws -> CommandResult {
        let start = Date()
        var stdout: [String] = []
        var stderr: [String] = []
        var status: Int32?
        for try await event in stream(spec) {
            switch event {
            case .stdout(let line): stdout.append(line)
            case .stderr(let line): stderr.append(line)
            case .exited(let code, let signaled): status = signaled ? nil : code
            }
        }
        return CommandResult(
            spec: spec, exitStatus: status, stdout: stdout, stderr: stderr,
            duration: Date().timeIntervalSince(start)
        )
    }

    /// Lit un tuyau jusqu'à la fin et découpe en lignes.
    /// Couper sur `\n` ne casse jamais un caractère UTF-8.
    private static func pump(
        _ handle: FileHandle,
        group: DispatchGroup,
        emit: @escaping @Sendable (String) -> Void
    ) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            func line(_ bytes: Data) -> String {
                var text = String(decoding: bytes, as: UTF8.self)
                if text.hasSuffix("\r") { text.removeLast() }
                return text
            }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    emit(line(buffer[buffer.startIndex..<newline]))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            if !buffer.isEmpty { emit(line(buffer)) }
            group.leave()
        }
    }
}

/// `Process` n'est pas `Sendable` ; il n'est touché ici que pour le lire ou l'arrêter.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
}

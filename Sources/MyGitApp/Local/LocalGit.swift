import Foundation

/// Runs git in a local clone, for the one write the app does: pushing a branch before opening its PR.
enum LocalGit {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Commits on HEAD that its upstream doesn't have; nil when the branch has no upstream.
    static func unpushedCount(in path: String) async -> Int? {
        guard let output = try? await run(["rev-list", "--count", "@{upstream}..HEAD"], in: path) else { return nil }
        return Int(output)
    }

    static func push(branch: String, in path: String) async throws {
        _ = try await run(["push", "--set-upstream", "origin", branch], in: path)
    }

    private static func run(_ arguments: [String], in path: String) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path] + arguments
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            env["GIT_TERMINAL_PROMPT"] = "0" // fail instead of waiting on a password prompt nobody sees
            process.environment = env
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(message: message.isEmpty ? "git \(arguments.first ?? "") a échoué." : message)
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

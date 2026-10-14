import Foundation
import Observation

/// Last-known API responses on disk, so every screen renders instantly on launch.
final class DiskCache: @unchecked Sendable {
    static let shared = DiskCache()
    private let dir: URL
    private let queue = DispatchQueue(label: "MyGitApp.DiskCache", qos: .utility)

    init(dir: URL = AppPaths.support.appendingPathComponent("cache", isDirectory: true)) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func read<T: Decodable>(_ key: String, as: T.Type = T.self) -> T? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? JSONDecoder.github.decode(T.self, from: data)
    }

    func write<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder.github.encode(value) else { return }
        let url = url(for: key)
        queue.async { try? data.write(to: url, options: .atomic) }
    }

    private func url(for key: String) -> URL {
        let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return dir.appendingPathComponent(safe + ".json")
    }
}

/// Stale-while-revalidate loader: shows the cached value immediately, then refreshes.
@MainActor @Observable
final class Loader<T: Codable> {
    var value: T?
    var error: String?
    var isLoading = false
    private(set) var loadedKey: String?

    func load(_ key: String, fetch: @escaping () async throws -> T) async {
        if loadedKey != key {
            value = DiskCache.shared.read(key, as: T.self)
            error = nil
            loadedKey = key
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await fetch()
            guard loadedKey == key else { return }
            value = fresh
            error = nil
            DiskCache.shared.write(fresh, key: key)
            SyncClock.shared.markSynced()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard loadedKey == key else { return }
            self.error = error.localizedDescription
        }
    }
}

/// Drives the "Synced 27s ago" footer.
@MainActor @Observable
final class SyncClock {
    static let shared = SyncClock()
    var lastSync: Date?
    func markSynced() { lastSync = .now }
}

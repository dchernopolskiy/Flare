//
//  JobTracker.swift
//  Flare
//
//  Created by Dan on 12/9/25.
//

import Foundation

actor JobTracker {
    static let shared = JobTracker()

    private var trackedJobs: [String: TrackedJob] = [:]
    private let cacheFile: URL
    private var persistenceTask: Task<Void, Never>?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let flareDir = appSupport.appendingPathComponent("Flare", isDirectory: true)
        cacheFile = flareDir.appendingPathComponent("job-tracking.json")
        try? FileManager.default.createDirectory(at: flareDir, withIntermediateDirectories: true)
        trackedJobs = Self.loadCache(from: cacheFile)
    }

    func trackJob(id: String, title: String, url: String, source: String) {
        if trackedJobs[id] == nil {
            trackedJobs[id] = TrackedJob(
                id: id,
                title: title,
                url: url,
                source: source,
                firstSeen: Date(),
                lastSeen: Date()
            )
        } else {
            trackedJobs[id]?.lastSeen = Date()
        }
        schedulePersistence()
    }

    func getFirstSeenDate(for jobId: String) -> Date? {
        return trackedJobs[jobId]?.firstSeen
    }

    func hasSeenJob(_ jobId: String) -> Bool {
        return trackedJobs[jobId] != nil
    }

    func getTrackedJobs(for source: String) -> [TrackedJob] {
        return trackedJobs.values.filter { $0.source == source }
    }

    func cleanup() {
        let cutoff = Date().addingTimeInterval(-90 * 24 * 60 * 60)
        trackedJobs = trackedJobs.filter { $0.value.lastSeen > cutoff }
        persistenceTask?.cancel()
        persistCache()
    }

    /// Clears only the in-memory view. PersistenceService removes the underlying
    /// files transactionally, so writing here would create a partial clear if that
    /// operation later failed.
    func clear() {
        persistenceTask?.cancel()
        trackedJobs.removeAll()
    }

    // MARK: - Persistence

    private static func loadCache(from url: URL) -> [String: TrackedJob] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[JobTracker] No cache file found")
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            let jobs = try JSONDecoder().decode([TrackedJob].self, from: data)
            let trackedJobs = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
            print("[JobTracker] Loaded \(trackedJobs.count) tracked jobs")
            return trackedJobs
        } catch {
            print("[JobTracker] Failed to load cache: \(error)")
            return [:]
        }
    }

    private func persistCache() {
        do {
            let jobs = Array(trackedJobs.values)
            let data = try JSONEncoder().encode(jobs)
            try data.write(to: cacheFile, options: .atomic)
        } catch {
            print("[JobTracker] Failed to persist cache: \(error)")
        }
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.persistCache()
        }
    }
}

struct TrackedJob: Codable {
    let id: String
    let title: String
    let url: String
    let source: String
    let firstSeen: Date
    var lastSeen: Date
}

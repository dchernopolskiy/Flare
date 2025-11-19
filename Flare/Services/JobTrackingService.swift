//
//  JobTrackingService.swift
//  Flare
//
//  Created by Claude on 12/2/25.
//

import Foundation

actor JobTrackingService {
    static let shared = JobTrackingService()

    private struct JobTrackingData: Codable {
        let id: String
        let firstSeenDate: Date
    }

    private init() {}

    func loadTrackingData(for source: String) async -> [String: Date] {
        let url = getTrackingFileURL(for: source)

        do {
            let data = try Data(contentsOf: url)
            let trackingData = try JSONDecoder().decode([JobTrackingData].self, from: data)

            var dict: [String: Date] = [:]
            for item in trackingData {
                dict[item.id] = item.firstSeenDate
            }

            return dict
        } catch {
            return [:]
        }
    }

    /// Save tracking data for a specific source
    func saveTrackingData(_ jobs: [Job], for source: String, currentDate: Date, retentionDays: Int = 30) async {
        let url = getTrackingFileURL(for: source)

        do {
            var existingData = await loadTrackingData(for: source)

            for job in jobs {
                if existingData[job.id] == nil {
                    existingData[job.id] = currentDate
                }
            }

            let trackingData = existingData.map { JobTrackingData(id: $0.key, firstSeenDate: $0.value) }

            let cutoffDate = Date().addingTimeInterval(-Double(retentionDays) * 24 * 3600)
            let recentData = trackingData.filter { $0.firstSeenDate > cutoffDate }

            let data = try JSONEncoder().encode(recentData)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            print("[\(source)] Failed to save job tracking data: \(error)")
        }
    }

    private func getTrackingFileURL(for source: String) -> URL {
        let sanitizedSource = source.lowercased().replacingOccurrences(of: " ", with: "")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicrosoftJobMonitor")
            .appendingPathComponent("\(sanitizedSource)JobTracking.json")
    }
}

//
//  LeverFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import Foundation

actor LeverFetcher: URLBasedJobFetcherProtocol {

    private let trackingService = JobTrackingService.shared

    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let slug = extractLeverSlug(from: url)
        let storedJobDates = await trackingService.loadTrackingData(for: "lever_\(slug)")
        let currentDate = Date()

        guard let apiURL = URL(string: "https://api.lever.co/v0/postings/\(slug)?mode=json") else {
            throw FetchError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: apiURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            FetcherLog.error("Lever", "HTTP \(httpResponse.statusCode)")
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoded: [LeverJob]
        do {
            decoded = try JSONDecoder().decode([LeverJob].self, from: data)
        } catch {
            FetcherLog.error("Lever", "Decoding error: \(error.localizedDescription)")
            throw FetchError.decodingError(details: "Failed to decode Lever response: \(error.localizedDescription)")
        }

        guard !decoded.isEmpty else {
            throw FetchError.noJobs
        }

        let titleKeywords = titleFilter.parseAsFilterKeywords()
        let locationKeywords = locationFilter.parseAsFilterKeywords().includingRemote()

        let allJobs = decoded.compactMap { job -> Job? in
            guard !job.text.isEmpty, !job.id.isEmpty, !job.hostedUrl.isEmpty else { return nil }

            let location = job.categories.location ?? "Location not specified"
            let jobId = "lever-\(job.id)"
            let firstSeenDate = storedJobDates[jobId] ?? currentDate

            return Job(
                id: jobId,
                title: job.text,
                location: location,
                postingDate: ISO8601DateFormatter().date(from: job.createdAt),
                url: job.hostedUrl,
                description: job.descriptionPlain,
                workSiteFlexibility: WorkFlexibility.extract(from: job.descriptionPlain),
                source: .lever,
                companyName: slug.capitalized,
                department: job.categories.team,
                category: job.categories.commitment,
                firstSeenDate: firstSeenDate,
                originalPostingDate: nil,
                wasBumped: false
            )
        }

        let filteredJobs = allJobs.applying(titleKeywords: titleKeywords, locationKeywords: locationKeywords)
        FetcherLog.info("Lever", "Fetched \(allJobs.count) total, \(filteredJobs.count) after filtering")

        await trackingService.saveTrackingData(filteredJobs, for: "lever_\(slug)", currentDate: currentDate, retentionDays: 30)
        return filteredJobs
    }
    
    // MARK: - Helper Methods

    private func extractLeverSlug(from url: URL) -> String {
        if let host = url.host, host.contains("lever.co") {
            let parts = url.pathComponents.filter { !$0.isEmpty }
            return parts.first ?? host.replacingOccurrences(of: ".lever.co", with: "")
        }
        return url.lastPathComponent
    }
}

// MARK: - Lever API Model
struct LeverJob: Codable {
    let id: String
    let text: String
    let createdAt: String
    let hostedUrl: String
    let descriptionPlain: String
    let categories: Categories
    
    struct Categories: Codable {
        let team: String?
        let commitment: String?
        let location: String?
    }
}

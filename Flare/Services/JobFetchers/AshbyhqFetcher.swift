//
//  AshbyFetcher.swift
//  MSJobMonitor
//
//
//

import Foundation

actor AshbyFetcher: URLBasedJobFetcherProtocol {

    private let trackingService = JobTrackingService.shared

    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let slug = extractAshbySlug(from: url)

        let storedJobDates = await trackingService.loadTrackingData(for: "ashby_\(slug)")
        let currentDate = Date()

        let jobs = try await fetchJobsViaGraphQL(slug: slug)

        let titleKeywords = titleFilter.parseAsFilterKeywords()
        let locationKeywords = locationFilter.parseAsFilterKeywords()

        let allJobs = jobs.compactMap { job -> Job? in
            let location = job.locationName ?? "Location not specified"

            var fullLocation = location
            if !job.secondaryLocations.isEmpty {
                let secondaryLocs = job.secondaryLocations.map { $0.locationName }.joined(separator: ", ")
                fullLocation += " (+ \(secondaryLocs))"
            }

            let jobId = "ashby-\(job.id)"
            let firstSeenDate = storedJobDates[jobId] ?? currentDate

            return Job(
                id: jobId,
                title: job.title,
                location: fullLocation,
                postingDate: nil,
                url: "https://jobs.ashbyhq.com/\(slug)/\(job.id)",
                description: job.compensationTierSummary ?? "",
                workSiteFlexibility: job.workplaceType,
                source: .ashby,
                companyName: slug.capitalized,
                department: nil,
                category: nil,
                firstSeenDate: firstSeenDate,
                originalPostingDate: nil,
                wasBumped: false
            )
        }

        let filteredJobs = allJobs.applying(titleKeywords: titleKeywords, locationKeywords: locationKeywords)
        FetcherLog.info("Ashby", "Fetched \(allJobs.count) total, \(filteredJobs.count) after filtering")

        await trackingService.saveTrackingData(filteredJobs, for: "ashby_\(slug)", currentDate: currentDate, retentionDays: 30)
        return filteredJobs
    }

    // MARK: - GraphQL API Call
    
    private func fetchJobsViaGraphQL(slug: String) async throws -> [AshbyJobPosting] {
        let apiURL = URL(string: "https://jobs.ashbyhq.com/api/non-user-graphql?op=ApiJobBoardWithTeams")!
        
        let query = """
        query ApiJobBoardWithTeams($organizationHostedJobsPageName: String!) {
          jobBoard: jobBoardWithTeams(
            organizationHostedJobsPageName: $organizationHostedJobsPageName
          ) {
            teams {
              id
              name
              parentTeamId
            }
            jobPostings {
              id
              title
              teamId
              locationId
              locationName
              workplaceType
              employmentType
              secondaryLocations {
                locationId
                locationName
              }
              compensationTierSummary
            }
          }
        }
        """
        
        let variables: [String: Any] = [
            "organizationHostedJobsPageName": slug
        ]
        
        let requestBody: [String: Any] = [
            "operationName": "ApiJobBoardWithTeams",
            "query": query,
            "variables": variables
        ]
        
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            FetcherLog.error("Ashby", "HTTP \(httpResponse.statusCode)")
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoded: AshbyGraphQLResponse
        do {
            decoded = try JSONDecoder().decode(AshbyGraphQLResponse.self, from: data)
        } catch {
            FetcherLog.error("Ashby", "Decoding error: \(error.localizedDescription)")
            throw FetchError.decodingError(details: "Failed to decode Ashby response: \(error.localizedDescription)")
        }

        guard let jobPostings = decoded.data.jobBoard?.jobPostings else {
            throw FetchError.decodingError(details: "No job postings found in Ashby response")
        }
        
        return jobPostings
    }
    
    // MARK: - Helper Methods

    private func extractAshbySlug(from url: URL) -> String {
        if let host = url.host, host.contains("ashbyhq.com") {
            return url.lastPathComponent
        }
        return url.lastPathComponent
    }
}

// MARK: - Ashby GraphQL Models

struct AshbyGraphQLResponse: Codable {
    let data: AshbyData
}

struct AshbyData: Codable {
    let jobBoard: AshbyJobBoard?
}

struct AshbyJobBoard: Codable {
    let teams: [AshbyTeam]
    let jobPostings: [AshbyJobPosting]
}

struct AshbyTeam: Codable {
    let id: String
    let name: String
    let parentTeamId: String?
}

struct AshbyJobPosting: Codable {
    let id: String
    let title: String
    let teamId: String
    let locationId: String?
    let locationName: String?
    let workplaceType: String?
    let employmentType: String?
    let secondaryLocations: [AshbySecondaryLocation]
    let compensationTierSummary: String?
}

struct AshbySecondaryLocation: Codable {
    let locationId: String
    let locationName: String
}

//
//  GreenhouseFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import Foundation

// MARK: - Greenhouse API Models
struct GreenhouseResponse: Codable {
    let jobs: [GreenhouseJob]
}

struct GreenhouseJob: Codable {
    let id: Int
    let title: String
    let absolute_url: String
    let location: GreenhouseLocation?
    let updated_at: String?
    let content: String?
    let departments: [GreenhouseDepartment]?
    
    struct GreenhouseLocation: Codable {
        let name: String
    }
    
    struct GreenhouseDepartment: Codable {
        let name: String
    }
}

// MARK: - Greenhouse Fetcher
actor GreenhouseFetcher {

    func fetchGreenhouseJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let boardSlug = extractGreenhouseBoardSlug(from: url)
        let apiURL = URL(string: "https://boards-api.greenhouse.io/v1/boards/\(boardSlug)/jobs?content=true")!

        var request = URLRequest(url: apiURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            FetcherLog.error("Greenhouse", "HTTP \(httpResponse.statusCode)")
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoded: GreenhouseResponse
        do {
            decoded = try JSONDecoder().decode(GreenhouseResponse.self, from: data)
        } catch {
            FetcherLog.error("Greenhouse", "Decoding error: \(error.localizedDescription)")
            throw FetchError.decodingError(details: "Failed to decode Greenhouse response: \(error.localizedDescription)")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        let titleKeywords = titleFilter.parseAsFilterKeywords()
        let locationKeywords = locationFilter.parseAsFilterKeywords().includingRemote()

        let allJobs = decoded.jobs.compactMap { ghJob -> Job? in
            guard !ghJob.title.isEmpty, !ghJob.absolute_url.isEmpty else { return nil }

            var postingDate = Date()
            if let dateString = ghJob.updated_at {
                postingDate = formatter.date(from: dateString)
                           ?? fallbackFormatter.date(from: dateString)
                           ?? Date()
            }

            let rawLocation = ghJob.location?.name ?? ""
            let cleanDescription = HTMLCleaner.cleanHTML(ghJob.content ?? "")
            let location = rawLocation.isEmpty ? "Not specified" : rawLocation

            return Job(
                id: "gh-\(ghJob.id)",
                title: ghJob.title,
                location: location,
                postingDate: postingDate,
                url: ghJob.absolute_url,
                description: cleanDescription,
                workSiteFlexibility: WorkFlexibility.extract(from: cleanDescription),
                source: .greenhouse,
                companyName: extractCompanyName(from: url),
                department: ghJob.departments?.first?.name,
                category: nil,
                firstSeenDate: Date(),
                originalPostingDate: nil,
                wasBumped: false
            )
        }

        let filteredJobs = allJobs.applying(titleKeywords: titleKeywords, locationKeywords: locationKeywords)
        FetcherLog.info("Greenhouse", "Fetched \(allJobs.count) total, \(filteredJobs.count) after filtering")

        return filteredJobs
    }
    
    // MARK: - Helper Methods

    private func extractGreenhouseBoardSlug(from url: URL) -> String {
        let pathComponents = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        
        if url.host?.contains("boards.greenhouse.io") == true ||
           url.host?.contains("job-boards.greenhouse.io") == true {
            return pathComponents.first ?? "unknown"
        } else if url.host?.hasSuffix("greenhouse.io") == true {
            if let host = url.host,
               let companyName = host.components(separatedBy: ".").first {
                return companyName
            }
        }
        
        return pathComponents.first ?? "unknown"
    }
    
    private func extractCompanyName(from url: URL) -> String {
        let slug = extractGreenhouseBoardSlug(from: url)
        return slug.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

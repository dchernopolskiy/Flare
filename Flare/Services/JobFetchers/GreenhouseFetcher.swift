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
actor GreenhouseFetcher: JobFetcherProtocol {
    
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        return []
    }
    
    func fetchGreenhouseJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let boardSlug = extractGreenhouseBoardSlug(from: url)
        print("[Greenhouse] Fetching jobs for board: \(boardSlug)")
        print("[Greenhouse] Title filter: '\(titleFilter)', Location filter: '\(locationFilter)'")

        let apiURL = URL(string: "https://boards-api.greenhouse.io/v1/boards/\(boardSlug)/jobs?content=true")!
        
        var request = URLRequest(url: apiURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            if let errorString = String(data: data, encoding: .utf8) {
            }
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }
        
        do {
            let decoded = try JSONDecoder().decode(GreenhouseResponse.self, from: data)
            print("[Greenhouse] API returned \(decoded.jobs.count) total jobs")

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime]

            let titleKeywords = parseFilterString(titleFilter, includeRemote: false)
            let locationKeywords = parseFilterString(locationFilter)

            print("[Greenhouse] Applying filters - Title keywords: \(titleKeywords), Location keywords: \(locationKeywords)")

            let jobs = decoded.jobs.enumerated().compactMap { (index, ghJob) -> Job? in
                guard !ghJob.title.isEmpty else {
                    print("[Greenhouse] Skipping job at index \(index): empty title")
                    return nil
                }

                guard !ghJob.absolute_url.isEmpty else {
                    print("[Greenhouse] Skipping job '\(ghJob.title)' at index \(index): empty URL")
                    return nil
                }

                var postingDate = Date()
                if let dateString = ghJob.updated_at {
                    postingDate = formatter.date(from: dateString)
                               ?? fallbackFormatter.date(from: dateString)
                               ?? Date()
                }

                let rawLocation = ghJob.location?.name ?? ""
                let title = ghJob.title

                // Title filter
                if !titleKeywords.isEmpty {
                    let titleMatches = titleKeywords.contains { keyword in
                        title.localizedCaseInsensitiveContains(keyword)
                    }
                    if !titleMatches {
                        return nil
                    }
                }

                // Location filter - simple keyword matching (includes "remote" automatically)
                if !locationKeywords.isEmpty {
                    let locationMatches = locationKeywords.contains { keyword in
                        rawLocation.localizedCaseInsensitiveContains(keyword)
                    }
                    if !locationMatches {
                        return nil
                    }
                }
                
                let cleanDescription = HTMLCleaner.cleanHTML(ghJob.content ?? "")

                // Use raw location, it's more accurate than trying to parse
                let location = rawLocation.isEmpty ? "Not specified" : rawLocation

                return Job(
                    id: "gh-\(ghJob.id)",
                    title: title,
                    location: location,
                    postingDate: postingDate,
                    url: ghJob.absolute_url,
                    description: cleanDescription,
                    workSiteFlexibility: extractWorkFlexibility(from: cleanDescription),
                    source: .greenhouse,
                    companyName: extractCompanyName(from: url),
                    department: ghJob.departments?.first?.name,
                    category: nil,
                    firstSeenDate: Date(),
                    originalPostingDate: nil,
                    wasBumped: false
                )
            }
            print("[Greenhouse] Parsed \(jobs.count) jobs from API (after filtering)")

            return jobs
            
        } catch let DecodingError.keyNotFound(key, context) {
            print("[Greenhouse] Missing key '\(key.stringValue)' at: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
            if let responseString = String(data: data, encoding: .utf8) {
                print("[Greenhouse] Response preview: \(responseString.prefix(500))")
            }
            throw FetchError.decodingError(details: "Missing field '\(key.stringValue)' in Greenhouse response")
        } catch {
            print("[Greenhouse] Decoding error: \(error)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("[Greenhouse] Response preview: \(responseString.prefix(500))")
            }
            throw FetchError.decodingError(details: "Failed to decode Greenhouse response: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helper Methods
    
    private func parseFilterString(_ filterString: String, includeRemote: Bool = true) -> [String] {
        guard !filterString.isEmpty else { return [] }
        
        var keywords = filterString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        if includeRemote {
            let remoteKeywords = ["remote", "work from home", "distributed", "anywhere"]
            let hasRemoteKeyword = keywords.contains { keyword in
                remoteKeywords.contains { remote in
                    keyword.localizedCaseInsensitiveContains(remote)
                }
            }
            
            if !hasRemoteKeyword {
                keywords.append("remote")
            }
        }
        
        return keywords
    }
    
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
    
    private func extractWorkFlexibility(from description: String) -> String? {
        let flexibilityKeywords = ["remote", "hybrid", "flexible", "work from home", "onsite", "on-site"]
        let lowercased = description.lowercased()
        
        for keyword in flexibilityKeywords {
            if lowercased.contains(keyword) {
                return keyword.capitalized
            }
        }
        
        return nil
    }
}

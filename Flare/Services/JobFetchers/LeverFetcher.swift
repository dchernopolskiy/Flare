//
//  LeverFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import Foundation

actor LeverFetcher: URLBasedJobFetcherProtocol {
    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let slug = extractLeverSlug(from: url)
        print("[Lever] Fetching jobs for: \(slug)")
        print("[Lever] Title filter: '\(titleFilter)', Location filter: '\(locationFilter)'")

        guard let apiURL = URL(string: "https://api.lever.co/v0/postings/\(slug)?mode=json") else {
            throw FetchError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: apiURL)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("[Lever] Invalid response object")
            throw FetchError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            print("[Lever] HTTP error: \(httpResponse.statusCode)")
            if let errorString = String(data: data, encoding: .utf8) {
                print("[Lever] Response preview: \(errorString.prefix(200))")
            }
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }
        
        let decoded: [LeverJob]
        do {
            decoded = try JSONDecoder().decode([LeverJob].self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            print("[Lever] Missing key '\(key.stringValue)' at: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
            if let responseString = String(data: data, encoding: .utf8) {
                print("[Lever] Response preview: \(responseString.prefix(500))")
            }
            throw FetchError.decodingError(details: "Missing field '\(key.stringValue)' in Lever response")
        } catch {
            print("[Lever] Decoding error: \(error)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("[Lever] Response preview: \(responseString.prefix(500))")
            }
            throw FetchError.decodingError(details: "Failed to decode Lever response: \(error.localizedDescription)")
        }
        
        guard !decoded.isEmpty else {
            throw FetchError.noJobs
        }

        print("[Lever] API returned \(decoded.count) total jobs")

        let titleKeywords = parseFilterString(titleFilter, includeRemote: false)
        let locationKeywords = parseFilterString(locationFilter)
        
        return decoded.enumerated().compactMap { (index, job) -> Job? in
            guard !job.text.isEmpty else {
                print("[Lever] Skipping job at index \(index): empty title")
                return nil
            }
            
            guard !job.id.isEmpty else {
                print("[Lever] Skipping job '\(job.text)' at index \(index): empty ID")
                return nil
            }
            
            guard !job.hostedUrl.isEmpty else {
                print("[Lever] Skipping job '\(job.text)' at index \(index): empty URL")
                return nil
            }
            
            let location = job.categories.location ?? "Location not specified"
            let title = job.text
            
            if !titleKeywords.isEmpty {
                let titleMatches = titleKeywords.contains { keyword in
                    title.localizedCaseInsensitiveContains(keyword)
                }
                if !titleMatches {
                    return nil
                }
            }
            
            if !locationKeywords.isEmpty {
                let locationMatches = locationKeywords.contains { keyword in
                    location.localizedCaseInsensitiveContains(keyword)
                }
                if !locationMatches {
                    return nil
                }
            }
            
            return Job(
                id: "lever-\(job.id)",
                title: title,
                location: location,
                postingDate: ISO8601DateFormatter().date(from: job.createdAt),
                url: job.hostedUrl,
                description: job.descriptionPlain,
                workSiteFlexibility: nil,
                source: .lever,
                companyName: slug.capitalized,
                department: job.categories.team,
                category: job.categories.commitment,
                firstSeenDate: Date(),
                originalPostingDate: nil,
                wasBumped: false
            )
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

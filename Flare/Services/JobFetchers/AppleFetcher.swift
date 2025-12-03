//
//  AppleFetcher.swift
//  Flare
//
//  Created by Claude on 1/2/25.
//

import Foundation

actor AppleFetcher: JobFetcherProtocol, URLBasedJobFetcherProtocol {
    private let apiURL = URL(string: "https://jobs.apple.com/api/v1/search")!
    private let csrfURL = URL(string: "https://jobs.apple.com/api/v1/CSRFToken")!
    private let trackingService = JobTrackingService.shared
    private var cachedCSRFToken: String?
    private var csrfTokenExpiry: Date?

    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        let trackingData = await trackingService.loadTrackingData(for: "apple")
        let currentDate = Date()

        let jobs = try await fetchAllJobs(trackingData: trackingData, currentDate: currentDate, maxPages: maxPages, titleKeywords: titleKeywords, location: location)

        let filteredJobs = applyFilters(jobs: jobs, titleKeywords: titleKeywords, location: location)

        await trackingService.saveTrackingData(filteredJobs, for: "apple", currentDate: currentDate, retentionDays: 30)

        print("[Apple] Fetched \(jobs.count) total jobs, \(filteredJobs.count) after filtering")
        return filteredJobs
    }

    private func fetchCSRFToken() async throws -> String {
        if let token = cachedCSRFToken,
           let expiry = csrfTokenExpiry,
           Date() < expiry {
            return token
        }

        var request = URLRequest(url: csrfURL)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw FetchError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        guard let tokenString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw FetchError.decodingError(details: "Failed to decode CSRF token")
        }

        // Cache the token for 10 minutes
        cachedCSRFToken = tokenString
        csrfTokenExpiry = Date().addingTimeInterval(600)

        return tokenString
    }

    private func fetchAllJobs(trackingData: [String: Date], currentDate: Date, maxPages: Int, titleKeywords: [String], location: String) async throws -> [Job] {
        var allJobs: [Job] = []

        var locationFilter: [String] = []
        let lowercasedLocation = location.lowercased()

        if lowercasedLocation.contains("washington") || lowercasedLocation.contains("seattle") {
            locationFilter.append("postLocation-state1000") // Washington state
        } else if !location.isEmpty {
            locationFilter.append("postLocation-USA")
        } else {
            locationFilter.append("postLocation-USA")
        }

        let searchQuery = titleKeywords.joined(separator: " ")

        for page in 1...maxPages {
            let pageJobs = try await fetchPage(
                page: page,
                trackingData: trackingData,
                currentDate: currentDate,
                query: searchQuery,
                locationFilter: locationFilter
            )
            allJobs.append(contentsOf: pageJobs)

            if pageJobs.count < 20 {
                break
            }
        }

        return allJobs
    }

    private func fetchPage(page: Int, trackingData: [String: Date], currentDate: Date, query: String, locationFilter: [String]) async throws -> [Job] {
        let csrfToken = try await fetchCSRFToken()

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("en-us", forHTTPHeaderField: "browserlocale")
        request.setValue("en_US", forHTTPHeaderField: "locale")
        request.setValue(csrfToken, forHTTPHeaderField: "x-apple-csrf-token")
        request.setValue("https://jobs.apple.com", forHTTPHeaderField: "origin")
        request.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.timeoutInterval = 15

        let requestBody: [String: Any] = [
            "query": query,
            "filters": [
                "locations": locationFilter
            ],
            "page": page,
            "locale": "en-us",
            "sort": "newest",
            "format": [
                "longDate": "MMMM D, YYYY",
                "mediumDate": "MMM D, YYYY"
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        print("[Apple] Fetching page \(page) with query '\(query)' and locations \(locationFilter)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorString = String(data: data, encoding: .utf8) {
                print("[Apple] Error response: \(errorString.prefix(500))")
            }
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoded: AppleResponse
        do {
            decoded = try JSONDecoder().decode(AppleResponse.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            print("[Apple] Missing key '\(key.stringValue)' at: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
            if let responseString = String(data: data, encoding: .utf8) {
                print("[Apple] Response preview: \(responseString.prefix(500))")
            }
            throw FetchError.decodingError(details: "Missing field '\(key.stringValue)' in Apple response")
        } catch {
            print("[Apple] Decoding error: \(error)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("[Apple] Response preview: \(responseString.prefix(500))")
            }
            throw FetchError.decodingError(details: "Failed to decode Apple response: \(error.localizedDescription)")
        }

        let jobs = decoded.res.searchResults.compactMap { appleJob -> Job? in
            let title = appleJob.postingTitle
            guard !title.isEmpty else {
                print("[Apple] Skipping job: empty title")
                return nil
            }

            let locationString = buildLocationString(from: appleJob)

            let jobURL = "https://jobs.apple.com/en-us/details/\(appleJob.positionId)/\(appleJob.transformedPostingTitle ?? "")"

            var workFlexibility: String? = nil
            if appleJob.homeOffice == true {
                workFlexibility = "Remote"
            }

            var postingDate: Date? = nil
            if let dateString = appleJob.postDateInGMT {
                let formatter = ISO8601DateFormatter()
                postingDate = formatter.date(from: dateString)
            }

            let jobId = "apple-\(appleJob.positionId)"
            let firstSeenDate = trackingData[jobId] ?? currentDate

            return Job(
                id: jobId,
                title: title,
                location: locationString,
                postingDate: postingDate,
                url: jobURL,
                description: appleJob.jobSummary ?? "",
                workSiteFlexibility: workFlexibility,
                source: .apple,
                companyName: "Apple",
                department: appleJob.team?.teamName,
                category: appleJob.team?.teamName,
                firstSeenDate: firstSeenDate,
                originalPostingDate: postingDate,
                wasBumped: false
            )
        }

        return jobs
    }

    private func buildLocationString(from job: AppleJob) -> String {
        guard let locations = job.locations, !locations.isEmpty else {
            return "Location not specified"
        }

        let location = locations[0]
        var components: [String] = []

        if let name = location.name, !name.isEmpty {
            components.append(name)
        }

        if let country = location.countryName, !country.isEmpty, country != "United States of America" {
            components.append(country)
        }

        return components.isEmpty ? "Location not specified" : components.joined(separator: ", ")
    }

    private func applyFilters(jobs: [Job], titleKeywords: [String], location: String) -> [Job] {
        var filteredJobs = jobs

        if !titleKeywords.isEmpty {
            let keywords = titleKeywords.filter { !$0.isEmpty }
            if !keywords.isEmpty {
                filteredJobs = filteredJobs.filter { job in
                    keywords.contains { keyword in
                        job.title.localizedCaseInsensitiveContains(keyword) ||
                        job.department?.localizedCaseInsensitiveContains(keyword) ?? false ||
                        job.category?.localizedCaseInsensitiveContains(keyword) ?? false
                    }
                }
            }
        }

        if !location.isEmpty {
            let locationKeywords = parseLocationString(location)
            if !locationKeywords.isEmpty {
                filteredJobs = filteredJobs.filter { job in
                    locationKeywords.contains { keyword in
                        job.location.localizedCaseInsensitiveContains(keyword)
                    }
                }
            }
        }

        return filteredJobs
    }

    private func parseLocationString(_ locationString: String) -> [String] {
        guard !locationString.isEmpty else { return [] }

        var keywords = locationString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if keywords.contains(where: { $0.localizedCaseInsensitiveContains("remote") }) {
            if !keywords.contains("remote") {
                keywords.append("remote")
            }
            if !keywords.contains("Remote") {
                keywords.append("Remote")
            }
        }

        return keywords
    }

    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let titleKeywords = parseFilterString(titleFilter)

        let trackingData = await trackingService.loadTrackingData(for: "apple")
        let currentDate = Date()

        let jobs = try await fetchAllJobs(
            trackingData: trackingData,
            currentDate: currentDate,
            maxPages: 5,
            titleKeywords: titleKeywords,
            location: locationFilter
        )

        let filteredJobs = applyFilters(jobs: jobs, titleKeywords: titleKeywords, location: locationFilter)

        await trackingService.saveTrackingData(filteredJobs, for: "apple", currentDate: currentDate, retentionDays: 30)

        return filteredJobs
    }

    private func parseFilterString(_ filterString: String) -> [String] {
        guard !filterString.isEmpty else { return [] }

        return filterString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Apple API Model

struct AppleResponse: Codable {
    let res: AppleResponseData
}

struct AppleResponseData: Codable {
    let searchResults: [AppleJob]
}

struct AppleJob: Codable {
    let id: String
    let positionId: String
    let postingTitle: String
    let transformedPostingTitle: String?
    let postingDate: String?
    let postDateInGMT: String?
    let jobSummary: String?
    let team: AppleTeam?
    let locations: [AppleLocation]?
    let homeOffice: Bool?
}

struct AppleTeam: Codable {
    let teamName: String?
    let teamID: String?
    let teamCode: String?
}

struct AppleLocation: Codable {
    let postLocationId: String?
    let city: String?
    let stateProvince: String?
    let countryName: String?
    let name: String?
    let countryID: String?
    let level: Int?
}

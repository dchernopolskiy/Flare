//
//  MicrosoftJobFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import Foundation

actor MicrosoftJobFetcher: JobFetcherProtocol {
    private let baseURL = "https://apply.careers.microsoft.com/api/pcsx/search"
    private let detailsBaseURL = "https://apply.careers.microsoft.com/api/pcsx/position_details"
    private var descriptionCache: [String: String] = [:] // positionId -> description

    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int = 5) async throws -> [Job] {
        print("[Microsoft] Starting fetch with location: '\(location)'")
        let safeMaxPages = max(1, min(maxPages, 20))

        var allJobs: [Job] = []
        var globalSeenJobIds = Set<String>()
        
        let targetLocations = LocationService.getMicrosoftLocationParams(location)
        print("[Microsoft] Target locations from mapper: \(targetLocations)")
        
        let titles = titleKeywords.filter { !$0.isEmpty }
        
        var searchCombinations: [(title: String, location: String)] = []
        
        if titles.isEmpty && targetLocations.isEmpty {
            searchCombinations.append(("", "United States"))
        } else if titles.isEmpty {
            for loc in targetLocations {
                searchCombinations.append(("", loc))
            }
        } else if targetLocations.isEmpty {
            for title in titles {
                searchCombinations.append((title, "United States"))
            }
        } else {
            for title in titles {
                for loc in targetLocations {
                    searchCombinations.append((title, loc))
                }
            }
        }
        
        for (index, combo) in searchCombinations.enumerated() {
            let description = [combo.title, combo.location].filter { !$0.isEmpty }.joined(separator: " in ")
            let totalSearches = searchCombinations.count
            
            await MainActor.run {
                JobManager.shared.loadingProgress = "Microsoft search \(index + 1)/\(totalSearches): \(description)"
            }
            
            let pageLimit = min(safeMaxPages, 3)
            let jobs = try await executeIndividualSearch(
                title: combo.title,
                location: combo.location,
                maxPages: pageLimit
            )
            
            let newJobs = jobs.filter { job in
                if globalSeenJobIds.contains(job.id) {
                    return false
                }
                globalSeenJobIds.insert(job.id)
                return true
            }
            
            allJobs.append(contentsOf: newJobs)

            try await Task.sleep(nanoseconds: FetchDelayConfig.fetchPageDelay * 2) // Longer delay for Microsoft
        }
        
        await MainActor.run {
            JobManager.shared.loadingProgress = ""
        }

        print("[Microsoft] Total jobs returned: \(allJobs.count)")

        // Fetch detailed descriptions for all jobs
        print("[Microsoft] Fetching detailed descriptions for \(allJobs.count) jobs")
        var jobsWithDescriptions: [Job] = []

        for (index, job) in allJobs.enumerated() {
            let components = job.id.split(separator: "-")
            guard components.count >= 2,
                  components[0] == "microsoft",
                  let positionId = components[1].split(separator: "-").first else {
                print("[Microsoft] Invalid job ID format: \(job.id)")
                jobsWithDescriptions.append(job)
                continue
            }

            let positionIdString = String(positionId)

            // Check cache first
            let description: String?
            if let cached = descriptionCache[positionIdString] {
                description = cached
                print("[Microsoft] Using cached description for \(positionIdString)")
            } else {
                // Fetch and cache
                do {
                    description = try await fetchJobDescription(positionId: positionIdString)
                    if let desc = description {
                        descriptionCache[positionIdString] = desc
                    }
                } catch {
                    print("[Microsoft] Failed to fetch description for \(positionIdString): \(error)")
                    description = nil
                }
            }

            if let description = description {
                let updatedJob = Job(
                    id: job.id,
                    title: job.title,
                    location: job.location,
                    postingDate: job.postingDate,
                    url: job.url,
                    description: description,
                    workSiteFlexibility: job.workSiteFlexibility,
                    source: job.source,
                    companyName: job.companyName,
                    department: job.department,
                    category: job.category,
                    firstSeenDate: job.firstSeenDate,
                    originalPostingDate: job.originalPostingDate,
                    wasBumped: job.wasBumped
                )
                jobsWithDescriptions.append(updatedJob)
            } else {
                jobsWithDescriptions.append(job)
            }

            if (index + 1) % 10 == 0 {
                print("[Microsoft] Processed descriptions for \(index + 1)/\(allJobs.count) jobs")
            }

            // Only delay if we actually fetched (not cached)
            if descriptionCache[positionIdString] == nil {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
            }
        }

        print("[Microsoft] Completed fetching descriptions for \(jobsWithDescriptions.count) jobs")
        return jobsWithDescriptions
    }
    
    private func executeIndividualSearch(title: String, location: String, maxPages: Int) async throws -> [Job] {
        var jobs: [Job] = []
        let pageSize = 10  // Microsoft API returns 10 results per page
        var totalCount: Int?
        
        for page in 0..<maxPages {
            let startIndex = page * pageSize
            if let total = totalCount, startIndex >= total {
                print("[Microsoft] Reached total count (\(total)), stopping pagination")
                break
            }
            
            var components = URLComponents(string: baseURL)!
            components.queryItems = [
                URLQueryItem(name: "domain", value: "microsoft.com"),
                URLQueryItem(name: "start", value: String(startIndex)),
                URLQueryItem(name: "sort_by", value: "timestamp"),
                URLQueryItem(name: "filter_distance", value: "160"),
                URLQueryItem(name: "includeRemote", value: "1")
            ]
            
            if !title.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "query", value: title))
            }
            
            if !location.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "location", value: location))
            }
            
            var request = URLRequest(url: components.url!)
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
            request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
            request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
            request.timeoutInterval = 15
            
            if page == 0 {
                print("[Microsoft] Query URL: \(components.url!)")
            }
            
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[Microsoft] Invalid response object")
                throw FetchError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                print("[Microsoft] HTTP error: \(httpResponse.statusCode)")
                throw FetchError.httpError(statusCode: httpResponse.statusCode)
            }
            
            let (pageJobs, count) = try parseResponse(data)
            
            
            if page == 0 {
                totalCount = count
                print("Total available jobs: \(count)")
                print("Page \(page + 1): Found \(pageJobs.count) jobs")
            }
            
            jobs.append(contentsOf: pageJobs)
            
            if pageJobs.isEmpty || pageJobs.count < pageSize {
                print("Last page reached (got \(pageJobs.count) jobs)")
                break
            }

            try await Task.sleep(nanoseconds: FetchDelayConfig.boardFetchDelay)
        }
        print("Total jobs fetched: \(jobs.count)")
        
        return jobs
    }
    
    private func parseResponse(_ data: Data) throws -> ([Job], Int) {
        let decoder = JSONDecoder()
        
        let response: MSResponse
        do {
            response = try decoder.decode(MSResponse.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            print("[Microsoft] Missing key '\(key.stringValue)' at: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
            if let responseString = String(data: data, encoding: .utf8) {
                print("[Microsoft] Response preview: \(responseString.prefix(500))")
            }
            throw FetchError.decodingError(details: "Missing field '\(key.stringValue)' in Microsoft response")
        } catch {
            print("[Microsoft] Decoding error: \(error)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("[Microsoft] Response preview: \(responseString.prefix(500))")
            }
            throw FetchError.decodingError(details: "Failed to decode Microsoft response: \(error.localizedDescription)")
        }
        
        guard response.status == 200 else {
            let errorMsg = response.error?.message ?? "Unknown error"
            print("[Microsoft] API error: \(errorMsg)")
            throw FetchError.apiError(errorMsg)
        }
        
        var jobs: [Job] = []
        
        for (index, position) in response.data.positions.enumerated() {
            guard !position.name.isEmpty else {
                print("[Microsoft] Skipping job at index \(index): empty name")
                continue
            }
            
            guard !position.displayJobId.isEmpty else {
                print("[Microsoft] Skipping job '\(position.name)' at index \(index): empty displayJobId")
                continue
            }
            
            let primaryLocation = position.locations.first ?? "Location not specified"
            var displayLocation = primaryLocation
            if let workOption = position.workLocationOption {
                switch workOption.lowercased() {
                case "onsite", "fully on-site":
                    displayLocation += " (On-site)"
                case "remote":
                    displayLocation += " (Remote)"
                case "hybrid":
                    displayLocation += " (Hybrid)"
                default:
                    if workOption.contains("days") || workOption.contains("week") {
                        displayLocation += " (Hybrid: \(workOption))"
                    }
                }
            }
            
            let postingDate = position.lastRefreshDate
            let originalDate = position.originalPostingDate
            let isBumped = position.wasBumped
            if isBumped {
                print("🔵 [Microsoft] Job '\(position.name)' was BUMPED:")
                print("  - Original posting (creationTs): \(originalDate)")
                print("  - Last refresh (postedTs): \(postingDate)")
                print("  - Time diff: \(postingDate.timeIntervalSince(originalDate) / 3600) hours")
            }
            
            let jobURL: String
            if !position.positionUrl.isEmpty {
                jobURL = "https://apply.careers.microsoft.com\(position.positionUrl)"
            } else {
                jobURL = "https://apply.careers.microsoft.com/careers/job/\(position.id)"
            }
            
            let job = Job(
                id: "microsoft-\(position.id)-\(position.displayJobId)",
                title: position.name,
                location: displayLocation,
                postingDate: postingDate,
                url: jobURL,
                description: "", // Not included in search results
                workSiteFlexibility: position.workLocationOption ?? "",
                source: .microsoft,
                companyName: "Microsoft",
                department: position.department,
                category: nil,
                firstSeenDate: Date(),
                originalPostingDate: originalDate,
                wasBumped: isBumped
            )
            
            jobs.append(job)
        }
        
        return (jobs, response.data.count)
    }

    // MARK: - Job Details Fetching

    func fetchJobDescription(positionId: String, domain: String = "microsoft.com") async throws -> String? {
        var components = URLComponents(string: detailsBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "position_id", value: positionId),
            URLQueryItem(name: "domain", value: domain),
            URLQueryItem(name: "hl", value: "en")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36", forHTTPHeaderField: "user-agent")
        request.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.timeoutInterval = 10

        print("[Microsoft] Fetching details for position: \(positionId)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            print("[Microsoft] Details API HTTP error: \(httpResponse.statusCode)")
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let detailsResponse: MSPositionDetailsResponse
        do {
            detailsResponse = try decoder.decode(MSPositionDetailsResponse.self, from: data)
        } catch {
            print("[Microsoft] Failed to decode position details: \(error)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("[Microsoft] Response preview: \(responseString.prefix(500))")
            }
            throw FetchError.decodingError(details: "Failed to decode position details: \(error.localizedDescription)")
        }

        guard detailsResponse.status == 200 else {
            let errorMsg = detailsResponse.error?.message ?? "Unknown error"
            print("[Microsoft] Details API error: \(errorMsg)")
            throw FetchError.apiError(errorMsg)
        }

        return detailsResponse.data?.jobDescription
    }

    func fetchJobsWithDetails(titleKeywords: [String], location: String, maxPages: Int = 5, includeDescriptions: Bool = false) async throws -> [Job] {
        // First, fetch all jobs normally
        let jobs = try await fetchJobs(titleKeywords: titleKeywords, location: location, maxPages: maxPages)

        guard includeDescriptions else {
            return jobs
        }

        print("[Microsoft] Fetching detailed descriptions for \(jobs.count) jobs...")

        var jobsWithDescriptions: [Job] = []

        for (index, job) in jobs.enumerated() {
            let components = job.id.split(separator: "-")
            guard components.count >= 2,
                  components[0] == "microsoft",
                  let positionId = components[1].split(separator: "-").first else {
                print("[Microsoft] Invalid job ID format: \(job.id)")
                jobsWithDescriptions.append(job)
                continue
            }

            do {
                if let description = try await fetchJobDescription(positionId: String(positionId)) {
                    let updatedJob = Job(
                        id: job.id,
                        title: job.title,
                        location: job.location,
                        postingDate: job.postingDate,
                        url: job.url,
                        description: description,
                        workSiteFlexibility: job.workSiteFlexibility,
                        source: job.source,
                        companyName: job.companyName,
                        department: job.department,
                        category: job.category,
                        firstSeenDate: job.firstSeenDate,
                        originalPostingDate: job.originalPostingDate,
                        wasBumped: job.wasBumped
                    )
                    jobsWithDescriptions.append(updatedJob)
                } else {
                    jobsWithDescriptions.append(job)
                }
            } catch {
                print("[Microsoft] Failed to fetch description for \(positionId): \(error)")
                jobsWithDescriptions.append(job)
            }

            if (index + 1) % 10 == 0 {
                print("[Microsoft] Fetched descriptions for \(index + 1)/\(jobs.count) jobs")
            }

            try await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
        }

        print("[Microsoft] Completed fetching descriptions for \(jobsWithDescriptions.count) jobs")
        return jobsWithDescriptions
    }
}

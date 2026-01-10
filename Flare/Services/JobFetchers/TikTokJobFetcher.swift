//
//  TikTokJobFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import Foundation

actor TikTokJobFetcher: JobFetcherProtocol {
    private let apiURL = URL(string: "https://api.lifeattiktok.com/api/v1/public/supplier/search/job/posts")!
    private let pageSize = 12
    private let trackingService = JobTrackingService.shared

    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        let locationCodes = LocationService.getTikTokLocationCodes(location)
        let trackingData = await trackingService.loadTrackingData(for: "tiktok")
        let currentDate = Date()

        // Fetch jobs with regular location
        var allJobs = try await fetchJobsWithParams(
            titleKeywords: titleKeywords,
            locationCodes: locationCodes,
            maxPages: maxPages,
            trackingData: trackingData,
            currentDate: currentDate
        )

        // Also fetch remote jobs by adding "remote" to keyword search
        if !location.lowercased().contains("remote") && !titleKeywords.contains(where: { $0.lowercased().contains("remote") }) {
            var remoteKeywords = titleKeywords
            remoteKeywords.append("remote")

            let remoteJobs = try await fetchJobsWithParams(
                titleKeywords: remoteKeywords,
                locationCodes: [],  // No location filter for remote
                maxPages: min(maxPages, 5),  // Limit pages for remote search
                trackingData: trackingData,
                currentDate: currentDate
            )

            let existingIds = Set(allJobs.map { $0.id })
            let newRemoteJobs = remoteJobs.filter { !existingIds.contains($0.id) }
            allJobs.append(contentsOf: newRemoteJobs)
        }

        await trackingService.saveTrackingData(allJobs, for: "tiktok", currentDate: currentDate, retentionDays: 30)
        return allJobs
    }

    private func fetchJobsWithParams(
        titleKeywords: [String],
        locationCodes: [String],
        maxPages: Int,
        trackingData: [String: Date],
        currentDate: Date
    ) async throws -> [Job] {
        var allJobs: [Job] = []
        var currentOffset = 0
        var pageNumber = 1
        
        while allJobs.count < 5000 && pageNumber <= maxPages {
            do {
                let pageJobs = try await fetchJobsPage(
                    titleKeywords: titleKeywords,
                    locationCodes: locationCodes,
                    offset: currentOffset
                )
                
                if pageJobs.isEmpty {
                    break
                }
                
                let converted = pageJobs.enumerated().compactMap { (index, tikTokJob) -> Job? in
                    // Validate required fields
                    guard !tikTokJob.title.isEmpty else {
                        print("[TikTok] Skipping job at index \(index): empty title")
                        return nil
                    }
                    
                    guard !tikTokJob.id.isEmpty else {
                        print("[TikTok] Skipping job at index \(index): empty ID")
                        return nil
                    }
                    
                    let locationString = buildLocationString(from: tikTokJob.city_info)
                    let jobId = "tiktok-\(tikTokJob.id)"
                    let firstSeenDate = trackingData[jobId] ?? currentDate
                    
                    return Job(
                        id: jobId,
                        title: tikTokJob.title,
                        location: locationString,
                        postingDate: nil,
                        url: "https://lifeattiktok.com/search/\(tikTokJob.id)",
                        description: combineDescriptionAndRequirements(tikTokJob),
                        workSiteFlexibility: extractWorkFlexibility(from: tikTokJob.description),
                        source: .tiktok,
                        companyName: "TikTok",
                        department: tikTokJob.job_category?.en_name,
                        category: tikTokJob.job_category?.i18n_name,
                        firstSeenDate: firstSeenDate,
                        originalPostingDate: nil,
                        wasBumped: false
                    )
                }
                
                allJobs.append(contentsOf: converted)
                
                if pageJobs.count < pageSize {
                    break
                }
                
                currentOffset += pageSize
                pageNumber += 1

                try await Task.sleep(nanoseconds: FetchDelayConfig.fetchPageDelay)
            } catch let error as FetchError {
                print("[TikTok] Fetch error on page \(pageNumber): \(error.errorDescription ?? "Unknown")")
                throw error
            } catch {
                print("[TikTok] Unexpected error on page \(pageNumber): \(error)")
                throw FetchError.networkError(error)
            }
        }
        
        return allJobs
    }

    private func fetchJobsPage(titleKeywords: [String], locationCodes: [String], offset: Int) async throws -> [TikTokJob] {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue("en-US", forHTTPHeaderField: "accept-language")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("https://lifeattiktok.com", forHTTPHeaderField: "origin")
        request.setValue("https://lifeattiktok.com/", forHTTPHeaderField: "referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "user-agent")
        request.setValue("tiktok", forHTTPHeaderField: "website-path")
        request.timeoutInterval = 15
        
        let body = buildRequestBody(
            titleKeywords: titleKeywords,
            locationCodes: locationCodes,
            offset: offset
        )
        
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }
        
        let decoded: TikTokAPIResponse
        do {
            decoded = try JSONDecoder().decode(TikTokAPIResponse.self, from: data)
        } catch {
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? "Unable to preview"
            print("[TikTok] Decoding error: \(error)")
            print("[TikTok] Response preview: \(preview)")
            throw FetchError.decodingError(details: "Failed to decode TikTok response: \(error.localizedDescription)")
        }
        
        guard decoded.code == 0 else {
            throw FetchError.apiError("TikTok API returned error code \(decoded.code)")
        }
        
        return decoded.data.job_post_list
    }
    
    private func buildRequestBody(titleKeywords: [String], locationCodes: [String], offset: Int) -> [String: Any] {
        return [
            "recruitment_id_list": ["1"],
            "job_category_id_list": [],
            "subject_id_list": [],
            "location_code_list": locationCodes,
            "keyword": titleKeywords.joined(separator: " "),
            "limit": pageSize,
            "offset": offset
        ]
    }
    
    // MARK: - Helpers
    private func buildLocationString(from cityInfo: TikTokCityInfo?) -> String {
        guard let cityInfo = cityInfo else { return "Location not specified" }
        var parts: [String] = []
        if let city = cityInfo.en_name { parts.append(city) }
        var parent = cityInfo.parent
        while let p = parent {
            if let n = p.en_name { parts.append(n) }
            parent = p.parent
        }
        return parts.joined(separator: ", ")
    }
    
    private func combineDescriptionAndRequirements(_ job: TikTokJob) -> String {
        var combined = job.description
        if !job.requirement.isEmpty {
            combined += "\n\nRequirements:\n" + job.requirement
        }
        return combined
    }
    
    private func extractWorkFlexibility(from description: String) -> String? {
        let keywords = ["remote", "hybrid", "flexible", "onsite", "on-site", "in-office"]
        let lower = description.lowercased()
        for key in keywords where lower.contains(key) {
            return key.capitalized
        }
        return nil
    }
}

// MARK: - Models (keep existing)
struct TikTokAPIResponse: Codable {
    let code: Int
    let data: TikTokData
}

struct TikTokData: Codable {
    let job_post_list: [TikTokJob]
}

struct TikTokJob: Codable {
    let id: String
    let code: String?
    let title: String
    let description: String
    let requirement: String
    let job_category: TikTokJobCategory?
    let city_info: TikTokCityInfo?
}

final class TikTokJobCategory: Codable {
    let id: String
    let en_name: String?
    let i18n_name: String?
    var parent: TikTokJobCategory?
}

final class TikTokCityInfo: Codable {
    let code: String
    let en_name: String?
    var parent: TikTokCityInfo?
}

//
//  SnapFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/30/25.
//

import Foundation

actor SnapFetcher: JobFetcherProtocol, URLBasedJobFetcherProtocol {
    private let apiURL = URL(string: "https://careers.snap.com/api/jobs")!
    private let trackingService = JobTrackingService.shared

    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {

        let trackingData = await trackingService.loadTrackingData(for: "snap")
        let currentDate = Date()

        let jobs = try await fetchAllJobs(trackingData: trackingData, currentDate: currentDate)

        let locationKeywords = location.parseAsFilterKeywords()
        let filteredJobs = jobs.applying(titleKeywords: titleKeywords, locationKeywords: locationKeywords)

        await trackingService.saveTrackingData(filteredJobs, for: "snap", currentDate: currentDate, retentionDays: 30)

        FetcherLog.info("Snap", "Fetched \(jobs.count) total, \(filteredJobs.count) after filtering")
        return filteredJobs
    }
    
    private func fetchAllJobs(trackingData: [String: Date], currentDate: Date) async throws -> [Job] {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        
        components.queryItems = [
            URLQueryItem(name: "location", value: ""),
            URLQueryItem(name: "role", value: ""),
            URLQueryItem(name: "team", value: ""),
            URLQueryItem(name: "type", value: "")
        ]
        
        guard let url = components.url else {
            throw FetchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            FetcherLog.error("Snap", "HTTP \(httpResponse.statusCode)")
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoded: SnapResponse
        do {
            decoded = try JSONDecoder().decode(SnapResponse.self, from: data)
        } catch {
            FetcherLog.error("Snap", "Decoding error: \(error.localizedDescription)")
            throw FetchError.decodingError(details: "Failed to decode Snap response: \(error.localizedDescription)")
        }
        
        let jobs = decoded.body.compactMap { snapJob -> Job? in
            guard let source = snapJob._source else { return nil }

            let title = source.title ?? "Untitled Position"
            guard !title.isEmpty else { return nil }
            
            let locationString = buildLocationString(from: source)
            
            let jobURL = source.absolute_url ?? "https://careers.snap.com/jobs/\(snapJob._id)"
            
            var workFlexibility: String? = nil
            if let offices = source.offices, offices.contains(where: { $0.name?.lowercased().contains("remote") ?? false }) {
                workFlexibility = "Remote"
            }
            
            let jobId = "snap-\(snapJob._id)"
            let firstSeenDate = trackingData[jobId] ?? currentDate
            
            return Job(
                id: jobId,
                title: title,
                location: locationString,
                postingDate: nil,
                url: jobURL,
                description: source.jobDescription ?? "",
                workSiteFlexibility: workFlexibility,
                source: .snap,
                companyName: "Snap Inc.",
                department: source.departments,
                category: source.role,
                firstSeenDate: firstSeenDate,
                originalPostingDate: nil,
                wasBumped: false
            )
        }
        
        return jobs
    }
    
    private func buildLocationString(from source: SnapJobSource) -> String {
        if let primaryLocation = source.primary_location, !primaryLocation.isEmpty {
            return primaryLocation
        }
        
        if let offices = source.offices, !offices.isEmpty {
            let locations = offices.compactMap { office -> String? in
                if let name = office.name, !name.isEmpty {
                    return name
                } else if let location = office.location, !location.isEmpty {
                    return location
                }
                return nil
            }
            
            if !locations.isEmpty {
                return locations.joined(separator: " / ")
            }
        }
        
        return "Location not specified"
    }
    
    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let titleKeywords = titleFilter.parseAsFilterKeywords()

        let trackingData = await trackingService.loadTrackingData(for: "snap")
        let currentDate = Date()

        let jobs = try await fetchAllJobs(trackingData: trackingData, currentDate: currentDate)

        let locationKeywords = locationFilter.parseAsFilterKeywords()
        let filteredJobs = jobs.applying(titleKeywords: titleKeywords, locationKeywords: locationKeywords)

        await trackingService.saveTrackingData(filteredJobs, for: "snap", currentDate: currentDate, retentionDays: 30)

        return filteredJobs
    }
}

// MARK: - Snap API Models

struct SnapResponse: Codable {
    let body: [SnapJob]
}

struct SnapJob: Codable {
    let _index: String?
    let _type: String?
    let _id: String
    let _score: Double?
    let _ignored: [String]?
    let _source: SnapJobSource?
}

struct SnapJobSource: Codable {
    let employment_type: String?
    let role: String?
    let offices: [SnapOffice]?
    let primary_location: String?
    let External_Posting: String?
    let absolute_url: String?
    let departments: String?
    let id: String?
    let title: String?
    let jobPostingSite: String?
    let jobDescription: String?
}

struct SnapOffice: Codable {
    let name: String?
    let location: String?
}

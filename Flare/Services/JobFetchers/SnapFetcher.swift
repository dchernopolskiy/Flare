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

        let filteredJobs = applyFilters(jobs: jobs, titleKeywords: titleKeywords, location: location)

        await trackingService.saveTrackingData(filteredJobs, for: "snap", currentDate: currentDate, retentionDays: 30)
        
        print("[Snap] Fetched \(jobs.count) total jobs, \(filteredJobs.count) after filtering")
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
        
        print("[Snap] Fetching from: \(url)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            if let errorString = String(data: data, encoding: .utf8) {
                print("[Snap] Error response: \(errorString.prefix(200))")
            }
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }
        
        let decoded: SnapResponse
        do {
            decoded = try JSONDecoder().decode(SnapResponse.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            print("[Snap] Missing key '\(key.stringValue)' at: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
            if let responseString = String(data: data, encoding: .utf8) {
                print("[Snap] Response preview: \(responseString.prefix(500))")
            }
            throw FetchError.decodingError(details: "Missing field '\(key.stringValue)' in Snap response")
        } catch {
            print("[Snap] Decoding error: \(error)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("[Snap] Response preview: \(responseString.prefix(500))")
            }
            throw FetchError.decodingError(details: "Failed to decode Snap response: \(error.localizedDescription)")
        }
        
        let jobs = decoded.body.enumerated().compactMap { (index, snapJob) -> Job? in
            guard let source = snapJob._source else {
                print("[Snap] Skipping job at index \(index): missing _source")
                return nil
            }
            
            let title = source.title ?? "Untitled Position"
            guard !title.isEmpty else {
                print("[Snap] Skipping job at index \(index): empty title")
                return nil
            }
            
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

        let trackingData = await trackingService.loadTrackingData(for: "snap")
        let currentDate = Date()

        let jobs = try await fetchAllJobs(trackingData: trackingData, currentDate: currentDate)

        let filteredJobs = applyFilters(jobs: jobs, titleKeywords: titleKeywords, location: locationFilter)

        await trackingService.saveTrackingData(filteredJobs, for: "snap", currentDate: currentDate, retentionDays: 30)

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

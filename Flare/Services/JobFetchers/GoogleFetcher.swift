//
//  GoogleFetcher.swift
//  Flare
//
//  Created by Claude on 1/2/25.
//

import Foundation

actor GoogleFetcher: URLBasedJobFetcherProtocol {
    private let baseURL = "https://www.google.com/about/careers/applications/jobs/results"
    private let trackingService = JobTrackingService.shared

    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let trackingData = await trackingService.loadTrackingData(for: "google")
        let currentDate = Date()
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents(string: baseURL)!

        if !titleFilter.isEmpty {
            components.queryItems = components.queryItems ?? []
            components.queryItems?.append(URLQueryItem(name: "q", value: titleFilter))
        }

        if !locationFilter.isEmpty {
            components.queryItems = components.queryItems ?? []
            components.queryItems?.append(URLQueryItem(name: "location", value: locationFilter))
        }

        components.queryItems = components.queryItems ?? []
        components.queryItems?.append(URLQueryItem(name: "sort_by", value: "date"))

        guard let finalURL = components.url else {
            throw FetchError.invalidURL
        }

        var request = URLRequest(url: finalURL)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        print("[Google] Fetching from: \(finalURL)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            print("[Google] HTTP error: \(httpResponse.statusCode)")
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw FetchError.decodingError(details: "Failed to decode HTML response")
        }

        let jobs = parseHTML(html, baseURL: url, trackingData: trackingData, currentDate: currentDate)

        await trackingService.saveTrackingData(jobs, for: "google", currentDate: currentDate, retentionDays: 30)

        print("[Google] Fetched \(jobs.count) jobs")
        return jobs
    }

    private func parseHTML(_ html: String, baseURL: URL, trackingData: [String: Date], currentDate: Date) -> [Job] {
        var jobs: [Job] = []

        // Pattern: <li class="lLd3Je" ssk='18:103872267078771398'>
        let jobPattern = #"<li class="lLd3Je" ssk='[^']*'>.*?</li>"#

        guard let jobRegex = try? NSRegularExpression(pattern: jobPattern, options: [.dotMatchesLineSeparators]) else {
            print("[Google] Failed to create job regex")
            return []
        }

        let matches = jobRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches.prefix(100) { // Limit to 100 jobs
            guard let range = Range(match.range, in: html) else { continue }
            let jobHTML = String(html[range])

            if let job = parseJobListing(jobHTML, baseURL: baseURL, trackingData: trackingData, currentDate: currentDate) {
                jobs.append(job)
            }
        }

        return jobs
    }

    private func parseJobListing(_ html: String, baseURL: URL, trackingData: [String: Date], currentDate: Date) -> Job? {
        var jobId: String?
        if let sskMatch = html.range(of: #"ssk='([^']+)'"#, options: .regularExpression) {
            let sskValue = String(html[sskMatch])
                .replacingOccurrences(of: "ssk='", with: "")
                .replacingOccurrences(of: "'", with: "")
            jobId = "google-\(sskValue)"
        }

        var title: String?
        if let titleMatch = html.range(of: #"<h3 class="QJPWVe">([^<]+)</h3>"#, options: .regularExpression) {
            title = extractText(from: String(html[titleMatch]), pattern: #">([^<]+)<"#)
        }

        var location: String?
        if let locationMatch = html.range(of: #"<span class="r0wTof[^"]*">([^<]+)</span>"#, options: .regularExpression) {
            location = extractText(from: String(html[locationMatch]), pattern: #">([^<]+)<"#)
        }

        var jobURL: String?
        if let urlMatch = html.range(of: #"<a class="WpHeLc[^"]*" href="([^"]+)""#, options: .regularExpression) {
            let path = extractText(from: String(html[urlMatch]), pattern: #"href="([^"]+)""#)
            if let path = path {
                if path.hasPrefix("http") {
                    jobURL = path
                } else {
                    jobURL = "https://www.google.com/about/careers/applications/\(path)"
                }
            }
        }

        var experienceLevel: String?
        if html.contains(#"<span class="wVSTAb">Advanced</span>"#) {
            experienceLevel = "Advanced"
        } else if html.contains(#"<span class="wVSTAb">Entry</span>"#) {
            experienceLevel = "Entry"
        } else if html.contains(#"<span class="wVSTAb">Mid</span>"#) {
            experienceLevel = "Mid"
        }

        var description = ""
        let qualPattern = #"<h4>Minimum qualifications</h4>.*?</ul>"#
        if let qualRegex = try? NSRegularExpression(pattern: qualPattern, options: [.dotMatchesLineSeparators]),
           let match = qualRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range, in: html) {
            description = String(html[range])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let jobTitle = title, !jobTitle.isEmpty,
              let finalJobId = jobId else {
            print("[Google] Skipping job: missing required fields")
            return nil
        }

        let firstSeenDate = trackingData[finalJobId] ?? currentDate

        return Job(
            id: finalJobId,
            title: jobTitle,
            location: location ?? "Not specified",
            postingDate: nil,
            url: jobURL ?? "https://careers.google.com",
            description: description,
            workSiteFlexibility: nil,
            source: .google,
            companyName: "Google",
            department: nil,
            category: experienceLevel,
            firstSeenDate: firstSeenDate,
            originalPostingDate: nil,
            wasBumped: false
        )
    }

    private func extractText(from html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        if let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }
}

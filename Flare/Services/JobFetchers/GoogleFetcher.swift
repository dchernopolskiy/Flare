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

        // Try to extract jobs from embedded JSON data first
        var jobs = parseEmbeddedJSON(html, trackingData: trackingData, currentDate: currentDate)

        // Fallback to HTML parsing if JSON extraction fails
        if jobs.isEmpty {
            print("[Google] JSON extraction failed, falling back to HTML parsing")
            jobs = parseHTML(html, baseURL: url, trackingData: trackingData, currentDate: currentDate)
        }

        await trackingService.saveTrackingData(jobs, for: "google", currentDate: currentDate, retentionDays: 30)

        print("[Google] Fetched \(jobs.count) jobs")
        return jobs
    }

    // MARK: - Embedded JSON Parsing

    /// Parse jobs from the embedded JSON data structure in Google's career pages
    /// The data is in format: data: [[[jobId, title, url, ...], ...], null, count, pageSize]
    private func parseEmbeddedJSON(_ html: String, trackingData: [String: Date], currentDate: Date) -> [Job] {
        var jobs: [Job] = []

        // Look for the data array pattern - it starts after "data:" and contains job arrays
        // Pattern: data: [[["jobId", "title", "url", ...], ...
        guard let dataStart = html.range(of: "data: [[") else {
            print("[Google] No embedded data array found")
            return []
        }

        // Find the end of the data array by counting brackets
        let searchStart = dataStart.lowerBound
        var depth = 0
        var inString = false
        var escapeNext = false
        var dataEnd: String.Index?
        var foundStart = false

        for i in html.indices[searchStart...] {
            let char = html[i]

            if escapeNext {
                escapeNext = false
                continue
            }

            if char == "\\" && inString {
                escapeNext = true
                continue
            }

            if char == "\"" {
                inString = !inString
                continue
            }

            if !inString {
                if char == "[" {
                    if !foundStart {
                        foundStart = true
                    }
                    depth += 1
                } else if char == "]" {
                    depth -= 1
                    if depth == 0 && foundStart {
                        dataEnd = html.index(after: i)
                        break
                    }
                }
            }
        }

        guard let endIndex = dataEnd else {
            print("[Google] Could not find end of data array")
            return []
        }

        // Extract just the array portion (skip "data: ")
        let dataStartIndex = html.index(dataStart.lowerBound, offsetBy: 6) // Skip "data: "
        let jsonString = String(html[dataStartIndex..<endIndex])

        // Unescape unicode sequences
        let unescapedJSON = jsonString
            .replacingOccurrences(of: "\\u003d", with: "=")
            .replacingOccurrences(of: "\\u003c", with: "<")
            .replacingOccurrences(of: "\\u003e", with: ">")
            .replacingOccurrences(of: "\\u0026", with: "&")

        guard let jsonData = unescapedJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [Any],
              let jobsArray = parsed.first as? [[Any]] else {
            print("[Google] Failed to parse embedded JSON")
            return []
        }

        print("[Google] Found \(jobsArray.count) jobs in embedded JSON")

        for jobArray in jobsArray {
            guard jobArray.count >= 8 else { continue }

            // Structure: [jobId, title, url, [responsibilities], [qualifications], company, locale, [locations], ...]
            guard let jobId = jobArray[0] as? String,
                  let title = jobArray[1] as? String,
                  let rawURL = jobArray[2] as? String else {
                continue
            }

            // Build full URL from relative path
            let url: String
            if rawURL.hasPrefix("http") {
                url = rawURL
            } else if rawURL.hasPrefix("/") {
                url = "https://www.google.com\(rawURL)"
            } else {
                url = "https://www.google.com/about/careers/applications/\(rawURL)"
            }

            // Extract location from the locations array (index 7)
            var location = "Not specified"
            if jobArray.count > 7, let locationsArray = jobArray[7] as? [[Any]] {
                let locationStrings = locationsArray.compactMap { locArray -> String? in
                    // First element is the location string like "New York, NY, USA"
                    return locArray.first as? String
                }
                if !locationStrings.isEmpty {
                    location = locationStrings.joined(separator: "; ")
                }
            }

            // Extract description from responsibilities (index 3) and qualifications (index 4)
            var description = ""
            if jobArray.count > 4 {
                if let respArray = jobArray[3] as? [Any], respArray.count > 1,
                   let responsibilities = respArray[1] as? String {
                    description = stripHTML(responsibilities)
                }
                if let qualArray = jobArray[4] as? [Any], qualArray.count > 1,
                   let qualifications = qualArray[1] as? String {
                    let qualText = stripHTML(qualifications)
                    if !description.isEmpty {
                        description += "\n\n"
                    }
                    description += qualText
                }
            }

            // Extract experience level from the experience array (index 10 if present)
            var experienceLevel: String?
            if jobArray.count > 10, let expArray = jobArray[10] as? [Int] {
                // Experience levels: 2 = Mid, 3 = Senior, 4 = Lead/Staff
                if expArray.contains(4) {
                    experienceLevel = "Lead/Staff"
                } else if expArray.contains(3) {
                    experienceLevel = "Senior"
                } else if expArray.contains(2) {
                    experienceLevel = "Mid"
                }
            }

            let fullJobId = "google-\(jobId)"
            let firstSeenDate = trackingData[fullJobId] ?? currentDate

            let job = Job(
                id: fullJobId,
                title: title,
                location: location,
                postingDate: nil,
                url: url,
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
            jobs.append(job)
        }

        return jobs
    }

    private func stripHTML(_ html: String) -> String {
        return html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTML Parsing (Fallback)

    private func parseHTML(_ html: String, baseURL: URL, trackingData: [String: Date], currentDate: Date) -> [Job] {
        var jobs: [Job] = []

        // Pattern: <li class="lLd3Je" ssk='18:103872267078771398'>
        let jobPattern = #"<li class="lLd3Je" ssk='[^']*'>.*?</li>"#

        guard let jobRegex = try? NSRegularExpression(pattern: jobPattern, options: [.dotMatchesLineSeparators]) else {
            print("[Google] Failed to create job regex")
            return []
        }

        let matches = jobRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches.prefix(100) {
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
        let locationPattern = #"<span class="r0wTof[^"]*">([^<]+)</span>"#
        if let locationRegex = try? NSRegularExpression(pattern: locationPattern, options: []) {
            let matches = locationRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            var locations: [String] = []
            for match in matches {
                if let range = Range(match.range, in: html),
                   let text = extractText(from: String(html[range]), pattern: #">([^<]+)<"#) {
                    let cleaned = text.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "^;\\s*", with: "", options: .regularExpression)
                    if !cleaned.isEmpty && !locations.contains(cleaned) {
                        locations.append(cleaned)
                    }
                }
            }
            location = locations.joined(separator: "; ")
        }

        var jobURL: String?
        if let urlMatch = html.range(of: #"<a class="WpHeLc[^"]*" href="([^"]+)""#, options: .regularExpression) {
            let path = extractText(from: String(html[urlMatch]), pattern: #"href="([^"]+)""#)
            if let path = path {
                if path.hasPrefix("http") {
                    jobURL = path
                } else if path.hasPrefix("/") {
                    jobURL = "https://www.google.com\(path)"
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

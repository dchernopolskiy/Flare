//
//  GoogleFetcher.swift
//  Flare
//

import Foundation

actor GoogleFetcher: URLBasedJobFetcherProtocol {
    private let baseURL = "https://www.google.com/about/careers/applications/jobs/results"
    private let trackingService = JobTrackingService.shared
    private let maxPages = 5

    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let trackingData = await trackingService.loadTrackingData(for: "google")
        let currentDate = Date()

        var allJobs = try await fetchAllPages(url: url, titleFilter: titleFilter, locationFilter: locationFilter, trackingData: trackingData, currentDate: currentDate)

        if shouldIncludeRemote(for: locationFilter),
           !locationFilter.isEmpty,
           !locationFilter.localizedCaseInsensitiveContains("remote") {
            let remoteJobs = try await fetchAllPages(url: url, titleFilter: titleFilter, locationFilter: "Remote", trackingData: trackingData, currentDate: currentDate)
            allJobs = allJobs.merging(remoteJobs)
        }

        await trackingService.saveTrackingData(allJobs, for: "google", currentDate: currentDate, retentionDays: 30)
        FetcherLog.info("Google", "Fetched \(allJobs.count) total jobs")
        return allJobs
    }

    private func fetchAllPages(url: URL, titleFilter: String, locationFilter: String, trackingData: [String: Date], currentDate: Date) async throws -> [Job] {
        var allJobs: [Job] = []
        var seenJobIds = Set<String>()

        for page in 1...maxPages {
            let pageJobs = try await fetchPage(page: page, url: url, titleFilter: titleFilter, locationFilter: locationFilter, trackingData: trackingData, currentDate: currentDate)
            let newJobs = pageJobs.filter { !seenJobIds.contains($0.id) }
            newJobs.forEach { seenJobIds.insert($0.id) }
            allJobs.append(contentsOf: newJobs)

            FetcherLog.debug("Google", "Page \(page): \(pageJobs.count) jobs (\(newJobs.count) new)")
            if pageJobs.count < 15 { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return allJobs
    }

    private func fetchPage(page: Int, url: URL, titleFilter: String, locationFilter: String, trackingData: [String: Date], currentDate: Date) async throws -> [Job] {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents(string: baseURL)!
        var queryItems: [URLQueryItem] = []

        if !titleFilter.isEmpty { queryItems.append(URLQueryItem(name: "q", value: titleFilter)) }
        if !locationFilter.isEmpty { queryItems.append(URLQueryItem(name: "location", value: locationFilter)) }
        queryItems.append(URLQueryItem(name: "sort_by", value: "date"))
        if page > 1 { queryItems.append(URLQueryItem(name: "page", value: String(page))) }
        components.queryItems = queryItems

        guard let finalURL = components.url else { throw FetchError.invalidURL }

        var request = URLRequest(url: finalURL)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw FetchError.invalidResponse
        }

        var jobs = parseEmbeddedJSON(html, trackingData: trackingData, currentDate: currentDate)
        if jobs.isEmpty {
            jobs = parseHTML(html, baseURL: url, trackingData: trackingData, currentDate: currentDate)
        }
        return jobs
    }

    private func parseEmbeddedJSON(_ html: String, trackingData: [String: Date], currentDate: Date) -> [Job] {
        var jobs: [Job] = []

        guard let dataStart = html.range(of: "data: [[") else { return [] }

        let searchStart = dataStart.lowerBound
        var depth = 0, inString = false, escapeNext = false, foundStart = false
        var dataEnd: String.Index?

        for i in html.indices[searchStart...] {
            let char = html[i]
            if escapeNext { escapeNext = false; continue }
            if char == "\\" && inString { escapeNext = true; continue }
            if char == "\"" { inString = !inString; continue }
            if !inString {
                if char == "[" { if !foundStart { foundStart = true }; depth += 1 }
                else if char == "]" { depth -= 1; if depth == 0 && foundStart { dataEnd = html.index(after: i); break } }
            }
        }

        guard let endIndex = dataEnd else { return [] }

        let dataStartIndex = html.index(dataStart.lowerBound, offsetBy: 6)
        let jsonString = String(html[dataStartIndex..<endIndex])
        let unescapedJSON = jsonString
            .replacingOccurrences(of: "\\u003d", with: "=")
            .replacingOccurrences(of: "\\u003c", with: "<")
            .replacingOccurrences(of: "\\u003e", with: ">")
            .replacingOccurrences(of: "\\u0026", with: "&")

        guard let jsonData = unescapedJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [Any],
              let jobsArray = parsed.first as? [[Any]] else { return [] }

        for jobArray in jobsArray {
            guard jobArray.count >= 8,
                  let rawJobId = jobArray[0] as? String,
                  let title = jobArray[1] as? String else { continue }

            let jobId = rawJobId.contains(":") ? String(rawJobId.split(separator: ":").last ?? Substring(rawJobId)) : rawJobId
            let url = "https://www.google.com/about/careers/applications/jobs/results/\(jobId)-\(title.toURLSlug())"

            var location = "Not specified"
            if jobArray.count > 7, let locationsArray = jobArray[7] as? [[Any]] {
                let locationStrings = locationsArray.compactMap { $0.first as? String }
                if !locationStrings.isEmpty { location = locationStrings.joined(separator: "; ") }
            }

            var description = ""
            if jobArray.count > 4 {
                if let respArray = jobArray[3] as? [Any], respArray.count > 1, let resp = respArray[1] as? String {
                    description = stripHTML(resp)
                }
                if let qualArray = jobArray[4] as? [Any], qualArray.count > 1, let qual = qualArray[1] as? String {
                    if !description.isEmpty { description += "\n\n" }
                    description += stripHTML(qual)
                }
            }

            var experienceLevel: String?
            if jobArray.count > 10, let expArray = jobArray[10] as? [Int] {
                if expArray.contains(4) { experienceLevel = "Lead/Staff" }
                else if expArray.contains(3) { experienceLevel = "Senior" }
                else if expArray.contains(2) { experienceLevel = "Mid" }
            }

            let fullJobId = "google-\(jobId)"
            jobs.append(Job(
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
                firstSeenDate: trackingData[fullJobId] ?? currentDate,
                originalPostingDate: nil,
                wasBumped: false
            ))
        }
        return jobs
    }

    private func stripHTML(_ html: String) -> String { HTMLCleaner.cleanHTML(html) }

    private func parseHTML(_ html: String, baseURL: URL, trackingData: [String: Date], currentDate: Date) -> [Job] {
        var jobs: [Job] = []
        let jobPattern = #"<li class="lLd3Je" ssk='[^']*'>.*?</li>"#

        guard let jobRegex = try? NSRegularExpression(pattern: jobPattern, options: .dotMatchesLineSeparators) else { return [] }
        let matches = jobRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches.prefix(100) {
            guard let range = Range(match.range, in: html) else { continue }
            if let job = parseJobListing(String(html[range]), baseURL: baseURL, trackingData: trackingData, currentDate: currentDate) {
                jobs.append(job)
            }
        }
        return jobs
    }

    private func parseJobListing(_ html: String, baseURL: URL, trackingData: [String: Date], currentDate: Date) -> Job? {
        var jobId: String?
        if let sskMatch = html.range(of: #"ssk='([^']+)'"#, options: .regularExpression) {
            var sskValue = String(html[sskMatch]).replacingOccurrences(of: "ssk='", with: "").replacingOccurrences(of: "'", with: "")
            if sskValue.contains(":") { sskValue = String(sskValue.split(separator: ":").last ?? Substring(sskValue)) }
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
                    let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^;\\s*", with: "", options: .regularExpression)
                    if !cleaned.isEmpty && !locations.contains(cleaned) { locations.append(cleaned) }
                }
            }
            location = locations.joined(separator: "; ")
        }

        var jobURL: String?
        if let jobTitle = title, let sskValue = jobId?.replacingOccurrences(of: "google-", with: "") {
            jobURL = "https://www.google.com/about/careers/applications/jobs/results/\(sskValue)-\(jobTitle.toURLSlug())"
        }

        var experienceLevel: String?
        if html.contains(#"<span class="wVSTAb">Advanced</span>"#) { experienceLevel = "Advanced" }
        else if html.contains(#"<span class="wVSTAb">Entry</span>"#) { experienceLevel = "Entry" }
        else if html.contains(#"<span class="wVSTAb">Mid</span>"#) { experienceLevel = "Mid" }

        var description = ""
        let qualPattern = #"<h4>Minimum qualifications</h4>.*?</ul>"#
        if let qualRegex = try? NSRegularExpression(pattern: qualPattern, options: .dotMatchesLineSeparators),
           let match = qualRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range, in: html) {
            description = String(html[range]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let jobTitle = title, !jobTitle.isEmpty, let finalJobId = jobId else { return nil }

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
            firstSeenDate: trackingData[finalJobId] ?? currentDate,
            originalPostingDate: nil,
            wasBumped: false
        )
    }

    private func extractText(from html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return HTMLCleaner.cleanHTML(String(html[range]))
    }

    private func shouldIncludeRemote(for locationFilter: String) -> Bool {
        if locationFilter.localizedCaseInsensitiveContains("remote") {
            return true
        }
        return UserDefaults.standard.object(forKey: "includeRemoteJobs") as? Bool ?? true
    }
}

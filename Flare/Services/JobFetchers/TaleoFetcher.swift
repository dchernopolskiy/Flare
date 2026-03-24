//
//  TaleoFetcher.swift
//  Flare
//

import Foundation

actor TaleoFetcher: URLBasedJobFetcherProtocol {
    private let trackingService = JobTrackingService.shared

    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let companySlug = extractCompanySlug(from: url)
        let careerSection = extractCareerSection(from: url)
        let storedJobDates = await trackingService.loadTrackingData(for: "taleo_\(companySlug)")
        let currentDate = Date()

        var allJobs: [Job] = []
        if let apiJobs = try? await fetchFromAPI(url: url, companySlug: companySlug, careerSection: careerSection, storedJobDates: storedJobDates, currentDate: currentDate) {
            allJobs = apiJobs
        } else {
            allJobs = try await fetchFromHTML(url: url, companySlug: companySlug, storedJobDates: storedJobDates, currentDate: currentDate)
        }

        let titleKeywords = titleFilter.parseAsFilterKeywords()
        let locationKeywords = locationFilter.parseAsFilterKeywords().includingRemote()
        let filteredJobs = allJobs.applying(titleKeywords: titleKeywords, locationKeywords: locationKeywords)

        FetcherLog.info("Taleo", "Fetched \(allJobs.count) total, \(filteredJobs.count) after filtering for \(companySlug)")
        await trackingService.saveTrackingData(filteredJobs, for: "taleo_\(companySlug)", currentDate: currentDate, retentionDays: 30)
        return filteredJobs
    }

    private func fetchFromAPI(url: URL, companySlug: String, careerSection: String, storedJobDates: [String: Date], currentDate: Date) async throws -> [Job] {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw FetchError.invalidURL
        }

        components.path = "/careersection/rest/jobboard/searchjobs"
        components.queryItems = [
            URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "portal", value: careerSection)
        ]

        guard let apiURL = components.url else { throw FetchError.invalidURL }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let searchBody: [String: Any] = [
            "multilineEnabled": false,
            "sortingSelection": ["sortBySelectionParam": "5", "ascendingSortingOrder": "false"],
            "fieldData": ["fields": [:], "valid": true],
            "filterSelectionParam": ["searchFilterSelections": []],
            "advancedSearchFiltersSelectionParam": ["searchFilterSelections": []],
            "pageNo": 1,
            "pageSize": 100
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: searchBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw FetchError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return try parseAPIResponse(data, baseURL: url, companySlug: companySlug, careerSection: careerSection, storedJobDates: storedJobDates, currentDate: currentDate)
    }

    private func parseAPIResponse(_ data: Data, baseURL: URL, companySlug: String, careerSection: String, storedJobDates: [String: Date], currentDate: Date) throws -> [Job] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requisitionList = json["requisitionList"] as? [[String: Any]] else {
            throw FetchError.decodingError(details: "Failed to parse Taleo API response")
        }

        return requisitionList.compactMap { req -> Job? in
            guard let title = req["title"] as? String ?? req["jobTitle"] as? String,
                  let jobId = req["jobId"] as? String ?? req["contestNo"] as? String ?? (req["id"] as? Int).map(String.init) else {
                return nil
            }

            let location = extractLocation(from: req)
            let fullJobId = "taleo-\(companySlug)-\(jobId)"
            let postingDate = (req["postingDate"] as? String ?? req["postedDate"] as? String).flatMap { parseDate($0) }

            return Job(
                id: fullJobId,
                title: title,
                location: location,
                postingDate: postingDate,
                url: buildJobURL(baseURL: baseURL, careerSection: careerSection, jobId: jobId),
                description: req["description"] as? String ?? req["jobDescription"] as? String ?? "",
                workSiteFlexibility: WorkFlexibility.extract(from: "\(title) \(location)"),
                source: .taleo,
                companyName: companySlug.replacingOccurrences(of: "-", with: " ").capitalized,
                department: req["department"] as? String ?? req["organization"] as? String,
                category: req["jobFamily"] as? String ?? req["category"] as? String,
                firstSeenDate: storedJobDates[fullJobId] ?? currentDate,
                originalPostingDate: postingDate,
                wasBumped: false
            )
        }
    }

    private func fetchFromHTML(url: URL, companySlug: String, storedJobDates: [String: Date], currentDate: Date) async throws -> [Job] {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw FetchError.invalidResponse
        }

        return parseJobsFromHTML(html, baseURL: url, companySlug: companySlug, storedJobDates: storedJobDates, currentDate: currentDate)
    }

    private func parseJobsFromHTML(_ html: String, baseURL: URL, companySlug: String, storedJobDates: [String: Date], currentDate: Date) -> [Job] {
        var jobs: [Job] = []
        let patterns = [
            #"<a[^>]*href="[^"]*jobdetail\.ftl\?job=(\d+)[^"]*"[^>]*>([^<]+)</a>"#,
            #"<a[^>]*onclick="[^"]*requisitionId[=:](\d+)[^"]*"[^>]*>([^<]+)</a>"#,
            #"data-requisitionid="(\d+)"[^>]*>[\s\S]*?<span[^>]*class="[^"]*jobTitle[^"]*"[^>]*>([^<]+)</span>"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

            for match in matches {
                guard match.numberOfRanges >= 3,
                      let idRange = Range(match.range(at: 1), in: html),
                      let titleRange = Range(match.range(at: 2), in: html) else { continue }

                let jobIdString = String(html[idRange])
                let title = HTMLCleaner.cleanHTML(String(html[titleRange])).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }

                let fullJobId = "taleo-\(companySlug)-\(jobIdString)"
                if jobs.contains(where: { $0.id == fullJobId }) { continue }

                let careerSection = extractCareerSection(from: baseURL)
                jobs.append(Job(
                    id: fullJobId,
                    title: title,
                    location: extractLocationFromHTML(html: html, jobId: jobIdString) ?? "See job details",
                    postingDate: nil,
                    url: buildJobURL(baseURL: baseURL, careerSection: careerSection, jobId: jobIdString),
                    description: "",
                    workSiteFlexibility: WorkFlexibility.extract(from: title),
                    source: .taleo,
                    companyName: companySlug.replacingOccurrences(of: "-", with: " ").capitalized,
                    department: nil,
                    category: nil,
                    firstSeenDate: storedJobDates[fullJobId] ?? currentDate,
                    originalPostingDate: nil,
                    wasBumped: false
                ))
            }
            if !jobs.isEmpty { break }
        }
        return jobs
    }

    private func extractLocation(from requisition: [String: Any]) -> String {
        if let location = requisition["location"] as? String, !location.isEmpty { return location }
        if let locationObj = requisition["location"] as? [String: Any] {
            let parts = [locationObj["city"], locationObj["state"], locationObj["country"]].compactMap { $0 as? String }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
        }
        if let locations = requisition["locations"] as? [[String: Any]], let first = locations.first {
            let parts = [first["city"], first["state"]].compactMap { $0 as? String }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
        }
        if let primaryLocation = requisition["primaryLocation"] as? String, !primaryLocation.isEmpty { return primaryLocation }
        return "See job details"
    }

    private func extractLocationFromHTML(html: String, jobId: String) -> String? {
        let pattern = #"requisitionId[=:]?\#(jobId)[\s\S]{0,800}?(?:location|city)[^>]*>([^<]+)<"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let location = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return location.isEmpty ? nil : location
    }

    private func buildJobURL(baseURL: URL, careerSection: String, jobId: String) -> String {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL.absoluteString
        }
        components.path = "/careersection/\(careerSection)/jobdetail.ftl"
        components.queryItems = [URLQueryItem(name: "job", value: jobId)]
        return components.url?.absoluteString ?? baseURL.absoluteString
    }

    private func extractCompanySlug(from url: URL) -> String {
        guard let host = url.host else { return "unknown" }
        if host.contains("taleo.net") {
            return host.components(separatedBy: ".").first ?? "unknown"
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let org = components.queryItems?.first(where: { $0.name == "org" })?.value {
            return org.lowercased()
        }
        return host.components(separatedBy: ".").first ?? "unknown"
    }

    private func extractCareerSection(from url: URL) -> String {
        let path = url.path
        if let range = path.range(of: "/careersection/") {
            let afterSection = path[range.upperBound...]
            if let endRange = afterSection.range(of: "/") {
                return String(afterSection[..<endRange.lowerBound])
            }
        }
        return "2"
    }

    private func parseDate(_ dateString: String) -> Date? {
        let formats = ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd", "MM/dd/yyyy"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            if let date = formatter.date(from: dateString) { return date }
        }
        return ISO8601DateFormatter().date(from: dateString)
    }
}

//
//  iCIMSFetcher.swift
//  Flare
//

import Foundation

actor iCIMSFetcher: URLBasedJobFetcherProtocol {
    private let trackingService = JobTrackingService.shared

    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let companySlug = extractCompanySlug(from: url)
        let storedJobDates = await trackingService.loadTrackingData(for: "icims_\(companySlug)")
        let currentDate = Date()

        var allJobs: [Job] = []

        for page in 1...10 {
            let pageJobs = try await fetchPage(page, baseURL: url, companySlug: companySlug, storedJobDates: storedJobDates, currentDate: currentDate)
            if pageJobs.isEmpty { break }
            allJobs.append(contentsOf: pageJobs)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let titleKeywords = titleFilter.parseAsFilterKeywords()
        let locationKeywords = locationFilter.parseAsFilterKeywords().includingRemote()
        let filteredJobs = allJobs.applying(titleKeywords: titleKeywords, locationKeywords: locationKeywords)

        FetcherLog.info("iCIMS", "Fetched \(allJobs.count) total, \(filteredJobs.count) after filtering")
        await trackingService.saveTrackingData(filteredJobs, for: "icims_\(companySlug)", currentDate: currentDate, retentionDays: 30)
        return filteredJobs
    }

    private func fetchPage(_ page: Int, baseURL: URL, companySlug: String, storedJobDates: [String: Date], currentDate: Date) async throws -> [Job] {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw FetchError.invalidURL
        }

        components.path = "/jobs/search"
        components.queryItems = [
            URLQueryItem(name: "pr", value: String(page)),
            URLQueryItem(name: "searchRadius", value: "50"),
            URLQueryItem(name: "in_iframe", value: "1"),
            URLQueryItem(name: "mode", value: "job")
        ]

        guard let searchURL = components.url else { throw FetchError.invalidURL }

        var request = URLRequest(url: searchURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw FetchError.invalidResponse
        }

        return parseJobs(html, baseURL: baseURL, companySlug: companySlug, storedJobDates: storedJobDates, currentDate: currentDate)
    }

    private func parseJobs(_ html: String, baseURL: URL, companySlug: String, storedJobDates: [String: Date], currentDate: Date) -> [Job] {
        var jobs: [Job] = []

        let patterns = [
            #"<a[^>]*href="(/jobs/(\d+)/job[^"]*)"[^>]*class="[^"]*iCIMS_Anchor[^"]*"[^>]*>([^<]+)</a>"#,
            #"<div[^>]*class="[^"]*iCIMS_JobsTable[^"]*"[^>]*>[\s\S]*?<a[^>]*href="([^"]+/jobs/(\d+)/[^"]*)"[^>]*>([^<]+)</a>"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

            for match in matches {
                guard match.numberOfRanges >= 4,
                      let pathRange = Range(match.range(at: 1), in: html),
                      let idRange = Range(match.range(at: 2), in: html),
                      let titleRange = Range(match.range(at: 3), in: html) else { continue }

                let path = String(html[pathRange])
                let jobIdStr = String(html[idRange])
                let title = HTMLCleaner.cleanHTML(String(html[titleRange])).trimmingCharacters(in: .whitespacesAndNewlines)

                guard !title.isEmpty else { continue }

                let jobURL = path.hasPrefix("http") ? path : "https://\(baseURL.host ?? "")\(path)"
                let jobId = "icims-\(companySlug)-\(jobIdStr)"

                jobs.append(Job(
                    id: jobId,
                    title: title,
                    location: "See job details",
                    postingDate: nil,
                    url: jobURL,
                    description: "",
                    workSiteFlexibility: WorkFlexibility.extract(from: title),
                    source: .icims,
                    companyName: companySlug.replacingOccurrences(of: "-", with: " ").capitalized,
                    department: nil,
                    category: nil,
                    firstSeenDate: storedJobDates[jobId] ?? currentDate,
                    originalPostingDate: nil,
                    wasBumped: false
                ))
            }

            if !jobs.isEmpty { break }
        }

        return jobs
    }

    private func extractCompanySlug(from url: URL) -> String {
        guard let host = url.host, host.contains("icims.com") else { return "unknown" }
        let subdomain = host.replacingOccurrences(of: ".icims.com", with: "")
        return subdomain.hasPrefix("careers-") ? String(subdomain.dropFirst(8)) : subdomain
    }
}

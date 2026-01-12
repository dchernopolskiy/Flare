//
//  UniversalJobFetcher.swift
//  Flare
//
//  Created by Dan on 11/19/25.
//

import Foundation
import WebKit

actor UniversalJobFetcher: URLBasedJobFetcherProtocol {

    private let llmParser = LLMParser.shared

    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        FetcherLog.info("Universal", "Starting extraction from: \(url.absoluteString)")

        let isLLMEnabled = UserDefaults.standard.bool(forKey: "enableAIParser")

        let (html, extractedJobs) = try await extractFromJSON(url: url)

        if !extractedJobs.isEmpty {
            FetcherLog.info("Universal", "Found \(extractedJobs.count) jobs via JSON/API")
            let filtered = filterJobs(extractedJobs, titleFilter: titleFilter, locationFilter: locationFilter)

            if isLLMEnabled {
                let llmJobs = await tryLLMExtraction(html: html, url: url)
                if llmJobs.count > filtered.count {
                    FetcherLog.info("Universal", "LLM found more (\(llmJobs.count) vs \(filtered.count))")
                    return filterJobs(llmJobs, titleFilter: titleFilter, locationFilter: locationFilter)
                }
            }
            return filtered
        }

        if isLLMEnabled {
            if let llmAPIJobs = await tryLLMAPIDiscovery(html: html, url: url), !llmAPIJobs.isEmpty {
                return filterJobs(llmAPIJobs, titleFilter: titleFilter, locationFilter: locationFilter)
            }

            let llmJobs = await tryLLMExtraction(html: html, url: url)
            if !llmJobs.isEmpty {
                return filterJobs(llmJobs, titleFilter: titleFilter, locationFilter: locationFilter)
            }
        }

        let patternJobs = extractJobsFromHTMLPatterns(html: html, baseURL: url)
        if !patternJobs.isEmpty {
            FetcherLog.info("Universal", "HTML patterns found \(patternJobs.count) jobs")
            return filterJobs(patternJobs, titleFilter: titleFilter, locationFilter: locationFilter)
        }

        FetcherLog.warning("Universal", "No jobs found")
        return []
    }

    private func extractFromJSON(url: URL) async throws -> (html: String, jobs: [Job]) {
        let html = try await fetchHTML(from: url)

        var allJobs: [Job] = []

        let schemaJobs = extractFromSchemaOrg(html: html, baseURL: url)
        if !schemaJobs.isEmpty {
            FetcherLog.debug("Universal", "Schema.org found \(schemaJobs.count) jobs")
            allJobs.append(contentsOf: schemaJobs)
        }

        let nextDataJobs = extractFromNextData(html: html, baseURL: url)
        if !nextDataJobs.isEmpty {
            FetcherLog.debug("Universal", "__NEXT_DATA__ found \(nextDataJobs.count) jobs")
            allJobs = allJobs.merging(nextDataJobs)
        }

        let embeddedJobs = extractFromEmbeddedJSON(html: html, baseURL: url)
        if !embeddedJobs.isEmpty {
            FetcherLog.debug("Universal", "Embedded JSON found \(embeddedJobs.count) jobs")
            allJobs = allJobs.merging(embeddedJobs)
        }

        let apiJobs = try await discoverAndFetchAPI(baseURL: url)
        if !apiJobs.isEmpty {
            FetcherLog.debug("Universal", "API discovery found \(apiJobs.count) jobs")
            allJobs = allJobs.merging(apiJobs)
        }

        return (html, allJobs)
    }

    private func extractFromSchemaOrg(html: String, baseURL: URL) -> [Job] {
        var jobs: [Job] = []

        let jsonLDPattern = #"<script[^>]*type=["\']application/ld\+json["\'][^>]*>([\s\S]*?)</script>"#

        guard let regex = try? NSRegularExpression(pattern: jsonLDPattern, options: .caseInsensitive) else {
            return []
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard let contentRange = Range(match.range(at: 1), in: html) else { continue }
            let jsonString = String(html[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }

            let schemas: [[String: Any]]
            if let array = json as? [[String: Any]] {
                schemas = array
            } else if let single = json as? [String: Any] {
                schemas = [single]
            } else {
                continue
            }

            for schema in schemas {
                guard let type = schema["@type"] as? String,
                      type == "JobPosting" else { continue }

                guard let title = schema["title"] as? String else { continue }

                var location = "Not specified"
                if let jobLocation = schema["jobLocation"] as? [String: Any] {
                    if let address = jobLocation["address"] as? [String: Any] {
                        let parts = [
                            address["addressLocality"] as? String,
                            address["addressRegion"] as? String,
                            address["addressCountry"] as? String
                        ].compactMap { $0 }
                        if !parts.isEmpty {
                            location = parts.joined(separator: ", ")
                        }
                    } else if let name = jobLocation["name"] as? String {
                        location = name
                    }
                } else if let locationType = schema["jobLocationType"] as? String,
                          locationType.lowercased().contains("remote") {
                    location = "Remote"
                }

                var jobURL = baseURL.absoluteString
                if let url = schema["url"] as? String {
                    jobURL = url.hasPrefix("http") ? url : "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")\(url)"
                }

                var postingDate: Date?
                if let datePosted = schema["datePosted"] as? String {
                    postingDate = ISO8601DateFormatter().date(from: datePosted)
                }

                let description = schema["description"] as? String ?? ""
                let companyName = (schema["hiringOrganization"] as? [String: Any])?["name"] as? String
                    ?? extractCompanyName(from: baseURL)

                let job = Job(
                    id: "schema-\(UUID().uuidString)",
                    title: title,
                    location: location,
                    postingDate: postingDate,
                    url: jobURL,
                    description: HTMLCleaner.cleanHTML(description),
                    workSiteFlexibility: WorkFlexibility.extract(from: "\(title) \(location) \(description)"),
                    source: detectSource(from: baseURL),
                    companyName: companyName,
                    department: nil,
                    category: schema["occupationalCategory"] as? String,
                    firstSeenDate: Date(),
                    originalPostingDate: nil,
                    wasBumped: false
                )
                jobs.append(job)
            }
        }

        return jobs
    }

    private func extractFromNextData(html: String, baseURL: URL) -> [Job] {
        let pattern = #"<script[^>]*id=["\']__NEXT_DATA__["\'][^>]*>([\s\S]*?)</script>"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let contentRange = Range(match.range(at: 1), in: html) else {
            return []
        }

        let jsonString = String(html[contentRange])
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        guard let props = json["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any] else {
            return []
        }

        return extractJobsFromDict(pageProps, baseURL: baseURL, idPrefix: "next")
    }

    private func extractFromEmbeddedJSON(html: String, baseURL: URL) -> [Job] {
        var jobs: [Job] = []

        let patterns: [(pattern: String, name: String)] = [
            (#"window\.__PRELOAD_STATE__\s*=\s*(\{[\s\S]*?\})(?:;|\s*<)"#, "preload"),
            (#"window\.__INITIAL_STATE__\s*=\s*(\{[\s\S]*?\})(?:;|\s*<)"#, "initial"),
            (#"window\.__NUXT__\s*=\s*(\{[\s\S]*?\})(?:;|\s*<)"#, "nuxt"),
            (#"window\.pageData\s*=\s*(\{[\s\S]*?\})(?:;|\s*<)"#, "pageData"),
            (#"window\._initialData\s*=\s*(\{[\s\S]*?\})(?:;|\s*<)"#, "initialData"),
        ]

        for (pattern, name) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let contentRange = Range(match.range(at: 1), in: html) else {
                continue
            }

            let jsonString = String(html[contentRange])

            if let data = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let extracted = extractJobsFromDict(json, baseURL: baseURL, idPrefix: name)
                if !extracted.isEmpty {
                    FetcherLog.debug("Universal", "Found \(extracted.count) jobs in \(name) state")
                    jobs.append(contentsOf: extracted)
                    break // Use first successful extraction
                }
            }
        }

        return jobs
    }

    private func discoverAndFetchAPI(baseURL: URL) async throws -> [Job] {
        let apiPaths = [
            "/api/jobs",
            "/api/careers",
            "/api/positions",
            "/api/openings",
            "/api/v1/jobs",
            "/api/v2/jobs",
            "/careers/api/jobs",
            "/jobs.json",
            "/careers.json",
            "/api/get-jobs"
        ]

        for path in apiPaths {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { continue }
            components.path = path
            components.query = nil
            guard let apiURL = components.url else { continue }

            do {
                var request = URLRequest(url: apiURL)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 10

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
                      contentType.contains("json") else {
                    continue
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) else { continue }

                let jobs: [Job]
                if let array = json as? [[String: Any]] {
                    jobs = parseJobArray(array, baseURL: baseURL, idPrefix: "api")
                } else if let dict = json as? [String: Any] {
                    jobs = extractJobsFromDict(dict, baseURL: baseURL, idPrefix: "api")
                } else {
                    continue
                }

                if !jobs.isEmpty {
                    FetcherLog.debug("Universal", "API \(path) returned \(jobs.count) jobs")
                    return jobs
                }
            } catch {
                continue
            }
        }

        return []
    }

    private func extractJobsFromHTMLPatterns(html: String, baseURL: URL) -> [Job] {
        var jobs: [Job] = []
        var seenURLs = Set<String>()

        let linkPatterns = [
            #"<a[^>]*href="([^"]*(?:/jobs?/|/careers?/|/positions?/|/openings?/)[^"]+)"[^>]*>([^<]{5,150})</a>"#,
            #"<a[^>]*href="([^"]*)"[^>]*class="[^"]*job[^"]*"[^>]*>([^<]{5,150})</a>"#,
            #"<a[^>]*id="[^"]*job[^"]*"[^>]*href="([^"]+)"[^>]*>([^<]{5,150})</a>"#,
        ]

        for pattern in linkPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

            for match in matches {
                guard let urlRange = Range(match.range(at: 1), in: html),
                      let titleRange = Range(match.range(at: 2), in: html) else { continue }

                let jobUrl = String(html[urlRange])
                let title = HTMLCleaner.cleanHTML(String(html[titleRange]))

                let skipPatterns = ["next", "prev", "page", "load more", "view all", "see all", "apply"]
                if skipPatterns.contains(where: { title.lowercased().contains($0) }) { continue }
                if title.count < 5 { continue }

                let fullUrl = jobUrl.hasPrefix("http") ? jobUrl : "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")\(jobUrl)"

                if seenURLs.contains(fullUrl) { continue }
                seenURLs.insert(fullUrl)

                let job = Job(
                    id: "html-\(UUID().uuidString)",
                    title: title,
                    location: "See job details",
                    postingDate: nil,
                    url: fullUrl,
                    description: "",
                    workSiteFlexibility: WorkFlexibility.extract(from: title),
                    source: detectSource(from: baseURL),
                    companyName: extractCompanyName(from: baseURL),
                    department: nil,
                    category: nil,
                    firstSeenDate: Date(),
                    originalPostingDate: nil,
                    wasBumped: false
                )
                jobs.append(job)
            }

            if !jobs.isEmpty { break }
        }

        return jobs
    }

    private func fetchHTML(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let html = String(data: data, encoding: .utf8) else {
            throw FetchError.decodingError(details: "Failed to decode HTML")
        }

        return html
    }

    private func extractJobsFromDict(_ dict: [String: Any], baseURL: URL, idPrefix: String) -> [Job] {
        let jobArrayKeys = ["jobs", "results", "data", "items", "positions", "listings", "openings",
                           "jobPostings", "postings", "opportunities", "roles", "requisitions"]

        for key in jobArrayKeys {
            if let array = dict[key] as? [[String: Any]], !array.isEmpty {
                return parseJobArray(array, baseURL: baseURL, idPrefix: idPrefix)
            }

            if let nested = dict[key] as? [String: Any] {
                for nestedKey in jobArrayKeys {
                    if let array = nested[nestedKey] as? [[String: Any]], !array.isEmpty {
                        return parseJobArray(array, baseURL: baseURL, idPrefix: idPrefix)
                    }
                }
            }
        }

        if let jobSearch = dict["jobSearch"] as? [String: Any],
           let jobs = jobSearch["jobs"] as? [[String: Any]] {
            return parseJobArray(jobs, baseURL: baseURL, idPrefix: idPrefix)
        }

        return []
    }

    private func parseJobArray(_ array: [[String: Any]], baseURL: URL, idPrefix: String) -> [Job] {
        return array.compactMap { dict -> Job? in
            let titleKeys = ["title", "text", "name", "position", "jobTitle", "role"]
            var title: String?
            for key in titleKeys {
                if let t = dict[key] as? String, !t.isEmpty {
                    title = t
                    break
                }
            }
            guard let jobTitle = title else { return nil }

            let locationKeys = ["location", "locations", "office", "city", "cityState", "region", "locationName"]
            var location = "Not specified"
            for key in locationKeys {
                if let loc = dict[key] as? String, !loc.isEmpty {
                    location = loc
                    break
                } else if let locs = dict[key] as? [[String: Any]], let first = locs.first {
                    if let loc = first["cityState"] as? String ?? first["city"] as? String ?? first["name"] as? String ?? first["locationText"] as? String {
                        location = loc
                        break
                    }
                } else if let locDict = dict[key] as? [String: Any] {
                    if let loc = locDict["name"] as? String ?? locDict["city"] as? String {
                        location = loc
                        break
                    }
                }
            }

            let urlKeys = ["url", "link", "href", "applyURL", "applyUrl", "jobUrl", "originalURL", "absolute_url"]
            var jobURL = baseURL.absoluteString
            for key in urlKeys {
                if let u = dict[key] as? String, !u.isEmpty {
                    if u.hasPrefix("http") {
                        jobURL = u
                    } else if u.hasPrefix("/") {
                        jobURL = "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")\(u)"
                    } else {
                        jobURL = "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")/\(u)"
                    }
                    break
                }
            }

            let idKeys = ["id", "jobId", "requisitionID", "uniqueID", "slug", "req_id"]
            var jobId = "\(idPrefix)-\(UUID().uuidString)"
            for key in idKeys {
                if let id = dict[key] {
                    jobId = "\(idPrefix)-\(id)"
                    break
                }
            }

            let description = dict["description"] as? String ?? ""

            return Job(
                id: jobId,
                title: jobTitle,
                location: location,
                postingDate: nil,
                url: jobURL,
                description: HTMLCleaner.cleanHTML(description),
                workSiteFlexibility: WorkFlexibility.extract(from: "\(jobTitle) \(location) \(description)"),
                source: detectSource(from: baseURL),
                companyName: extractCompanyName(from: baseURL),
                department: dict["department"] as? String,
                category: dict["category"] as? String,
                firstSeenDate: Date(),
                originalPostingDate: nil,
                wasBumped: false
            )
        }
    }

    private func detectSource(from url: URL) -> JobSource {
        if let detected = JobSource.detectFromURL(url.absoluteString) {
            return detected
        }
        return .unknown
    }

    private nonisolated func extractCompanyName(from url: URL) -> String {
        guard let host = url.host else { return "Unknown Company" }

        return host
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "careers.", with: "")
            .replacingOccurrences(of: "jobs.", with: "")
            .components(separatedBy: ".").first?
            .replacingOccurrences(of: "-", with: " ")
            .capitalized ?? "Unknown Company"
    }

    private func filterJobs(_ jobs: [Job], titleFilter: String, locationFilter: String) -> [Job] {
        let titleKeywords = titleFilter.parseAsFilterKeywords()
        let locationKeywords = locationFilter.parseAsFilterKeywords()
        return jobs.applying(titleKeywords: titleKeywords, locationKeywords: locationKeywords)
    }

    private func tryLLMExtraction(html: String, url: URL) async -> [Job] {
        do {
            let parsedJobs = try await llmParser.extractJobs(from: html, url: url)
            return parsedJobs.compactMap { parsed -> Job? in
                guard !parsed.title.isEmpty else { return nil }

                var jobURL = url.absoluteString
                if let parsedURL = parsed.url, !parsedURL.isEmpty {
                    if parsedURL.hasPrefix("http") {
                        jobURL = parsedURL
                    } else {
                        jobURL = "\(url.scheme ?? "https")://\(url.host ?? "")\(parsedURL.hasPrefix("/") ? "" : "/")\(parsedURL)"
                    }
                }

                return Job(
                    id: "llm-\(UUID().uuidString)",
                    title: parsed.title,
                    location: parsed.location ?? "Not specified",
                    postingDate: nil,
                    url: jobURL,
                    description: parsed.description ?? "",
                    workSiteFlexibility: WorkFlexibility.extract(from: "\(parsed.title) \(parsed.location ?? "")"),
                    source: detectSource(from: url),
                    companyName: extractCompanyName(from: url),
                    department: nil,
                    category: nil,
                    firstSeenDate: Date(),
                    originalPostingDate: nil,
                    wasBumped: false
                )
            }
        } catch {
            FetcherLog.error("Universal", "LLM extraction failed: \(error)")
            return []
        }
    }

    private func tryLLMAPIDiscovery(html: String, url: URL) async -> [Job]? {
        do {
            guard let detection = try await llmParser.detectPatternsInContent(html, sourceURL: url) else {
                return nil
            }

            if let apiEndpoint = detection.apiEndpoint, !apiEndpoint.isEmpty {
                FetcherLog.info("Universal", "LLM detected API: \(apiEndpoint)")

                let apiURL: URL
                if apiEndpoint.hasPrefix("http") {
                    guard let parsedURL = URL(string: apiEndpoint) else { return nil }
                    apiURL = parsedURL
                } else {
                    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
                    components.path = apiEndpoint.hasPrefix("/") ? apiEndpoint : "/\(apiEndpoint)"
                    components.query = nil
                    guard let parsedURL = components.url else { return nil }
                    apiURL = parsedURL
                }

                var request = URLRequest(url: apiURL)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 10

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    return nil
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

                if let array = json as? [[String: Any]] {
                    return parseJobArray(array, baseURL: url, idPrefix: "llm-api")
                } else if let dict = json as? [String: Any] {
                    return extractJobsFromDict(dict, baseURL: url, idPrefix: "llm-api")
                }
            }

            return nil
        } catch {
            FetcherLog.debug("Universal", "LLM API discovery failed: \(error)")
            return nil
        }
    }
}

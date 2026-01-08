//
//  UniversalJobFetcher.swift
//  Flare
//
//  Created by Dan on 11/19/25.
//


import Foundation
import WebKit

/// Simple Codable struct for decoding JavaScript job results
private struct UniversalJob: Codable {
    let id: String
    let title: String
    let location: String
    let url: String
}

actor UniversalJobFetcher: URLBasedJobFetcherProtocol {
    
    // MARK: - Pattern Configurations for Common Job Board Layouts
    private struct JobPatterns {
        static let patterns: [PatternConfig] = [
            PatternConfig(
                name: "Standard",
                container: [".job-listing", ".job-item", ".career-opportunity", "[data-job]"],
                title: ["h2", "h3", ".job-title", ".position-title", "a[href*='/job/']"],
                location: [".location", ".job-location", ".office", "[data-location]"],
                link: ["a[href*='/job/']", "a[href*='/career/']", ".job-link"]
            ),
            PatternConfig(
                name: "Card",
                container: [".card", ".job-card", "[class*='card'][class*='job']"],
                title: [".card-title", "h3", "h4"],
                location: [".card-subtitle", ".location", "span.text-muted"],
                link: ["a", ".card-link"]
            ),
            PatternConfig(
                name: "Table",
                container: ["tr", "tbody tr"],
                title: ["td:first-child", "td.title", "td a"],
                location: ["td:nth-child(2)", "td.location"],
                link: ["a", "td a"]
            )
        ]
        
        struct PatternConfig {
            let name: String
            let container: [String]
            let title: [String]
            let location: [String]
            let link: [String]
        }
    }
    
    // MARK: - Source Detection
    private func detectSource(from url: URL) -> JobSource {
        if let detected = JobSource.detectFromURL(url.absoluteString) {
            return detected
        }
        // Default to greenhouse as fallback for custom boards
        return .greenhouse
    }

    // MARK: - Main Fetch Method
    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        print("[Universal] Attempting to fetch from: \(url.absoluteString)")
        
        let jsJobs = await fetchWithJavaScript(url: url)
        if !jsJobs.isEmpty {
            print("[Universal] Found \(jsJobs.count) jobs via JavaScript")
            return filterJobs(jsJobs, titleFilter: titleFilter, locationFilter: locationFilter)
        }
        
        let patternJobs = try await fetchWithPatterns(url: url)
        if !patternJobs.isEmpty {
            print("[Universal] Found \(patternJobs.count) jobs via patterns")
            return filterJobs(patternJobs, titleFilter: titleFilter, locationFilter: locationFilter)
        }
        
        let apiJobs = try await discoverAPI(url: url)
        if !apiJobs.isEmpty {
            print("[Universal] Found \(apiJobs.count) jobs via API")
            return filterJobs(apiJobs, titleFilter: titleFilter, locationFilter: locationFilter)
        }
        
        print("[Universal] No jobs found")
        return []
    }
    
    // MARK: - JavaScript-Based Extraction
    @MainActor
    private func fetchWithJavaScript(url: URL) async -> [Job] {
        return await withCheckedContinuation { continuation in
            let webView = WKWebView()
            webView.load(URLRequest(url: url))

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let radancyAPICode = """
                (async function() {
                    if (window.__PRELOAD_STATE__ && window.__PRELOAD_STATE__.jobSearch) {
                        const jobData = window.__PRELOAD_STATE__.jobSearch;
                        const totalJobs = jobData.totalJob || 0;
                        const preloadedJobs = (jobData.jobs || []).length;

                        if (totalJobs > preloadedJobs) {
                            console.log('[Radancy] Detected pagination: ' + preloadedJobs + '/' + totalJobs + ' jobs preloaded');

                            const params = jobData.params || {};
                            const searchParams = new URLSearchParams(window.location.search);

                            Object.keys(params).forEach(key => {
                                if (!searchParams.has(key) && params[key]) {
                                    searchParams.set(key, params[key]);
                                }
                            });

                            const apiUrl = window.location.origin + '/api/get-jobs?' + searchParams.toString();
                            console.log('[Radancy] Fetching all jobs from: ' + apiUrl);

                            try {
                                const response = await fetch(apiUrl, {
                                    method: 'POST',
                                    headers: {
                                        'Content-Type': 'application/json',
                                        'Accept': 'application/json'
                                    },
                                    body: JSON.stringify({disable_switch_search_mode: false})
                                });

                                if (response.ok) {
                                    const data = await response.json();
                                    const allJobs = data.jobs || [];
                                    console.log('[Radancy] API returned ' + allJobs.length + ' jobs');

                                    if (allJobs.length > 0) {
                                        const jobs = [];
                                        allJobs.forEach(job => {
                                            let loc = 'Not specified';
                                            if (job.location) {
                                                loc = job.location;
                                            } else if (job.locations && job.locations.length > 0) {
                                                const firstLoc = job.locations[0];
                                                loc = firstLoc.cityState || firstLoc.city || firstLoc.locationText || 'Not specified';
                                            }

                                            let jobUrl = job.applyURL || job.applyUrl || job.url || job.originalURL || '';
                                            if (jobUrl && !jobUrl.startsWith('http')) {
                                                jobUrl = window.location.origin + '/job/' + jobUrl;
                                            }
                                            if (!jobUrl) jobUrl = window.location.href;

                                            jobs.push({
                                                title: job.title || job.jobTitle || '',
                                                location: loc,
                                                url: jobUrl,
                                                id: 'radancy-api-' + (job.requisitionID || job.uniqueID || job.id || Math.random().toString(36).substr(2, 9))
                                            });
                                        });
                                        return JSON.stringify(jobs);
                                    }
                                }
                            } catch (e) {
                                console.log('[Radancy] API fetch failed: ' + e.message);
                            }
                        }
                    }
                    return null;
                })()
                """

                webView.evaluateJavaScript(radancyAPICode) { (result, error) in
                    if let jsonString = result as? String, !jsonString.isEmpty {
                        if let data = jsonString.data(using: .utf8),
                           let jobsArray = try? JSONDecoder().decode([UniversalJob].self, from: data) {
                            let detectedSource = self.detectSource(from: url)
                            let jobs = jobsArray.map { job in
                                Job(
                                    id: job.id,
                                    title: job.title,
                                    location: job.location,
                                    postingDate: nil,
                                    url: job.url,
                                    description: "",
                                    workSiteFlexibility: nil,
                                    source: detectedSource,
                                    companyName: URL(string: job.url).flatMap { self.extractCompanyName(from: $0) } ?? "Unknown Company",
                                    department: nil,
                                    category: nil,
                                    firstSeenDate: Date(),
                                    originalPostingDate: nil,
                                    wasBumped: false
                                )
                            }
                            print("[Universal] Radancy API returned \(jobs.count) jobs")
                            continuation.resume(returning: jobs)
                            return
                        }
                    }

                    self.runStandardExtraction(webView: webView, url: url, continuation: continuation)
                }
            }
        }
    }

    @MainActor
    private func runStandardExtraction(webView: WKWebView, url: URL, continuation: CheckedContinuation<[Job], Never>) {
        let jsCode = """
        (function() {
            const jobs = [];

            if (window.__PRELOAD_STATE__ && window.__PRELOAD_STATE__.jobSearch) {
                const jobData = window.__PRELOAD_STATE__.jobSearch;
                const jobList = jobData.jobs || jobData.results || [];
                if (jobList.length > 0) {
                    jobList.forEach(job => {
                        let loc = 'Not specified';
                        if (job.location) {
                            loc = job.location;
                        } else if (job.locations && job.locations.length > 0) {
                            const firstLoc = job.locations[0];
                            loc = firstLoc.cityState || firstLoc.city || firstLoc.locationText || 'Not specified';
                        } else if (job.city) {
                            loc = job.city;
                        }

                        let jobUrl = job.applyURL || job.applyUrl || job.url || job.jobUrl || job.originalURL || '';
                        if (jobUrl && !jobUrl.startsWith('http')) {
                            jobUrl = window.location.origin + '/job/' + jobUrl;
                        }
                        if (!jobUrl) jobUrl = window.location.href;

                        jobs.push({
                            title: job.title || job.jobTitle || '',
                            location: loc,
                            url: jobUrl,
                            id: 'preload-' + (job.jobId || job.requisitionID || job.id || Math.random().toString(36).substr(2, 9))
                        });
                    });
                    return JSON.stringify(jobs);
                }
            }

            if (window.__INITIAL_STATE__) {
                const state = window.__INITIAL_STATE__;
                const jobList = state.jobs || state.positions || state.listings ||
                                (state.jobSearch && state.jobSearch.jobs) || [];
                if (jobList.length > 0) {
                    jobList.forEach(job => {
                        jobs.push({
                            title: job.title || job.jobTitle || '',
                            location: job.location || job.city || 'Not specified',
                            url: job.url || job.applyUrl || window.location.href,
                            id: 'initial-' + (job.id || Math.random().toString(36).substr(2, 9))
                        });
                    });
                    return JSON.stringify(jobs);
                }
            }

            const patterns = [
                { container: '.job-listing, .job-item, .career-opportunity', title: 'h2, h3, .title', location: '.location' },
                { container: '[data-job], [data-position]', title: '[data-title], .job-title', location: '[data-location]' },
                { container: 'article, .card', title: 'h3 a, .card-title', location: '.location, .office' },
                { container: 'tr', title: 'td:first-child a', location: 'td:nth-child(2)' }
            ];

            for (const pattern of patterns) {
                const containers = document.querySelectorAll(pattern.container);
                if (containers.length > 0) {
                    containers.forEach(container => {
                        const titleElem = container.querySelector(pattern.title);
                        const locationElem = container.querySelector(pattern.location);

                        if (titleElem && titleElem.textContent.trim()) {
                            const linkElem = container.querySelector('a[href]');
                            const job = {
                                title: titleElem.textContent.trim(),
                                location: locationElem ? locationElem.textContent.trim() : 'Not specified',
                                url: linkElem ? linkElem.href : window.location.href,
                                id: 'universal-' + Math.random().toString(36).substr(2, 9)
                            };
                            jobs.push(job);
                        }
                    });

                    if (jobs.length > 0) break;
                }
            }

            // If no jobs found with patterns, try finding all job-like links
            if (jobs.length === 0) {
                const links = document.querySelectorAll('a[href*="job"], a[href*="career"], a[href*="position"], a[href*="opening"]');
                links.forEach(link => {
                    const text = link.textContent.trim();
                    if (text.length > 10 && text.length < 200 && !text.includes('View all')) {
                        jobs.push({
                            title: text,
                            location: 'See job details',
                            url: link.href,
                            id: 'universal-' + Math.random().toString(36).substr(2, 9)
                        });
                    }
                });
            }

            return JSON.stringify(jobs);
        })();
        """

        webView.evaluateJavaScript(jsCode) { result, error in
            guard let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8),
                  let extractedJobs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                continuation.resume(returning: [])
                return
            }

            let detectedSource = self.detectSource(from: url)

            let jobs = extractedJobs.compactMap { jobDict -> Job? in
                guard let title = jobDict["title"] as? String,
                      let jobUrl = jobDict["url"] as? String,
                      let id = jobDict["id"] as? String else { return nil }

                let companyName = URL(string: jobUrl).flatMap { self.extractCompanyName(from: $0) } ?? "Unknown Company"

                return Job(
                    id: id,
                    title: title,
                    location: jobDict["location"] as? String ?? "Not specified",
                    postingDate: nil,
                    url: jobUrl,
                    description: "",
                    workSiteFlexibility: nil,
                    source: detectedSource,
                    companyName: companyName,
                    department: nil,
                    category: nil,
                    firstSeenDate: Date(),
                    originalPostingDate: nil,
                    wasBumped: false
                )
            }

            continuation.resume(returning: jobs)
        }
    }
    
    // MARK: - Pattern-Based Extraction
    private func fetchWithPatterns(url: URL) async throws -> [Job] {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        
        var jobs: [Job] = []
        
        for pattern in JobPatterns.patterns {
            jobs = extractJobsWithPattern(html: html, pattern: pattern, baseURL: url)
            if !jobs.isEmpty {
                print("[Universal] Pattern '\(pattern.name)' matched")
                break
            }
        }
        
        return jobs
    }
    
    private func extractJobsWithPattern(html: String, pattern: JobPatterns.PatternConfig, baseURL: URL) -> [Job] {
        var jobs: [Job] = []
        
        for containerSelector in pattern.container {
            // Build pattern with proper escaping
            let replacedSelector = containerSelector.replacingOccurrences(of: ".", with: "[^>]*class=\\\"")
            let containerPattern = "<\(replacedSelector)[^>]*>(.*?)</[^>]+>"
            
            guard let regex = try? NSRegularExpression(pattern: containerPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
                continue
            }
            
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            
            for match in matches.prefix(50) { // Limit to 50 jobs
                if let range = Range(match.range(at: 1), in: html) {
                    let containerHTML = String(html[range])
                    var title: String?
                    for titleSelector in pattern.title {
                        if let extracted = extractText(from: containerHTML, selector: titleSelector) {
                            title = extracted
                            break
                        }
                    }
                    
                    var location = "Not specified"
                    for locationSelector in pattern.location {
                        if let extracted = extractText(from: containerHTML, selector: locationSelector) {
                            location = extracted
                            break
                        }
                    }
                    
                    var jobURL = baseURL.absoluteString
                    if let linkMatch = containerHTML.range(of: #"href=["']([^"']+)["']"#, options: .regularExpression) {
                        let link = String(containerHTML[linkMatch]).replacingOccurrences(of: "href=", with: "")
                            .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                        
                        if link.hasPrefix("http") {
                            jobURL = link
                        } else if link.hasPrefix("/") {
                            jobURL = "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")\(link)"
                        }
                    }
                    
                    if let title = title, !title.isEmpty {
                        let job = Job(
                            id: "universal-\(UUID().uuidString)",
                            title: title,
                            location: location,
                            postingDate: nil,
                            url: jobURL,
                            description: "",
                            workSiteFlexibility: detectFlexibility(from: "\(title) \(location)"),
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
                }
            }
            
            if !jobs.isEmpty { break }
        }
        
        return jobs
    }
    
    // MARK: - API Discovery
    private func discoverAPI(url: URL) async throws -> [Job] {
        let apiPatterns = [
            "/api/jobs",
            "/api/careers",
            "/api/v1/jobs",
            "/api/v2/positions",
            "/jobs.json",
            "/careers.json",
            "/_next/data",
            "/wp-json/wp/v2"
        ]
        
        for pattern in apiPatterns {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            components.path = pattern
            guard let apiURL = components.url else { continue }
            
            do {
                let (data, response) = try await URLSession.shared.data(from: apiURL)
                
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
                    if let jobs = parseJSONJobs(data: data, baseURL: url) {
                        return jobs
                    }
                }
            } catch {
                continue
            }
        }
        
        return []
    }
    
    // MARK: - Helper Methods
    
    private func extractText(from html: String, selector: String) -> String? {
        let pattern = "<\(selector)[^>]*>(.*?)</\(selector)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        
        if let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            let text = String(html[range])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        
        return nil
    }
    
    private func parseJSONJobs(data: Data, baseURL: URL) -> [Job]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        
        if let jobArray = json as? [[String: Any]] {
            return parseJobArray(jobArray, baseURL: baseURL)
        }
        
        if let jsonDict = json as? [String: Any] {
            let possibleKeys = ["jobs", "data", "results", "positions", "listings"]
            for key in possibleKeys {
                if let jobArray = jsonDict[key] as? [[String: Any]] {
                    return parseJobArray(jobArray, baseURL: baseURL)
                }
            }
        }
        
        return nil
    }
    
    private func parseJobArray(_ array: [[String: Any]], baseURL: URL) -> [Job] {
        return array.compactMap { dict in
            let titleKeys = ["title", "position", "name", "jobTitle", "role"]
            var title: String?
            for key in titleKeys {
                if let t = dict[key] as? String {
                    title = t
                    break
                }
            }
            
            guard let jobTitle = title else { return nil }
            let locationKeys = ["location", "office", "city", "locationName"]
            var location = "Not specified"
            for key in locationKeys {
                if let loc = dict[key] as? String {
                    location = loc
                    break
                } else if let locDict = dict[key] as? [String: Any],
                          let name = locDict["name"] as? String {
                    location = name
                    break
                }
            }
            
            let urlKeys = ["url", "link", "href", "applyUrl"]
            var jobURL = baseURL.absoluteString
            for key in urlKeys {
                if let u = dict[key] as? String {
                    jobURL = u.hasPrefix("http") ? u : "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")\(u)"
                    break
                }
            }
            
            return Job(
                id: "universal-\(UUID().uuidString)",
                title: jobTitle,
                location: location,
                postingDate: nil,
                url: jobURL,
                description: dict["description"] as? String ?? "",
                workSiteFlexibility: detectFlexibility(from: "\(jobTitle) \(location)"),
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
    
    private func detectFlexibility(from text: String) -> String? {
        let keywords = ["remote", "hybrid", "onsite", "on-site", "flexible"]
        let lower = text.lowercased()
        
        for keyword in keywords {
            if lower.contains(keyword) {
                return keyword.capitalized
            }
        }
        
        return nil
    }
    
    private nonisolated func extractCompanyName(from url: URL) -> String {
        guard let host = url.host else { return "Unknown Company" }
        
        let parts = host.replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: ".com", with: "")
            .replacingOccurrences(of: ".io", with: "")
            .replacingOccurrences(of: ".co", with: "")
            .components(separatedBy: ".")
        
        return parts.first?.capitalized ?? "Unknown Company"
    }
    
    private func filterJobs(_ jobs: [Job], titleFilter: String, locationFilter: String) -> [Job] {
        var filtered = jobs
        
        if !titleFilter.isEmpty {
            let keywords = titleFilter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            filtered = filtered.filter { job in
                let title = job.title.lowercased()
                return keywords.contains { title.contains($0) }
            }
        }
        
        if !locationFilter.isEmpty {
            let keywords = locationFilter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            filtered = filtered.filter { job in
                let location = job.location.lowercased()
                return keywords.contains { location.contains($0) }
            }
        }
        
        return filtered
    }
}

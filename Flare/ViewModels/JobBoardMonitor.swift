//
//  JobBoardMonitor.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import Foundation
import SwiftUI

@MainActor
class JobBoardMonitor: ObservableObject {
    static let shared = JobBoardMonitor()
    
    @Published var boardConfigs: [JobBoardConfig] = []
    @Published var isMonitoring = false
    @Published var lastError: String?
    @Published var showConfigSheet = false
    @Published var testResults: [UUID: String] = [:]
    @Published var parsingStatus: [UUID: String] = [:]
    @Published var detectionStatus: String = ""
    @Published var detectionInProgress = false

    struct DetectionPreview: Identifiable {
        let id = UUID()
        let jobCount: Int
        let parsingMethod: ParsingMethod
        let queryURL: String
        let atsType: String?
    }

    private let persistenceService = PersistenceService.shared
    private let greenhouseFetcher = GreenhouseFetcher()
    private let ashbyFetcher = AshbyFetcher()
    private let leverFetcher = LeverFetcher()
    private let workdayFetcher = WorkdayFetcher()
    private let smartParser = SmartJobParser()
    private var monitorTimer: Timer?
    
    private init() {
        Task {
            await loadConfigs()
        }
    }
    
    func loadConfigs() async {
        do {
            boardConfigs = try await persistenceService.loadBoardConfigs()
        } catch {
            print("[JobBoardMonitor] Failed to load configs: \(error)")
        }
    }

    func saveConfigs() async {
        do {
            try await persistenceService.saveBoardConfigs(boardConfigs)
        } catch {
            print("[JobBoardMonitor] Failed to save configs: \(error)")
        }
    }
    
    func addBoardConfig(_ config: JobBoardConfig) {
        // Prevent duplicates by checking URL
        guard !boardConfigs.contains(where: { $0.url == config.url }) else {
            print("[JobBoardMonitor] Board with URL '\(config.url)' already exists, skipping")
            return
        }

        boardConfigs.append(config)
        Task {
            await saveConfigs()
        }
    }
    
    func removeBoardConfig(at index: Int) {
        // Get the URL before removing to clear the LLM cache for this domain
        let config = boardConfigs[index]
        if let url = URL(string: config.url), let domain = url.host {
            // Clear any cached LLM failure for this domain so re-adding will retry LLM
            Task {
                await APISchemaCache.shared.clearSchema(for: domain)
                print("[JobBoardMonitor] Cleared LLM cache for \(domain)")
            }
        }

        boardConfigs.remove(at: index)
        Task {
            await saveConfigs()
        }
    }
    
    func updateBoardConfig(_ config: JobBoardConfig) {
        if let index = boardConfigs.firstIndex(where: { $0.id == config.id }) {
            boardConfigs[index] = config
            Task {
                await saveConfigs()
            }
        }
    }
    
    func startMonitoring() async {
        monitorTimer?.invalidate()
        
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { [weak self] in
                await self?.fetchAllBoardJobs()
            }
        }
    }
    
    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }
    
    func testSingleBoard(_ config: JobBoardConfig) async {
        testResults[config.id] = "Testing..."

        do {
            let jobs = try await fetchJobsFromBoard(config, titleFilter: "", locationFilter: "")
            testResults[config.id] = "Found \(jobs.count) jobs"

            var updatedConfig = config
            updatedConfig.lastFetched = Date()
            updateBoardConfig(updatedConfig)
        } catch {
            testResults[config.id] = "Error: \(error.localizedDescription)"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.testResults.removeValue(forKey: config.id)
        }
    }

    func detectAndPreview(url: URL) async -> DetectionPreview? {
        await MainActor.run {
            detectionInProgress = true
            detectionStatus = "Detecting job board type..."
        }

        let urlString = url.absoluteString

        // Check if it's a direct ATS link
        if let source = JobSource.detectFromURL(urlString), source != .unknown, source.isSupported {
            await MainActor.run { detectionStatus = "Detected \(source.rawValue), fetching jobs..." }

            do {
                let jobs = try await fetchJobsForSource(source, url: url)
                await MainActor.run { detectionInProgress = false }
                return DetectionPreview(
                    jobCount: jobs.count,
                    parsingMethod: .directATS,
                    queryURL: urlString,
                    atsType: source.rawValue.lowercased()
                )
            } catch {
                print("[Detection] Direct ATS fetch error: \(error)")
            }
        }

        // Try Radancy API pattern early (before ATS detection) - fast and common
        await MainActor.run { detectionStatus = "Checking for API patterns..." }
        if let radancyResult = await tryRadancyAPIDetection(url: url) {
            await MainActor.run { detectionInProgress = false }
            return radancyResult
        }

        await MainActor.run { detectionStatus = "Scanning for ATS links..." }
        do {
            let result = try await ATSDetectorService.shared.detectATSEnhanced(from: url)
            if let atsURL = result.actualATSUrl,
               let atsType = result.source,
               atsType != .unknown,
               atsType.isSupported,
               let parsedURL = URL(string: atsURL) {

                await MainActor.run { detectionStatus = "Found \(atsType.rawValue), fetching jobs..." }
                let jobs = try await fetchJobsForSource(atsType, url: parsedURL)
                if !jobs.isEmpty {
                    await MainActor.run { detectionInProgress = false }
                    return DetectionPreview(
                        jobCount: jobs.count,
                        parsingMethod: .directATS,
                        queryURL: atsURL,
                        atsType: atsType.rawValue.lowercased()
                    )
                }
            }
        } catch {
            print("[Detection] ATS detection error: \(error)")
        }

        await MainActor.run { detectionStatus = "Trying JSON and API extraction..." }

        // Try quick extraction without LLM first
        do {
            let html = try await fetchHTMLForDetection(url: url)
            let jobs = extractJobsWithoutLLM(html: html, url: url)

            if jobs.count >= 3 {
                let method = determineParsingMethod(from: jobs)
                await MainActor.run { detectionInProgress = false }
                return DetectionPreview(
                    jobCount: jobs.count,
                    parsingMethod: method,
                    queryURL: urlString,
                    atsType: nil
                )
            }
        } catch {
            print("[Detection] Quick extraction error: \(error)")
        }

        // Use SmartJobParser with LLM if enabled - show progress
        let isLLMEnabled = UserDefaults.standard.bool(forKey: "enableAIParser")
        if isLLMEnabled {
            await MainActor.run { detectionStatus = "AI analyzing page structure..." }

            let jobs = await smartParser.parseJobs(
                from: url,
                titleFilter: "",
                locationFilter: "",
                statusCallback: { @MainActor [weak self] status in
                    self?.detectionStatus = status
                }
            )

            if !jobs.isEmpty {
                let method = determineParsingMethod(from: jobs)
                await MainActor.run { detectionInProgress = false }
                return DetectionPreview(
                    jobCount: jobs.count,
                    parsingMethod: method.rawValue.contains("AI") ? method : .llmExtraction,
                    queryURL: urlString,
                    atsType: nil
                )
            }
        }

        await MainActor.run {
            detectionStatus = "No jobs found"
            detectionInProgress = false
        }
        return nil
    }

    private func tryRadancyAPIDetection(url: URL) async -> DetectionPreview? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let pid = queryItems.first(where: { $0.name == "pid" })?.value else {
            return nil
        }

        let domain = queryItems.first(where: { $0.name == "domain" })?.value

        var apiComponents = components
        apiComponents.path = "/api/apply/v2/jobs/\(pid)/jobs"
        apiComponents.queryItems = domain != nil ? [URLQueryItem(name: "domain", value: domain)] : nil

        guard let apiURL = apiComponents.url else { return nil }

        print("[Detection] Trying Radancy API: \(apiURL.absoluteString)")
        await MainActor.run { detectionStatus = "Checking Radancy API..." }

        do {
            var request = URLRequest(url: apiURL)
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

            var jobCount = 0
            if let dict = json as? [String: Any] {
                if let positions = dict["positions"] as? [[String: Any]] {
                    jobCount = positions.count
                } else if let jobs = dict["jobs"] as? [[String: Any]] {
                    jobCount = jobs.count
                }
            } else if let array = json as? [[String: Any]] {
                jobCount = array.count
            }

            if jobCount > 0 {
                print("[Detection] Radancy API found \(jobCount) jobs")
                return DetectionPreview(
                    jobCount: jobCount,
                    parsingMethod: .apiDiscovery,
                    queryURL: apiURL.absoluteString,
                    atsType: "radancy"
                )
            }
        } catch {
            print("[Detection] Radancy API error: \(error)")
        }

        return nil
    }

    private func fetchHTMLForDetection(url: URL) async throws -> String {
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

    private func extractJobsWithoutLLM(html: String, url: URL) -> [Job] {
        var allJobs: [Job] = []

        // Schema.org extraction
        let schemaJobs = extractSchemaOrgJobs(html: html, url: url)
        allJobs.append(contentsOf: schemaJobs)

        // Try HTML patterns for job links
        let patternJobs = extractJobLinksFromHTML(html: html, url: url)
        for job in patternJobs {
            if !allJobs.contains(where: { $0.url == job.url }) {
                allJobs.append(job)
            }
        }

        return allJobs
    }

    private func extractSchemaOrgJobs(html: String, url: URL) -> [Job] {
        var jobs: [Job] = []
        let pattern = #"<script[^>]*type=["\']application/ld\+json["\'][^>]*>([\s\S]*?)</script>"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
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
                guard let type = schema["@type"] as? String, type == "JobPosting",
                      let title = schema["title"] as? String else { continue }

                var location = "Not specified"
                if let jobLocation = schema["jobLocation"] as? [String: Any],
                   let address = jobLocation["address"] as? [String: Any] {
                    let parts = [address["addressLocality"], address["addressRegion"], address["addressCountry"]]
                        .compactMap { $0 as? String }
                    if !parts.isEmpty { location = parts.joined(separator: ", ") }
                }

                var jobURL = url.absoluteString
                if let urlStr = schema["url"] as? String {
                    jobURL = urlStr.hasPrefix("http") ? urlStr : "\(url.scheme ?? "https")://\(url.host ?? "")\(urlStr)"
                }

                jobs.append(Job(
                    id: "schema-\(UUID().uuidString)",
                    title: title,
                    location: location,
                    postingDate: nil,
                    url: jobURL,
                    description: schema["description"] as? String ?? "",
                    workSiteFlexibility: nil,
                    source: .unknown,
                    companyName: (schema["hiringOrganization"] as? [String: Any])?["name"] as? String,
                    department: nil,
                    category: nil,
                    firstSeenDate: Date(),
                    originalPostingDate: nil,
                    wasBumped: false
                ))
            }
        }
        return jobs
    }

    private func extractJobLinksFromHTML(html: String, url: URL) -> [Job] {
        var jobs: [Job] = []
        var seenURLs = Set<String>()

        let patterns = [
            #"<a[^>]*href="([^"]*(?:/jobs?/|/careers?/|/positions?/|/openings?/)[^"]+)"[^>]*>([^<]{5,100})</a>"#,
            #"<a[^>]*href="([^"]*)"[^>]*class="[^"]*job[^"]*"[^>]*>([^<]{5,100})</a>"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

            for match in matches {
                guard let urlRange = Range(match.range(at: 1), in: html),
                      let titleRange = Range(match.range(at: 2), in: html) else { continue }

                let jobUrl = String(html[urlRange])
                let title = String(html[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)

                let skip = ["next", "prev", "page", "load more", "view all", "apply"]
                if skip.contains(where: { title.lowercased().contains($0) }) || title.count < 5 { continue }

                let fullUrl = jobUrl.hasPrefix("http") ? jobUrl : "\(url.scheme ?? "https")://\(url.host ?? "")\(jobUrl)"
                if seenURLs.contains(fullUrl) { continue }
                seenURLs.insert(fullUrl)

                jobs.append(Job(
                    id: "html-\(UUID().uuidString)",
                    title: title,
                    location: "Not specified",
                    postingDate: nil,
                    url: fullUrl,
                    description: "",
                    workSiteFlexibility: nil,
                    source: .unknown,
                    companyName: url.host?.replacingOccurrences(of: "www.", with: "").components(separatedBy: ".").first?.capitalized,
                    department: nil,
                    category: nil,
                    firstSeenDate: Date(),
                    originalPostingDate: nil,
                    wasBumped: false
                ))
            }

            if !jobs.isEmpty { break }
        }
        return jobs
    }

    private func fetchJobsForSource(_ source: JobSource, url: URL) async throws -> [Job] {
        switch source {
        case .greenhouse:
            return try await greenhouseFetcher.fetchGreenhouseJobs(from: url, titleFilter: "", locationFilter: "")
        case .ashby:
            return try await ashbyFetcher.fetchJobs(from: url, titleFilter: "", locationFilter: "")
        case .lever:
            return try await leverFetcher.fetchJobs(from: url, titleFilter: "", locationFilter: "")
        case .workday:
            return try await workdayFetcher.fetchJobs(from: url, titleFilter: "", locationFilter: "")
        default:
            return []
        }
    }

    private func determineParsingMethod(from jobs: [Job]) -> ParsingMethod {
        guard let firstId = jobs.first?.id else { return .unknown }
        if firstId.hasPrefix("schema-") { return .schemaOrg }
        if firstId.hasPrefix("next-") || firstId.hasPrefix("preload-") || firstId.hasPrefix("initial-") { return .embeddedJSON }
        if firstId.hasPrefix("api-") || firstId.hasPrefix("llm-api-") { return .apiDiscovery }
        if firstId.hasPrefix("llm-") { return .llmExtraction }
        if firstId.hasPrefix("html-") { return .htmlPatterns }
        return .unknown
    }

    func fetchAllBoardJobs(titleFilter: String = "", locationFilter: String = "") async -> [Job] {
        isMonitoring = true
        lastError = nil
        var allJobs = [Job]()
        var errorMessages = [String]()

        for config in boardConfigs where config.isEnabled && config.isSupported {
            do {
                let jobs = try await fetchJobsFromBoard(config, titleFilter: titleFilter, locationFilter: locationFilter)
                allJobs.append(contentsOf: jobs)

                var updatedConfig = config
                updatedConfig.lastFetched = Date()
                updateBoardConfig(updatedConfig)
            } catch {
                let errorMsg = "\(config.displayName): \(error.localizedDescription)"
                errorMessages.append(errorMsg)
                print("[JobBoard] \(errorMsg)")
            }

            try? await Task.sleep(nanoseconds: FetchDelayConfig.boardFetchDelay)
        }

        if !errorMessages.isEmpty {
            lastError = errorMessages.joined(separator: " | ")
        }

        isMonitoring = false
        return allJobs
    }
    
    // MARK: - Import/Export
    
    func exportBoards() -> String {
        return boardConfigs.map { config in
            "\(config.url) | \(config.name) | \(config.isEnabled ? "enabled" : "disabled")"
        }.joined(separator: "\n")
    }
    
    func importBoards(from content: String) -> (added: Int, failed: [String]) {
        let lines = content.components(separatedBy: .newlines)
        var addedCount = 0
        var failedLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            let parts = trimmed.components(separatedBy: " | ")
            guard parts.count >= 1 else {
                failedLines.append(line)
                continue
            }
            
            let url = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let isEnabled = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "enabled" : true
            
            if let config = JobBoardConfig(name: name, url: url, isEnabled: isEnabled) {
                // Check if already exists
                if !boardConfigs.contains(where: { $0.url == config.url }) {
                    addBoardConfig(config)
                    addedCount += 1
                }
            } else {
                failedLines.append(line)
            }
        }
        
        return (added: addedCount, failed: failedLines)
    }
    
    // MARK: - Private Methods
    
    private func fetchJobsFromBoard(_ config: JobBoardConfig, titleFilter: String, locationFilter: String) async throws -> [Job] {
        guard let url = URL(string: config.url) else {
            throw FetchError.invalidURL
        }

        // Check if we have a previously detected ATS URL (e.g., Workday found via GTM)
        // First check the config, then check the runtime cache
        var detectedATSURL = config.detectedATSURL
        var detectedATSType = config.detectedATSType

        // Check runtime cache if not in config
        var needsPersist = false
        if detectedATSURL == nil, let domain = url.host {
            if let cached = await DetectedATSCache.shared.get(for: domain) {
                detectedATSURL = cached.atsURL
                detectedATSType = cached.atsType
                needsPersist = true  // Found in runtime cache but not in config - need to persist
                print("[JobBoard] Found ATS in runtime cache: \(cached.atsType) at \(cached.atsURL)")
            }
        }

        if let detectedATSURL = detectedATSURL,
           let detectedATSType = detectedATSType,
           let atsURL = URL(string: detectedATSURL) {
            print("[JobBoard] Using cached ATS: \(detectedATSType) at \(detectedATSURL)")
            parsingStatus[config.id] = "Fetching from \(detectedATSType.capitalized)..."

            let jobs: [Job]
            switch detectedATSType.lowercased() {
            case "workday":
                jobs = try await workdayFetcher.fetchJobs(from: atsURL, titleFilter: titleFilter, locationFilter: locationFilter)
            case "greenhouse":
                jobs = try await greenhouseFetcher.fetchGreenhouseJobs(from: atsURL, titleFilter: titleFilter, locationFilter: locationFilter)
            case "lever":
                jobs = try await leverFetcher.fetchJobs(from: atsURL, titleFilter: titleFilter, locationFilter: locationFilter)
            case "ashby":
                jobs = try await ashbyFetcher.fetchJobs(from: atsURL, titleFilter: titleFilter, locationFilter: locationFilter)
            default:
                jobs = []
            }

            if !jobs.isEmpty {
                parsingStatus[config.id] = "Found \(jobs.count) jobs"

                if needsPersist {
                    var updatedConfig = config
                    updatedConfig.detectedATSURL = detectedATSURL
                    updatedConfig.detectedATSType = detectedATSType
                    updateBoardConfig(updatedConfig)
                }

                let configId = config.id
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.parsingStatus.removeValue(forKey: configId)
                }
                return jobs
            } else {
                parsingStatus[config.id] = "No jobs found"
            }
        }

        switch config.source {
        case .greenhouse:
            return try await greenhouseFetcher.fetchGreenhouseJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case .ashby:
            return try await ashbyFetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case .lever:
            return try await leverFetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case .workday:
            return try await workdayFetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        default:
            // Use SmartJobParser for unknown sources (falls back to LLM if enabled)
            // Pass status callback to show parsing progress
            let configId = config.id
            let jobs = await smartParser.parseJobs(
                from: url,
                titleFilter: titleFilter,
                locationFilter: locationFilter,
                statusCallback: { @MainActor [weak self] status in
                    self?.parsingStatus[configId] = status
                }
            )

            // After parsing, check if we detected an ATS URL and persist it to config
            if !jobs.isEmpty, let domain = url.host {
                if let cached = await DetectedATSCache.shared.get(for: domain) {
                    // Persist detected ATS to config for future refreshes
                    var updatedConfig = config
                    updatedConfig.detectedATSURL = cached.atsURL
                    updatedConfig.detectedATSType = cached.atsType
                    updateBoardConfig(updatedConfig)
                    print("[JobBoard] Persisted detected ATS to config: \(cached.atsType) at \(cached.atsURL)")
                }
            }

            return jobs
        }
    }
}

//
//  ModelDownloader 2.swift
//  Flare
//
//  Created by Dan on 12/9/25.
//

import Foundation

/// Smart job parser that tries multiple strategies in order:
/// 1. API/ATS detection (UniversalJobFetcher - for known platforms like Greenhouse, Lever, etc.)
/// 2. LLM parsing with schema caching (for custom career sites)
actor SmartJobParser {
    private let universalFetcher = UniversalJobFetcher()
    private let llmParser = LLMParser.shared
    private let schemaCache = APISchemaCache.shared
    private let jsonParser = UniversalJSONParser()
    private let cachedFetcher = CachedSchemaFetcher()

    /// Parse jobs from a URL using the best available method
    /// - Parameters:
    ///   - url: URL to parse jobs from
    ///   - titleFilter: Optional job title filter
    ///   - locationFilter: Optional location filter
    ///   - statusCallback: Optional callback for status updates (called on MainActor)
    func parseJobs(from url: URL, titleFilter: String = "", locationFilter: String = "", statusCallback: (@Sendable (String) -> Void)? = nil) async -> [Job] {
        print("[SmartParser] Parsing jobs from: \(url.absoluteString)")
        await updateStatus("🔍 Analyzing website...", callback: statusCallback)

        // Step 1: Try API/ATS detection first (for known platforms)
        do {
            await updateStatus("⚡ Trying API/ATS detection...", callback: statusCallback)
            let jobs = try await universalFetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
            if !jobs.isEmpty {
                print("[SmartParser] Success via API/ATS detection: \(jobs.count) jobs")
                await updateStatus("✅ Found \(jobs.count) jobs via API/ATS", callback: statusCallback)
                return jobs
            }
        } catch {
            print("[SmartParser] API/ATS detection failed: \(error.localizedDescription)")
            await updateStatus("❌ API/ATS detection failed", callback: statusCallback)
        }

        // Step 2: Scan HTML source for embedded ATS platforms
        do {
            await updateStatus("🔎 Scanning source code for ATS platforms...", callback: statusCallback)
            if let detectedPlatform = try await detectATSFromHTML(url: url) {
                await updateStatus("✅ Detected \(detectedPlatform) in source code, retrying...", callback: statusCallback)
                print("[SmartParser] Detected \(detectedPlatform) platform in HTML source")

                // Try fetching with the detected platform
                let jobs = try await universalFetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
                if !jobs.isEmpty {
                    await updateStatus("✅ Found \(jobs.count) jobs via detected \(detectedPlatform)", callback: statusCallback)
                    return jobs
                }
            }
        } catch {
            print("[SmartParser] HTML ATS detection failed: \(error.localizedDescription)")
        }

        // Step 3: Fall back to LLM if enabled
        let aiParsingEnabled = UserDefaults.standard.bool(forKey: "enableAIParser")
        print("[SmartParser] AI parsing enabled: \(aiParsingEnabled)")

        if aiParsingEnabled {
            print("[SmartParser] Falling back to LLM parsing...")
            await updateStatus("🤖 Using AI to analyze site...", callback: statusCallback)
            return await parseWithLLM(url: url, titleFilter: titleFilter, locationFilter: locationFilter, statusCallback: statusCallback)
        }

        print("[SmartParser] All parsing methods exhausted, returning empty")
        await updateStatus("❌ Unable to parse - enable AI parsing in Settings", callback: statusCallback)
        return []
    }

    /// Helper to update status on MainActor
    private func updateStatus(_ message: String, callback: (@Sendable (String) -> Void)?) async {
        guard let callback = callback else { return }
        await MainActor.run {
            callback(message)
        }
    }

    // MARK: - LLM-Based Parsing

    /// Parse jobs using LLM with WebKit API interception and schema caching
    private func parseWithLLM(url: URL, titleFilter: String, locationFilter: String, statusCallback: (@Sendable (String) -> Void)?) async -> [Job] {
        do {
            // Try WebKit rendering with API detection (for SPAs)
            if let jobs = try await tryWebKitAPIDetection(from: url, titleFilter: titleFilter, locationFilter: locationFilter, statusCallback: statusCallback) {
                return jobs
            }

            // If WebKit approach didn't work, try direct HTML parsing with LLM
            print("[SmartParser] WebKit approach failed, attempting direct HTML parsing...")
            await updateStatus("📄 Analyzing HTML content with AI...", callback: statusCallback)
            let html = try await fetchHTML(from: url)
            let parsedJobs = try await llmParser.extractJobs(from: html, url: url)
            let jobs = parsedJobs.compactMap { convertToJob($0, url: url) }
            let filteredJobs = applyFilters(jobs, titleFilter: titleFilter, locationFilter: locationFilter)

            if !filteredJobs.isEmpty {
                await updateStatus("✅ Found \(filteredJobs.count) jobs via HTML parsing", callback: statusCallback)
            } else {
                await updateStatus("❌ No jobs found in HTML content", callback: statusCallback)
            }

            return filteredJobs

        } catch {
            print("[SmartParser] LLM parsing failed: \(error)")
            await updateStatus("❌ AI parsing failed: \(error.localizedDescription)", callback: statusCallback)
            return []
        }
    }

    /// Try WebKit rendering with API interception (primary LLM approach for SPAs)
    private func tryWebKitAPIDetection(from url: URL, titleFilter: String, locationFilter: String, statusCallback: (@Sendable (String) -> Void)?) async throws -> [Job]? {
        guard let domain = url.host else { return nil }

        // Check cache first
        if let cachedSchema = await schemaCache.getSchema(for: domain) {
            // Check if LLM previously failed - retry after 7 days
            if cachedSchema.llmAttempted && !cachedSchema.schemaDiscovered {
                let daysSinceLastAttempt = Date().timeIntervalSince(cachedSchema.lastAttempt) / (24 * 60 * 60)

                if daysSinceLastAttempt < 7 {
                    print("[SmartParser] LLM previously attempted for \(domain) but failed (\(Int(daysSinceLastAttempt)) days ago) - skipping (will retry after 7 days)")
                    await updateStatus("⏳ AI previously failed for this site (retry in \(7 - Int(daysSinceLastAttempt)) days)", callback: statusCallback)
                    return nil
                } else {
                    print("[SmartParser] LLM failed \(Int(daysSinceLastAttempt)) days ago for \(domain) - retrying now")
                    await updateStatus("🔄 Retrying AI analysis (previous attempt was \(Int(daysSinceLastAttempt)) days ago)", callback: statusCallback)
                    await schemaCache.clearSchema(for: domain)
                }
            }

            // Use cached schema if available
            if cachedSchema.schemaDiscovered {
                print("[SmartParser] Using cached schema for \(domain)")
                await updateStatus("⚡ Using cached schema for \(domain)", callback: statusCallback)
                if let jobs = await fetchWithCachedSchema(cachedSchema, titleFilter: titleFilter, locationFilter: locationFilter, statusCallback: statusCallback) {
                    return jobs
                }
                print("[SmartParser] Cached fetch failed, will re-render with WebKit for fresh auth")
                await updateStatus("🔄 Cached schema failed, re-analyzing...", callback: statusCallback)
            }
        }

        // Check if it's a SPA before rendering
        await updateStatus("🌐 Checking site structure...", callback: statusCallback)
        let initialHTML = try await fetchHTML(from: url)
        let hasDataDiv = initialHTML.contains("id=\"root\"") || initialHTML.contains("id=\"app\"")
        let isTiny = initialHTML.count < 10000

        guard hasDataDiv && isTiny else {
            print("[SmartParser] Not a SPA, skipping WebKit rendering")
            return nil
        }

        print("[SmartParser] Detected SPA - using WebKit with API interception...")
        await updateStatus("🔎 Detected SPA, intercepting API calls...", callback: statusCallback)

        // Render with WebKit and intercept API calls
        let renderer = await WebKitRenderer()
        let result = try await renderer.renderWithAPIDetection(from: url, waitTime: 5.0)

        print("[SmartParser] WebKit rendered HTML length: \(result.html.count) chars")
        print("[SmartParser] Detected \(result.detectedAPICalls.count) API calls")
        await updateStatus("📡 Found \(result.detectedAPICalls.count) API calls", callback: statusCallback)

        // Try each detected API call
        for (index, apiCall) in result.detectedAPICalls.enumerated() {
            print("[SmartParser] Trying API endpoint: \(apiCall.url)")
            await updateStatus("🔍 Analyzing API \(index + 1)/\(result.detectedAPICalls.count): \(URL(string: apiCall.url)?.host ?? "unknown")", callback: statusCallback)

            if let jobs = await discoverAndCacheSchema(
                apiCall: apiCall,
                domain: domain,
                titleFilter: titleFilter,
                locationFilter: locationFilter,
                statusCallback: statusCallback
            ), !jobs.isEmpty {
                print("[SmartParser] Successfully fetched \(jobs.count) jobs from intercepted API!")
                await updateStatus("✅ Found \(jobs.count) jobs via API: \(URL(string: apiCall.url)?.path ?? "")", callback: statusCallback)
                await llmParser.unloadModel()  // Free memory
                return jobs
            }
        }

        // No jobs found - mark as failed
        await schemaCache.markLLMAttemptFailed(for: domain)
        await updateStatus("❌ No valid job API found", callback: statusCallback)
        return nil
    }

    /// Fetch jobs using a cached schema (fast path - no LLM needed)
    private func fetchWithCachedSchema(_ schema: DiscoveredAPISchema, titleFilter: String, locationFilter: String, statusCallback: (@Sendable (String) -> Void)?) async -> [Job]? {
        print("[SmartParser] Fetching from cached endpoint: \(schema.endpoint)")

        let jobs = await cachedFetcher.fetchJobs(
            schema: schema,
            titleFilter: titleFilter,
            locationFilter: locationFilter
        )

        if !jobs.isEmpty {
            await schemaCache.updateLastFetched(for: schema.domain)
            print("[SmartParser] Fetched \(jobs.count) jobs using cached schema")
            await updateStatus("✅ Found \(jobs.count) jobs using cached schema", callback: statusCallback)
        }

        return jobs.isEmpty ? nil : jobs
    }

    /// Discover schema using LLM and cache it for future use (one-time operation)
    private func discoverAndCacheSchema(
        apiCall: DetectedAPICall,
        domain: String,
        titleFilter: String,
        locationFilter: String,
        statusCallback: (@Sendable (String) -> Void)?
    ) async -> [Job]? {
        guard let apiURL = URL(string: apiCall.url) else { return nil }

        do {
            // Build request with intercepted headers/body
            var request = URLRequest(url: apiURL)
            request.httpMethod = apiCall.method

            if let body = apiCall.requestBody {
                request.httpBody = body.data(using: .utf8)
            }

            if let headers = apiCall.headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }

            // Fetch API response
            await updateStatus("📥 Fetching API response...", callback: statusCallback)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[SmartParser] API request failed with status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                await updateStatus("❌ API request failed (status: \((response as? HTTPURLResponse)?.statusCode ?? 0))", callback: statusCallback)
                return nil
            }

            guard let jsonString = String(data: data, encoding: .utf8) else {
                await updateStatus("❌ Invalid JSON response", callback: statusCallback)
                return nil
            }

            print("[SmartParser] API response length: \(jsonString.count) chars")
            let sizeKB = Double(jsonString.count) / 1024.0
            await updateStatus("🤖 AI analyzing JSON (\(String(format: "%.1f", sizeKB))KB)...", callback: statusCallback)

            // Use LLM to discover schema
            guard let schema = try await llmParser.discoverJSONSchema(from: jsonString) else {
                print("[SmartParser] Failed to discover schema")
                await updateStatus("❌ AI couldn't find job structure", callback: statusCallback)
                return nil
            }

            await updateStatus("✅ AI discovered schema: \(schema.jobsArrayPath)", callback: statusCallback)

            // Parse jobs using discovered schema
            let parsedJobs = jsonParser.extractJobs(from: jsonString, using: schema, baseURL: apiURL)
            let jobs = parsedJobs.compactMap { convertToJob($0, url: apiURL) }
            let filteredJobs = applyFilters(jobs, titleFilter: titleFilter, locationFilter: locationFilter)

            print("[SmartParser] Extracted \(filteredJobs.count) jobs using discovered schema")

            // Cache schema if successful
            if !filteredJobs.isEmpty {
                let discoveredSchema = DiscoveredAPISchema(
                    domain: domain,
                    endpoint: apiCall.url,
                    method: apiCall.method,
                    requestBody: apiCall.requestBody,
                    requestHeaders: apiCall.headers,
                    responseStructure: schema,
                    paginationInfo: PaginationInfo(
                        type: .offset,
                        pageParam: "offset",
                        pageSizeParam: "limit",
                        maxPages: 3
                    ),
                    sortInfo: nil,
                    discoveredAt: Date(),
                    llmAttempted: true,
                    schemaDiscovered: true,
                    lastAttempt: Date(),
                    lastFetchedAt: Date()
                )

                await schemaCache.saveSchema(discoveredSchema)
                print("[SmartParser] Cached schema for \(domain)")
            }

            return filteredJobs

        } catch {
            print("[SmartParser] Failed to discover schema: \(error)")
            return nil
        }
    }

    // MARK: - Helper Methods

    /// Fetch HTML from URL (basic fetch without rendering)
    private func fetchHTML(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let html = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "SmartJobParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode HTML"])
        }

        let hasDataDiv = html.contains("id=\"root\"") || html.contains("id=\"app\"")
        let hasJobKeywords = html.contains("job") || html.contains("position") || html.contains("career")
        print("[SmartParser] Fetched HTML length: \(html.count) chars, SPA: \(hasDataDiv), Has job keywords: \(hasJobKeywords)")

        return html
    }

    /// Detect ATS platform by scanning HTML and JavaScript source code for platform signatures
    private func detectATSFromHTML(url: URL) async throws -> String? {
        let html = try await fetchHTML(from: url)

        // Extract JavaScript file URLs from HTML
        let jsURLs = extractJavaScriptURLs(from: html, baseURL: url)
        print("[SmartParser] Found \(jsURLs.count) JavaScript files to scan")

        // Collect all content to scan (HTML + JS files)
        var contentToScan = html

        // Fetch up to 5 JavaScript files (prioritize those with "bundle", "app", "main" in name)
        let priorityJS = jsURLs.filter {
            $0.absoluteString.contains("bundle") ||
            $0.absoluteString.contains("app") ||
            $0.absoluteString.contains("main") ||
            $0.absoluteString.contains("vendor")
        }
        let jsToFetch = Array((priorityJS + jsURLs).prefix(5))

        for jsURL in jsToFetch {
            do {
                let (data, _) = try await URLSession.shared.data(from: jsURL)
                if let jsContent = String(data: data, encoding: .utf8) {
                    contentToScan += "\n" + jsContent
                    print("[SmartParser] Fetched JS file: \(jsURL.lastPathComponent) (\(jsContent.count) chars)")
                }
            } catch {
                print("[SmartParser] Failed to fetch JS file \(jsURL.lastPathComponent): \(error)")
            }
        }

        let lowercasedContent = contentToScan.lowercased()
        print("[SmartParser] Scanning \(contentToScan.count) chars of HTML+JS content")

        // Platform signatures to search for (in order of specificity)
        let signatures: [(platform: String, patterns: [String])] = [
            ("Workday", [
                "myworkdayjobs.com",
                "workday.com/api",
                "workday-jobs",
                "workdaycdn.com",
                "wd5.myworkdayjobs",
                "workday_service"
            ]),
            ("Greenhouse", [
                "greenhouse.io",
                "boards.greenhouse.io",
                "greenhouse-jobs",
                "boards-api.greenhouse.io",
                "gh-job-board",
                "greenhouse-embed"
            ]),
            ("Lever", [
                "lever.co",
                "jobs.lever.co",
                "lever-jobs",
                "lever-api",
                "lever-job-board",
                "leverapi"
            ]),
            ("Ashby", [
                "ashbyhq.com",
                "jobs.ashbyhq.com",
                "ashby-jobs",
                "ashby.com/api",
                "ashby-embed"
            ]),
            ("SmartRecruiters", [
                "smartrecruiters.com",
                "jobs.smartrecruiters.com",
                "smartrecruiters-jobs",
                "smartrecruiters-api"
            ]),
            ("BambooHR", [
                "bamboohr.com/jobs",
                "bamboohr-jobs",
                "bamboohr-api"
            ]),
            ("Jobvite", [
                "jobvite.com",
                "jobs.jobvite.com",
                "jobvite-jobs",
                "jobvite-api"
            ])
        ]

        // Check each platform's signatures
        for (platform, patterns) in signatures {
            var matchCount = 0
            var foundPatterns: [String] = []

            for pattern in patterns {
                if lowercasedContent.contains(pattern.lowercased()) {
                    matchCount += 1
                    foundPatterns.append(pattern)
                }
            }

            if matchCount > 0 {
                print("[SmartParser] Found \(matchCount) \(platform) signatures: \(foundPatterns.joined(separator: ", "))")
            }

            // If we found at least 2 signatures for a platform, it's a strong match
            if matchCount >= 2 {
                print("[SmartParser] ✅ Detected \(platform) platform (\(matchCount) signatures matched)")
                return platform
            }
            // Or if we found 1 very specific signature (API endpoint)
            else if matchCount == 1 {
                for pattern in foundPatterns {
                    if pattern.contains("api") || pattern.contains("boards.") || pattern.contains("-embed") {
                        print("[SmartParser] ✅ Detected \(platform) platform (strong signature: \(pattern))")
                        return platform
                    }
                }
            }
        }

        print("[SmartParser] No ATS platform signatures detected in HTML+JS")
        return nil
    }

    /// Extract JavaScript file URLs from HTML
    private func extractJavaScriptURLs(from html: String, baseURL: URL) -> [URL] {
        var jsURLs: [URL] = []

        // Simple regex to find script src attributes
        let scriptPattern = #"<script[^>]+src=["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: scriptPattern, options: .caseInsensitive) else {
            return []
        }

        let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))

        for match in matches {
            if match.numberOfRanges > 1,
               let srcRange = Range(match.range(at: 1), in: html) {
                let srcString = String(html[srcRange])

                // Skip data URIs and very small inline scripts
                guard !srcString.starts(with: "data:"),
                      srcString.count > 10 else { continue }

                // Convert to absolute URL
                if let url = URL(string: srcString, relativeTo: baseURL)?.absoluteURL {
                    jsURLs.append(url)
                }
            }
        }

        return jsURLs
    }

    /// Convert ParsedJob to Job model
    private func convertToJob(_ parsed: ParsedJob, url: URL) -> Job? {
        guard !parsed.title.isEmpty else { return nil }

        return Job(
            id: "llm-\(UUID().uuidString)",
            title: parsed.title,
            location: parsed.location ?? "Unknown",
            postingDate: nil,
            url: parsed.url ?? url.absoluteString,
            description: parsed.description ?? "",
            workSiteFlexibility: nil,
            source: .unknown,
            companyName: url.host?.replacingOccurrences(of: "www.", with: "").capitalized,
            department: nil,
            category: nil,
            firstSeenDate: Date(),
            originalPostingDate: nil,
            wasBumped: false
        )
    }

    /// Apply title and location filters
    private func applyFilters(_ jobs: [Job], titleFilter: String, locationFilter: String) -> [Job] {
        var filtered = jobs

        if !titleFilter.isEmpty {
            let keywords = titleFilter.lowercased().components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            filtered = filtered.filter { job in
                let jobTitle = job.title.lowercased()
                return keywords.contains { jobTitle.contains($0) }
            }
        }

        if !locationFilter.isEmpty {
            let locations = locationFilter.lowercased().components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            filtered = filtered.filter { job in
                let jobLocation = job.location.lowercased()
                return locations.contains { jobLocation.contains($0) }
            }
        }

        return filtered
    }
}

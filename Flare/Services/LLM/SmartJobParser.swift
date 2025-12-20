//
//  SmartJobParser.swift
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

        // Step 2: Fall back to LLM if enabled
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

            // WebKit approach didn't work - try regex-based script scanning first (fast)
            print("[SmartParser] WebKit approach failed, scanning scripts for patterns...")
            await updateStatus("🔍 Scanning page for job board patterns...", callback: statusCallback)

            let html = try await fetchHTML(from: url)

            // Step 1: Fast regex-based scanning of <script> tags (no LLM needed)
            let scanResult = scanScriptsForPatterns(in: html)

            // Check if we found ATS URLs via regex
            if let firstATSURL = scanResult.atsURLs.first,
               let atsType = scanResult.atsType {
                print("[SmartParser] Regex found ATS: \(atsType) at \(firstATSURL)")
                await updateStatus("🎯 Found \(atsType.capitalized) ATS: \(firstATSURL)", callback: statusCallback)

                if let detectedURL = URL(string: firstATSURL) {
                    let jobs = try await fetchFromDetectedATS(
                        url: detectedURL,
                        atsType: atsType,
                        titleFilter: titleFilter,
                        locationFilter: locationFilter,
                        statusCallback: statusCallback
                    )
                    if !jobs.isEmpty {
                        return jobs
                    }
                }
            }

            // Check if we found API endpoints via regex
            for endpoint in scanResult.apiEndpoints.prefix(3) {
                print("[SmartParser] Trying regex-detected API: \(endpoint)")
                if let jobs = await tryDetectedAPIEndpoint(
                    endpoint: endpoint,
                    apiType: "rest",
                    baseURL: url,
                    titleFilter: titleFilter,
                    locationFilter: locationFilter,
                    statusCallback: statusCallback
                ) {
                    return jobs
                }
            }

            // Check if we found embedded JSON with job data
            for json in scanResult.embeddedJSON {
                print("[SmartParser] Trying embedded JSON (\(json.count) chars)...")
                if let schema = try? await llmParser.discoverJSONSchema(from: json) {
                    let parsedJobs = jsonParser.extractJobs(from: json, using: schema, baseURL: url)
                    let jobs = parsedJobs.compactMap { convertToJob($0, url: url) }
                    let filteredJobs = applyFilters(jobs, titleFilter: titleFilter, locationFilter: locationFilter)
                    if !filteredJobs.isEmpty {
                        await updateStatus("✅ Found \(filteredJobs.count) jobs in embedded JSON", callback: statusCallback)
                        return filteredJobs
                    }
                }
            }

            // Step 2: If regex found nothing, use LLM for pattern detection
            print("[SmartParser] Regex scan found nothing, trying LLM pattern detection...")
            await updateStatus("🤖 AI analyzing page for hidden patterns...", callback: statusCallback)

            if let patternResult = try await llmParser.detectPatternsInContent(html, sourceURL: url) {
                // Found an ATS URL - return it for the caller to use dedicated fetcher
                if let atsURL = patternResult.atsURL,
                   let atsType = patternResult.atsType,
                   atsType != "null",
                   patternResult.confidence != "low" {
                    print("[SmartParser] LLM detected ATS: \(atsType) at \(atsURL)")
                    await updateStatus("🎯 AI found \(atsType.capitalized) ATS: \(atsURL)", callback: statusCallback)

                    // Try to fetch from the detected ATS URL
                    if let detectedURL = URL(string: atsURL) {
                        let jobs = try await fetchFromDetectedATS(
                            url: detectedURL,
                            atsType: atsType,
                            titleFilter: titleFilter,
                            locationFilter: locationFilter,
                            statusCallback: statusCallback
                        )
                        if !jobs.isEmpty {
                            return jobs
                        }
                    }
                }

                // Found an API endpoint - try to fetch and parse it
                if let apiEndpoint = patternResult.apiEndpoint,
                   let apiType = patternResult.apiType,
                   apiType != "null",
                   patternResult.confidence != "low" {
                    print("[SmartParser] LLM detected API: \(apiType) at \(apiEndpoint)")
                    await updateStatus("🎯 AI found \(apiType.uppercased()) API endpoint", callback: statusCallback)

                    if let jobs = await tryDetectedAPIEndpoint(
                        endpoint: apiEndpoint,
                        apiType: apiType,
                        baseURL: url,
                        titleFilter: titleFilter,
                        locationFilter: locationFilter,
                        statusCallback: statusCallback
                    ) {
                        return jobs
                    }
                }
            }

            // Step 2: Fall back to direct HTML extraction with LLM
            print("[SmartParser] No patterns found, attempting direct HTML parsing...")
            await updateStatus("📄 Analyzing HTML content with AI...", callback: statusCallback)
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

    /// Fetch jobs from a detected ATS URL using the appropriate dedicated fetcher
    private func fetchFromDetectedATS(url: URL, atsType: String, titleFilter: String, locationFilter: String, statusCallback: (@Sendable (String) -> Void)?) async throws -> [Job] {
        await updateStatus("⚡ Fetching from \(atsType.capitalized)...", callback: statusCallback)

        switch atsType.lowercased() {
        case "workday":
            let fetcher = WorkdayFetcher()
            return try await fetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case "greenhouse":
            let fetcher = GreenhouseFetcher()
            return try await fetcher.fetchGreenhouseJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case "lever":
            let fetcher = LeverFetcher()
            return try await fetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case "ashby":
            let fetcher = AshbyFetcher()
            return try await fetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        default:
            print("[SmartParser] Unknown ATS type: \(atsType)")
            return []
        }
    }

    /// Try to fetch jobs from a detected API endpoint
    private func tryDetectedAPIEndpoint(endpoint: String, apiType: String, baseURL: URL, titleFilter: String, locationFilter: String, statusCallback: (@Sendable (String) -> Void)?) async -> [Job]? {
        guard let apiURL = URL(string: endpoint, relativeTo: baseURL)?.absoluteURL else {
            print("[SmartParser] Invalid API endpoint URL: \(endpoint)")
            return nil
        }

        await updateStatus("📡 Fetching from detected API...", callback: statusCallback)

        do {
            var request = URLRequest(url: apiURL)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[SmartParser] API request failed: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }

            guard let jsonString = String(data: data, encoding: .utf8) else {
                return nil
            }

            print("[SmartParser] API response: \(jsonString.prefix(500))...")

            // Use LLM to discover schema and parse
            guard let schema = try await llmParser.discoverJSONSchema(from: jsonString) else {
                print("[SmartParser] Failed to discover schema for API response")
                return nil
            }

            let parsedJobs = jsonParser.extractJobs(from: jsonString, using: schema, baseURL: apiURL)
            let jobs = parsedJobs.compactMap { convertToJob($0, url: apiURL) }
            let filteredJobs = applyFilters(jobs, titleFilter: titleFilter, locationFilter: locationFilter)

            if !filteredJobs.isEmpty {
                await updateStatus("✅ Found \(filteredJobs.count) jobs from detected API", callback: statusCallback)
                return filteredJobs
            }

        } catch {
            print("[SmartParser] Failed to fetch from detected API: \(error)")
        }

        return nil
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

        // Check for common SPA framework root elements
        let spaPatterns = [
            "id=\"root\"", "id='root'",           // React
            "id=\"app\"", "id='app'",             // Vue, generic
            "id=\"__next\"", "id='__next'",       // Next.js
            "<app-root", "ng-app", "ng-version",  // Angular
            "id=\"__nuxt\"", "id='__nuxt'",       // Nuxt.js
            "data-reactroot",                      // React
            "data-v-"                              // Vue
        ]
        let hasDataDiv = spaPatterns.contains { initialHTML.contains($0) }
        let isTiny = initialHTML.count < 50000  // Generous threshold - many SPAs include inline styles/scripts

        // Also check for minimal content - SPAs often have very little actual content in the initial HTML
        let hasMinimalContent = !initialHTML.contains("<table") &&
                                 !initialHTML.contains("<ul class=\"jobs") &&
                                 !initialHTML.contains("job-listing")

        guard hasDataDiv && (isTiny || hasMinimalContent) else {
            print("[SmartParser] Not a SPA (hasDataDiv: \(hasDataDiv), size: \(initialHTML.count), minimalContent: \(hasMinimalContent)), skipping WebKit rendering")
            return nil
        }

        print("[SmartParser] Detected SPA - using WebKit with API interception...")
        await updateStatus("🔎 Detected SPA, intercepting API calls...", callback: statusCallback)

        // Render with WebKit and intercept API calls
        // Use longer wait time (8s) for first-time discovery to ensure all API calls complete
        let renderer = await WebKitRenderer()
        let result = try await renderer.renderWithAPIDetection(from: url, waitTime: 8.0)

        print("[SmartParser] WebKit rendered HTML length: \(result.html.count) chars")
        print("[SmartParser] Detected \(result.detectedAPICalls.count) API calls")
        await updateStatus("📡 Found \(result.detectedAPICalls.count) API calls", callback: statusCallback)

        // Try each detected API call
        var foundJobs: [Job]? = nil
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
                foundJobs = jobs
                break
            }
        }

        // Always unload model to free ~2GB memory, regardless of success or failure
        await llmParser.unloadModel()

        if let jobs = foundJobs {
            return jobs
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
                // Use LLM-discovered pagination params if available, otherwise use defaults
                let paginationType: PaginationType
                let pageParam: String?
                let pageSizeParam: String?

                if let discoveredParam = schema.paginationParam?.lowercased() {
                    if discoveredParam.contains("cursor") {
                        paginationType = .cursor
                        pageParam = schema.paginationParam
                    } else if discoveredParam.contains("page") && !discoveredParam.contains("size") {
                        paginationType = .page
                        pageParam = schema.paginationParam
                    } else {
                        paginationType = .offset
                        pageParam = schema.paginationParam
                    }
                    pageSizeParam = schema.pageSizeParam
                } else {
                    // Default fallback
                    paginationType = .offset
                    pageParam = "offset"
                    pageSizeParam = "limit"
                }

                let discoveredSchema = DiscoveredAPISchema(
                    domain: domain,
                    endpoint: apiCall.url,
                    method: apiCall.method,
                    requestBody: apiCall.requestBody,
                    requestHeaders: apiCall.headers,
                    responseStructure: schema,
                    paginationInfo: PaginationInfo(
                        type: paginationType,
                        pageParam: pageParam,
                        pageSizeParam: pageSizeParam,
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

    // MARK: - Pre-LLM Script Scanning (Fast Regex-based Detection)

    /// Result of scanning HTML for ATS/API patterns
    struct ScriptScanResult {
        let atsURLs: [String]           // Detected ATS URLs
        let atsType: String?            // Primary ATS type detected
        let apiEndpoints: [String]      // Detected API endpoints
        let embeddedJSON: [String]      // JSON blobs found in scripts
    }

    /// Scan HTML <script> tags for ATS URLs, API endpoints, and embedded JSON
    /// This is faster than LLM and catches patterns before we need AI
    private func scanScriptsForPatterns(in html: String) -> ScriptScanResult {
        var atsURLs: [String] = []
        var apiEndpoints: [String] = []
        var embeddedJSON: [String] = []
        var detectedATSType: String?

        // Extract all script tag contents
        let scriptPattern = #"<script[^>]*>([\s\S]*?)</script>"#
        let scriptRegex = try? NSRegularExpression(pattern: scriptPattern, options: .caseInsensitive)
        let range = NSRange(html.startIndex..., in: html)

        var allScriptContent = ""
        scriptRegex?.enumerateMatches(in: html, range: range) { match, _, _ in
            if let match = match, let contentRange = Range(match.range(at: 1), in: html) {
                allScriptContent += String(html[contentRange]) + "\n"
            }
        }

        // Also scan the full HTML for inline patterns
        let contentToScan = allScriptContent + html

        // ATS URL patterns (both normal and escaped formats)
        let atsPatterns: [(pattern: String, type: String)] = [
            (#"https?:(?:\\/\\/|//)[\w.-]*\.myworkdayjobs\.com[^\s"'<>]*"#, "workday"),
            (#"https?:(?:\\/\\/|//)[^"'\s]*greenhouse\.io[^\s"'<>]*"#, "greenhouse"),
            (#"https?:(?:\\/\\/|//)[^"'\s]*lever\.co[^\s"'<>]*"#, "lever"),
            (#"https?:(?:\\/\\/|//)[^"'\s]*ashbyhq\.com[^\s"'<>]*"#, "ashby"),
        ]

        for (pattern, atsType) in atsPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: contentToScan, range: NSRange(contentToScan.startIndex..., in: contentToScan))
                for match in matches {
                    if let range = Range(match.range, in: contentToScan) {
                        var url = String(contentToScan[range])
                        // Unescape escaped URLs
                        url = url.replacingOccurrences(of: "\\/", with: "/")
                        // Clean up trailing punctuation
                        url = url.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,;"))
                        if !atsURLs.contains(url) && url.contains(".") {
                            atsURLs.append(url)
                            if detectedATSType == nil {
                                detectedATSType = atsType
                            }
                        }
                    }
                }
            }
        }

        // API endpoint patterns
        let apiPatterns = [
            #"["']?(https?://[^"'\s]*(?:/api/|/graphql|/v[0-9]+/)[^"'\s]*?)["']?"#,
            #"["']?(/api/[^"'\s]+)["']?"#,
            #"["']?(/graphql[^"'\s]*)["']?"#,
            #"["']?(/careers/api[^"'\s]*)["']?"#,
            #"["']?(/jobs/api[^"'\s]*)["']?"#,
        ]

        for pattern in apiPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: contentToScan, range: NSRange(contentToScan.startIndex..., in: contentToScan))
                for match in matches.prefix(5) { // Limit to first 5 matches
                    let captureRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                    if let range = Range(captureRange, in: contentToScan) {
                        let endpoint = String(contentToScan[range])
                        if !apiEndpoints.contains(endpoint) && endpoint.count > 5 {
                            apiEndpoints.append(endpoint)
                        }
                    }
                }
            }
        }

        // Look for embedded JSON with job data (window.__INITIAL_STATE__, etc.)
        let jsonPatterns = [
            #"window\.__INITIAL_STATE__\s*=\s*(\{[\s\S]*?\});?"#,
            #"window\.__data\s*=\s*(\{[\s\S]*?\});?"#,
            #"window\.pageData\s*=\s*(\{[\s\S]*?\});?"#,
            #""jobs"\s*:\s*(\[[\s\S]*?\])"#,
            #""positions"\s*:\s*(\[[\s\S]*?\])"#,
            #""openings"\s*:\s*(\[[\s\S]*?\])"#,
        ]

        for pattern in jsonPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: allScriptContent, range: NSRange(allScriptContent.startIndex..., in: allScriptContent))
                for match in matches.prefix(3) { // Limit to first 3 matches
                    if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: allScriptContent) {
                        let json = String(allScriptContent[range])
                        if json.count > 100 && json.count < 500000 { // Reasonable size
                            embeddedJSON.append(json)
                        }
                    }
                }
            }
        }

        print("[SmartParser] Script scan: \(atsURLs.count) ATS URLs, \(apiEndpoints.count) API endpoints, \(embeddedJSON.count) JSON blobs")
        if !atsURLs.isEmpty {
            print("[SmartParser] Found ATS URLs: \(atsURLs.prefix(3))")
        }
        if !apiEndpoints.isEmpty {
            print("[SmartParser] Found API endpoints: \(apiEndpoints.prefix(3))")
        }

        return ScriptScanResult(
            atsURLs: atsURLs,
            atsType: detectedATSType,
            apiEndpoints: apiEndpoints,
            embeddedJSON: embeddedJSON
        )
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

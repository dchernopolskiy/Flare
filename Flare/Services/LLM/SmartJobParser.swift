//
//  SmartJobParser.swift
//  Flare
//
//  Created by Dan on 12/9/25.
//

import Foundation

// MARK: - Shared Constants for Job Extraction

/// Common field names and patterns used across job extraction methods
enum JobExtractionPatterns {
    /// Common field names for job titles
    static let titleFields = ["title", "text", "name", "position", "jobTitle", "role"]

    /// Common field names for job locations
    static let locationFields = ["location", "locations", "office", "city", "region", "cityState"]

    /// Common field names for job URLs
    static let urlFields = ["url", "link", "href", "applyURL", "applyUrl", "jobUrl", "originalURL"]

    /// Common field names for job IDs
    static let idFields = ["id", "jobId", "requisitionID", "uniqueID", "slug"]

    /// Common keys where job arrays are found in API responses
    static let jobArrayKeys = ["result", "results", "jobs", "data", "items", "positions", "listings", "openings"]

    /// Analytics and tracking patterns to exclude from API detection
    static let trackingExcludePatterns = [
        // Analytics platforms
        "analytics", "google-analytics", "gtm", "amplitude", "mixpanel", "heap",
        // Tracking/pixels
        "pixel", "tracking", "beacon", "collect", "event",
        // Monitoring
        "metrics", "telemetry", "log", "stat", "click",
        // Session replay
        "fullstory", "logrocket", "hotjar",
        // Error tracking
        "sentry", "bugsnag", "newrelic", "datadog", "dynatrace",
        // Marketing/CRM
        "facebook", "segment", "intercom", "drift", "hubspot", "marketo", "salesforce",
        // Other
        "optimize-pixel"
    ]

    /// Job-related URL patterns to prioritize
    static let jobRelatedPatterns = ["job", "career", "position", "opening", "search", "listing"]

    /// Check if a URL is likely tracking/analytics
    static func isTrackingURL(_ url: String) -> Bool {
        let lowercased = url.lowercased()
        return trackingExcludePatterns.contains { lowercased.contains($0) }
    }

    /// Check if a URL is likely job-related
    static func isJobRelatedURL(_ url: String) -> Bool {
        let lowercased = url.lowercased()
        return jobRelatedPatterns.contains { lowercased.contains($0) }
    }
}

/// Cache for detected ATS URLs - maps original URL domain to detected ATS info
actor DetectedATSCache {
    static let shared = DetectedATSCache()

    private var cache: [String: (atsURL: String, atsType: String)] = [:]

    func store(for domain: String, atsURL: String, atsType: String) {
        cache[domain] = (atsURL, atsType)
        print("[DetectedATSCache] Stored \(atsType) at \(atsURL) for \(domain)")
    }

    func get(for domain: String) -> (atsURL: String, atsType: String)? {
        return cache[domain]
    }

    func clear(for domain: String) {
        cache.removeValue(forKey: domain)
    }
}

/// Smart job parser that tries multiple strategies in order:
/// 1. API/ATS detection (UniversalJobFetcher - for known platforms like Greenhouse, Lever, etc.)
/// 2. LLM parsing with schema caching (for custom career sites)
actor SmartJobParser {
    private let universalFetcher = UniversalJobFetcher()
    private let llmParser = LLMParser.shared
    private let schemaCache = APISchemaCache.shared
    private let jsonParser = UniversalJSONParser()
    private let cachedFetcher = CachedSchemaFetcher()
    private let detectedATSCache = DetectedATSCache.shared

    /// Parse jobs from a URL using the best available method
    /// - Parameters:
    ///   - url: URL to parse jobs from
    ///   - titleFilter: Optional job title filter
    ///   - locationFilter: Optional location filter
    ///   - statusCallback: Optional callback for status updates (called on MainActor)
    func parseJobs(from url: URL, titleFilter: String = "", locationFilter: String = "", statusCallback: (@Sendable (String) -> Void)? = nil) async -> [Job] {
        // Auto-upgrade HTTP to HTTPS to comply with App Transport Security
        var secureURL = url
        if let scheme = url.scheme?.lowercased(), scheme == "http" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if let httpsURL = components?.url {
                secureURL = httpsURL
                print("[SmartParser] Auto-upgraded HTTP to HTTPS: \(secureURL.absoluteString)")
            }
        }

        print("[SmartParser] Parsing jobs from: \(secureURL.absoluteString)")
        await updateStatus("🔍 Analyzing website...", callback: statusCallback)

        // Step 1: Try API/ATS detection first (for known platforms)
        do {
            await updateStatus("⚡ Trying API/ATS detection...", callback: statusCallback)
            let jobs = try await universalFetcher.fetchJobs(from: secureURL, titleFilter: titleFilter, locationFilter: locationFilter)
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
            return await parseWithLLM(url: secureURL, titleFilter: titleFilter, locationFilter: locationFilter, statusCallback: statusCallback)
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

        var jobs: [Job] = []
        switch atsType.lowercased() {
        case "workday":
            let fetcher = WorkdayFetcher()
            jobs = try await fetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case "greenhouse":
            let fetcher = GreenhouseFetcher()
            jobs = try await fetcher.fetchGreenhouseJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case "lever":
            let fetcher = LeverFetcher()
            jobs = try await fetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case "ashby":
            let fetcher = AshbyFetcher()
            jobs = try await fetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        default:
            print("[SmartParser] Unknown ATS type: \(atsType)")
            await updateStatus("❌ Unknown ATS type: \(atsType)", callback: statusCallback)
            return []
        }

        // Update status after successful fetch
        if jobs.isEmpty {
            await updateStatus("❌ No jobs found from \(atsType.capitalized)", callback: statusCallback)
        } else {
            await updateStatus("✅ Found \(jobs.count) jobs from \(atsType.capitalized)", callback: statusCallback)
        }
        return jobs
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

        // Track whether LLM previously failed (we'll still do WebKit + regex, just skip LLM)
        var skipLLMAnalysis = false

        // Check cache first
        if let cachedSchema = await schemaCache.getSchema(for: domain) {
            // Check if LLM previously failed - retry after 7 days
            if cachedSchema.llmAttempted && !cachedSchema.schemaDiscovered {
                let daysSinceLastAttempt = Date().timeIntervalSince(cachedSchema.lastAttempt) / (24 * 60 * 60)

                if daysSinceLastAttempt < 7 {
                    print("[SmartParser] LLM previously failed for \(domain) (\(Int(daysSinceLastAttempt)) days ago) - will still try WebKit + regex scan")
                    await updateStatus("🔍 Scanning for job board patterns...", callback: statusCallback)
                    skipLLMAnalysis = true  // Skip LLM but still do WebKit rendering
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
        // If LLM previously failed, try without schema discovery (simple JSON extraction)
        var foundJobs: [Job]? = nil

        // Filter API calls to prioritize job-related ones and exclude tracking
        let jobRelatedAPICalls = result.detectedAPICalls.filter { apiCall in
            JobExtractionPatterns.isJobRelatedURL(apiCall.url) && !JobExtractionPatterns.isTrackingURL(apiCall.url)
        }

        // Use job-related calls first, fall back to all calls if none found
        let apiCallsToTry = jobRelatedAPICalls.isEmpty ? result.detectedAPICalls : jobRelatedAPICalls

        for (index, apiCall) in apiCallsToTry.enumerated() {
            print("[SmartParser] Trying API endpoint: \(apiCall.url)")
            await updateStatus("🔍 Analyzing API \(index + 1)/\(apiCallsToTry.count): \(URL(string: apiCall.url)?.host ?? "unknown")", callback: statusCallback)

            if skipLLMAnalysis {
                // Try simple JSON extraction without LLM schema discovery
                if let jobs = await trySimpleAPIExtraction(
                    apiCall: apiCall,
                    baseURL: url,
                    titleFilter: titleFilter,
                    locationFilter: locationFilter,
                    statusCallback: statusCallback
                ), !jobs.isEmpty {
                    print("[SmartParser] Successfully fetched \(jobs.count) jobs via simple extraction!")
                    await updateStatus("✅ Found \(jobs.count) jobs via API: \(URL(string: apiCall.url)?.path ?? "")", callback: statusCallback)
                    foundJobs = jobs
                    break
                }
            } else {
                // Try LLM schema discovery first
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

                // LLM failed - try simple extraction as fallback
                print("[SmartParser] LLM schema discovery failed, trying simple extraction...")
                await updateStatus("🔄 Trying simpler extraction method...", callback: statusCallback)
                if let jobs = await trySimpleAPIExtraction(
                    apiCall: apiCall,
                    baseURL: url,
                    titleFilter: titleFilter,
                    locationFilter: locationFilter,
                    statusCallback: statusCallback
                ), !jobs.isEmpty {
                    print("[SmartParser] Successfully fetched \(jobs.count) jobs via simple extraction fallback!")
                    await updateStatus("✅ Found \(jobs.count) jobs via API: \(URL(string: apiCall.url)?.path ?? "")", callback: statusCallback)
                    foundJobs = jobs
                    break
                }
            }
        }

        if let jobs = foundJobs {
            // Unload model on success
            await llmParser.unloadModel()
            return jobs
        }

        // Scan the RENDERED HTML for ATS patterns
        // This catches URLs injected by GTM/JS that weren't in the initial HTML
        // We do this when: no API calls found, or API calls didn't return jobs
        print("[SmartParser] Scanning WebKit-rendered HTML for ATS patterns...")
        await updateStatus("🔍 Scanning rendered page for job board patterns...", callback: statusCallback)

        let renderedScanResult = scanScriptsForPatterns(in: result.html)

        // Check if we found ATS URLs in the rendered content
        if let firstATSURL = renderedScanResult.atsURLs.first,
           let atsType = renderedScanResult.atsType {
            // Extract base ATS URL (remove job detail path, trailing backslash)
            let baseATSURL = extractBaseATSURL(from: firstATSURL, atsType: atsType)
            print("[SmartParser] Found ATS in rendered HTML: \(atsType)")
            print("[SmartParser] Original URL: \(firstATSURL)")
            print("[SmartParser] Base URL: \(baseATSURL)")
            await updateStatus("🎯 Found \(atsType.capitalized) in rendered page!", callback: statusCallback)

            // Store in cache for future refreshes
            await detectedATSCache.store(for: domain, atsURL: baseATSURL, atsType: atsType)

            // Unload model before using dedicated fetcher
            await llmParser.unloadModel()

            if let detectedURL = URL(string: baseATSURL) {
                do {
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
                } catch {
                    print("[SmartParser] Failed to fetch from detected ATS: \(error)")
                }
            }
        }

        // Check for API endpoints in rendered HTML
        for endpoint in renderedScanResult.apiEndpoints.prefix(3) {
            print("[SmartParser] Trying rendered HTML API: \(endpoint)")
            if let jobs = await tryDetectedAPIEndpoint(
                endpoint: endpoint,
                apiType: "rest",
                baseURL: url,
                titleFilter: titleFilter,
                locationFilter: locationFilter,
                statusCallback: statusCallback
            ) {
                await llmParser.unloadModel()
                return jobs
            }
        }

        // Always unload model to free ~2GB memory
        await llmParser.unloadModel()

        // No jobs found - mark as failed (only if we haven't already cached a failure)
        if !skipLLMAnalysis {
            await schemaCache.markLLMAttemptFailed(for: domain)
        }
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

    /// Try simple JSON extraction without LLM (for when LLM previously failed)
    /// This uses heuristics to find job arrays in common JSON structures
    private func trySimpleAPIExtraction(
        apiCall: DetectedAPICall,
        baseURL: URL,
        titleFilter: String,
        locationFilter: String,
        statusCallback: (@Sendable (String) -> Void)?
    ) async -> [Job]? {
        guard let apiURL = URL(string: apiCall.url) else {
            print("[SmartParser] Simple extraction: invalid URL")
            return nil
        }

        print("[SmartParser] Attempting simple extraction from: \(apiURL.absoluteString)")

        do {
            var request = URLRequest(url: apiURL)
            request.httpMethod = apiCall.method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

            if let headers = apiCall.headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) else {
                return nil
            }

            // Try to find job array in common locations
            var jobArray: [[String: Any]]?

            if let array = json as? [[String: Any]] {
                jobArray = array
            } else if let dict = json as? [String: Any] {
                // Use shared constants for job array keys
                for key in JobExtractionPatterns.jobArrayKeys {
                    if let array = dict[key] as? [[String: Any]], !array.isEmpty {
                        jobArray = array
                        break
                    }
                }
            }

            guard let jobs = jobArray, !jobs.isEmpty else {
                print("[SmartParser] Simple extraction: no job array found in JSON")
                return nil
            }

            print("[SmartParser] Simple extraction: found \(jobs.count) items in job array")

            // Extract jobs using shared field patterns
            var extractedJobs: [Job] = []

            for jobDict in jobs {
                // Find title using shared patterns
                var title: String?
                for field in JobExtractionPatterns.titleFields {
                    if let t = jobDict[field] as? String, !t.isEmpty {
                        title = t
                        break
                    }
                }
                guard let jobTitle = title else { continue }

                // Find location using shared patterns
                var location = "Not specified"
                for field in JobExtractionPatterns.locationFields {
                    if let loc = jobDict[field] as? String {
                        location = loc
                        break
                    } else if let locs = jobDict[field] as? [[String: Any]], let first = locs.first {
                        // Handle array of location objects (like Spotify, T-Mobile)
                        if let loc = first["cityState"] as? String {
                            location = loc
                        } else if let loc = first["location"] as? String {
                            location = loc
                        } else if let loc = first["name"] as? String {
                            location = loc
                        }
                        break
                    }
                }

                // Find URL using shared patterns
                var jobURL = baseURL.absoluteString
                for field in JobExtractionPatterns.urlFields {
                    if let u = jobDict[field] as? String {
                        if u.hasPrefix("http") {
                            jobURL = u
                        } else {
                            // Build URL from ID/slug
                            jobURL = "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")/jobs/\(u)"
                        }
                        break
                    }
                }

                let job = Job(
                    id: "simple-\(UUID().uuidString)",
                    title: jobTitle,
                    location: location,
                    postingDate: nil,
                    url: jobURL,
                    description: "",
                    workSiteFlexibility: nil,
                    source: .unknown,
                    companyName: baseURL.host?.replacingOccurrences(of: "www.", with: "").capitalized,
                    department: nil,
                    category: nil,
                    firstSeenDate: Date(),
                    originalPostingDate: nil,
                    wasBumped: false
                )
                extractedJobs.append(job)
            }

            print("[SmartParser] Simple extraction: extracted \(extractedJobs.count) jobs before filtering")
            let filteredJobs = applyFilters(extractedJobs, titleFilter: titleFilter, locationFilter: locationFilter)
            print("[SmartParser] Simple extraction: \(filteredJobs.count) jobs after filtering")
            return filteredJobs.isEmpty ? nil : filteredJobs

        } catch {
            print("[SmartParser] Simple API extraction failed: \(error)")
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
                        // Clean up trailing punctuation and HTML entities
                        url = url.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,;"))
                            .replacingOccurrences(of: "&#34", with: "")
                            .replacingOccurrences(of: "&quot;", with: "")

                        // Extract base URL (handles /apply, /login, /job/... paths)
                        let baseURL = extractBaseATSURL(from: url, atsType: atsType)

                        if !atsURLs.contains(baseURL) && baseURL.contains(".") {
                            atsURLs.append(baseURL)
                            if detectedATSType == nil {
                                detectedATSType = atsType
                            }
                        }
                    }
                }
            }
        }

        // API endpoint patterns - prioritize job-related APIs
        let apiPatterns = [
            // Job-specific API patterns (higher priority)
            #"["']?(/api/get-jobs[^"'\s]*)["']?"#,
            #"["']?(/api/jobs[^"'\s]*)["']?"#,
            #"["']?(/api/careers[^"'\s]*)["']?"#,
            #"["']?(/api/positions[^"'\s]*)["']?"#,
            #"["']?(/api/openings[^"'\s]*)["']?"#,
            #"["']?(/careers/api[^"'\s]*)["']?"#,
            #"["']?(/jobs/api[^"'\s]*)["']?"#,
            // Generic API patterns
            #"["']?(https?://[^"'\s]*(?:/api/|/graphql|/v[0-9]+/)[^"'\s]*?)["']?"#,
            #"["']?(/api/[^"'\s]+)["']?"#,
            #"["']?(/graphql[^"'\s]*)["']?"#,
        ]

        // Use shared exclusion patterns
        for pattern in apiPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: contentToScan, range: NSRange(contentToScan.startIndex..., in: contentToScan))
                for match in matches.prefix(5) { // Limit to first 5 matches
                    let captureRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                    if let range = Range(captureRange, in: contentToScan) {
                        let endpoint = String(contentToScan[range])

                        // Skip excluded patterns using shared helper
                        if JobExtractionPatterns.isTrackingURL(endpoint) {
                            continue
                        }

                        if !apiEndpoints.contains(endpoint) && endpoint.count > 5 {
                            apiEndpoints.append(endpoint)
                        }
                    }
                }
            }
        }

        // Look for embedded JSON with job data
        // Note: __PRELOAD_STATE__ is handled by UniversalJobFetcher's JavaScript execution
        // which runs first and has access to the browser context
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

    /// Extract base ATS URL from a job detail URL
    /// Converts: https://company.wd5.myworkdayjobs.com/SiteName/job/Location/Title_ID\
    /// To: https://company.wd5.myworkdayjobs.com/SiteName/
    private func extractBaseATSURL(from url: String, atsType: String) -> String {
        // Remove trailing backslash, quotes, and HTML entities
        var cleanURL = url
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\\"'"))
            .replacingOccurrences(of: "&#34", with: "")
            .replacingOccurrences(of: "&quot;", with: "")
            .replacingOccurrences(of: "&amp;", with: "&")

        switch atsType.lowercased() {
        case "workday":
            // Workday formats we might encounter:
            // - https://company.wd5.myworkdayjobs.com/SiteName/job/Location/Title_ID
            // - https://company.wd5.myworkdayjobs.com/SiteName/job/Location/Title_ID/apply
            // - https://company.wd5.myworkdayjobs.com/SiteName/login
            // We want: https://company.wd5.myworkdayjobs.com/SiteName/

            // First, remove /apply suffix if present
            if cleanURL.hasSuffix("/apply") {
                cleanURL = String(cleanURL.dropLast(6))
            }

            // Remove /login suffix if present
            if cleanURL.hasSuffix("/login") {
                cleanURL = String(cleanURL.dropLast(6))
            }

            // Now extract base URL up to /job/ or just the site name
            if let range = cleanURL.range(of: "/job/", options: .caseInsensitive) {
                cleanURL = String(cleanURL[..<range.lowerBound]) + "/"
            } else if let range = cleanURL.range(of: "/details/", options: .caseInsensitive) {
                cleanURL = String(cleanURL[..<range.lowerBound]) + "/"
            }
        case "greenhouse":
            // Greenhouse format: https://boards.greenhouse.io/company/jobs/12345
            // We want: https://boards.greenhouse.io/company
            if let range = cleanURL.range(of: "/jobs/", options: .caseInsensitive) {
                cleanURL = String(cleanURL[..<range.lowerBound])
            }
        case "lever":
            // Lever format: https://jobs.lever.co/company/job-id
            // We want: https://jobs.lever.co/company
            if let url = URL(string: cleanURL),
               let host = url.host,
               host.contains("lever.co") {
                let components = url.pathComponents.filter { $0 != "/" }
                if let company = components.first {
                    cleanURL = "https://\(host)/\(company)"
                }
            }
        case "ashby":
            // Ashby format: https://jobs.ashbyhq.com/company/job-id
            // We want: https://jobs.ashbyhq.com/company
            if let url = URL(string: cleanURL),
               let host = url.host,
               host.contains("ashbyhq.com") {
                let components = url.pathComponents.filter { $0 != "/" }
                if let company = components.first {
                    cleanURL = "https://\(host)/\(company)"
                }
            }
        default:
            break
        }

        return cleanURL
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

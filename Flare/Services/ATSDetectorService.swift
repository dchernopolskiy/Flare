//
//  ATSDetectorService.swift
//  MSJobMonitor
//

import Foundation
import WebKit

actor ATSDetectorService {
    static let shared = ATSDetectorService()
    
    struct DetectionResult {
        let source: JobSource?
        let confidence: Confidence
        let apiEndpoint: String?
        let actualATSUrl: String?
        let message: String
        
        enum Confidence {
            case certain
            case likely
            case uncertain
            case notDetected
        }
    }
    
    func detectATS(from url: URL) async throws -> DetectionResult {
        print("[ATS Detector] Starting detection for: \(url.absoluteString)")
        
        if let quickMatch = JobSource.detectFromURL(url.absoluteString) {
            print("[ATS Detector] Quick match found: \(quickMatch.rawValue)")
            return DetectionResult(
                source: quickMatch,
                confidence: .certain,
                apiEndpoint: nil,
                actualATSUrl: url.absoluteString,
                message: "Detected \(quickMatch.rawValue) from URL pattern"
            )
        }
        
        print("[ATS Detector] No quick match, fetching page content...")
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            print("[ATS Detector] Failed to decode HTML")
            throw FetchError.invalidResponse
        }
        
        print("[ATS Detector] Fetched HTML, length: \(html.count) characters")
        
        let isCareersPage = isLikelyCareersPage(url: url, html: html)
        let indicators = analyzeATSIndicators(in: html)
        print("[ATS Detector] Found indicators: \(indicators)")
        print("[ATS Detector] Probing ATS APIs...")
        if let probeResult = await probeATSystems(indicators: indicators, originalURL: url, isCareersPage: isCareersPage) {
            print("[ATS Detector] Found via API probe: \(probeResult.source?.rawValue ?? "unknown")")
            return probeResult
        }
        
        print("[ATS Detector] Searching for embedded ATS URLs...")
        if let embeddedResult = await findEmbeddedATSUrls(in: html, originalURL: url) {
            print("[ATS Detector] Found via embedded URLs: \(embeddedResult.source?.rawValue ?? "unknown")")
            return embeddedResult
        }
        
        print("[ATS Detector] Searching in JSON/script data...")
        if let jsonResult = findATSUrlsInJSON(in: html, originalURL: url) {
            print("[ATS Detector] Found via JSON: \(jsonResult.source?.rawValue ?? "unknown")")
            return jsonResult
        }
        
        print("[ATS Detector] Searching for API patterns...")
        if let apiResult = findJobAPIPatterns(in: html, originalURL: url) {
            print("[ATS Detector] Found API pattern but couldn't determine ATS")
            return apiResult
        }
        
        print("[ATS Detector] No ATS detected")
        
        return DetectionResult(
            source: nil,
            confidence: .notDetected,
            apiEndpoint: nil,
            actualATSUrl: nil,
            message: "Could not detect ATS system from this page"
        )
    }
    
    // MARK: - Careers Page Detection
    
    private func isLikelyCareersPage(url: URL, html: String) -> Bool {
        let urlString = url.absoluteString.lowercased()
        let urlIndicators = ["career", "job", "hiring", "join", "positions"]
        let hasCareerUrl = urlIndicators.contains { urlString.contains($0) }
        let htmlLower = html.lowercased()
        let contentIndicators = [
            "open position", "job opening", "join our team", "we're hiring",
            "apply now", "view all jobs", "current opening"
        ]
        let hasCareerContent = contentIndicators.contains { htmlLower.contains($0) }
        
        return hasCareerUrl || hasCareerContent
    }
    
    // MARK: - ATS Indicator Analysis
    
    private struct ATSIndicators {
        var greenhouse: Int = 0
        var lever: Int = 0
        var ashby: Int = 0
        var workday: Int = 0
        var beamery: Int = 0
        
        var isEmpty: Bool {
            greenhouse == 0 && lever == 0 && ashby == 0 && workday == 0 && beamery == 0
        }
        
        var strongest: (source: String, count: Int)? {
            let all = [
                ("greenhouse", greenhouse),
                ("lever", lever),
                ("ashby", ashby),
                ("workday", workday),
                ("beamery", beamery)
            ]
            return all.max(by: { $0.1 < $1.1 })
        }
    }
    
    private func analyzeATSIndicators(in html: String) -> ATSIndicators {
        let htmlLower = html.lowercased()
        var indicators = ATSIndicators()
        let greenhouseKeywords = ["greenhouse.io", "boards.greenhouse", "grnhse", "gh-", "data-gh"]
        for keyword in greenhouseKeywords {
            if htmlLower.contains(keyword) {
                indicators.greenhouse += 1
            }
        }
        
        let leverKeywords = [
            "lever.co",              // ATS domain
            "jobs.lever",            // Job board
            "api.lever",             // API endpoint
            "data-lever",            // HTML attribute
            "lever-application",     // Common class name
            "lever ats",             // Explicit mention
            "levercareers"           // Combined word
        ]
        for keyword in leverKeywords {
            if htmlLower.contains(keyword) {
                indicators.lever += 1
            }
        }
        
        let ashbyKeywords = ["ashbyhq", "jobs.ashbyhq", "ashby.com"]
        for keyword in ashbyKeywords {
            if htmlLower.contains(keyword) {
                indicators.ashby += 1
            }
        }
        
        let workdayKeywords = ["myworkdayjobs", "wd1.", "wd5.", "workday.com/careers"]
        for keyword in workdayKeywords {
            if htmlLower.contains(keyword) {
                indicators.workday += 1
            }
        }
        
        // Beamery patterns (often integrated with Workday)
        let beameryKeywords = ["beamery", "pages.beamery.com", "flows.beamery.com", "beamery.referrers"]
        for keyword in beameryKeywords {
            if htmlLower.contains(keyword) {
                indicators.beamery += 1
                // If Beamery is detected, also increase Workday score as they're often used together
                indicators.workday += 1
            }
        }
        
        return indicators
    }
    
    // MARK: - ATS Probing
    
    private func probeATSystems(indicators: ATSIndicators, originalURL: URL, isCareersPage: Bool) async -> DetectionResult? {
        let companySlug = extractCompanySlug(from: originalURL)
        
        if !indicators.isEmpty {
            print("[Probe] Probing based on indicators...")
            
            let probes: [(count: Int, probe: () async -> DetectionResult?)] = [
                (indicators.greenhouse, { await self.probeGreenhouse(companySlug: companySlug) }),
                (indicators.lever, { await self.probeLever(companySlug: companySlug) }),
                (indicators.ashby, { await self.probeAshby(companySlug: companySlug) }),
                (indicators.beamery + indicators.workday, { await self.probeWorkdayVariations(companySlug: companySlug, originalURL: originalURL) })
            ]
            
            for (count, probe) in probes.sorted(by: { $0.count > $1.count }) where count > 0 {
                if let result = await probe() {
                    return result
                }
            }
        }
        
        if isCareersPage && indicators.isEmpty {
            print("[Probe] No indicators found, but looks like careers page. Trying fallback probes...")
            
            if let result = await probeGreenhouse(companySlug: companySlug) {
                return result
            }
            
            if let result = await probeLever(companySlug: companySlug) {
                return result
            }
            
            if let result = await probeAshby(companySlug: companySlug) {
                return result
            }
            
            if let result = await probeWorkdayVariations(companySlug: companySlug, originalURL: originalURL) {
                return result
            }
            
            print("[Probe] Fallback probes failed")
        }
        
        return nil
    }
    
    // MARK: - Greenhouse Probing
    
    private func probeGreenhouse(companySlug: String) async -> DetectionResult? {
        let apiUrl = "https://boards-api.greenhouse.io/v1/boards/\(companySlug)/jobs?content=true"
        
        print("[Greenhouse Probe] Testing: \(apiUrl)")
        
        guard let result = try? await fetchGreenhouseAPIDetails(apiUrl: apiUrl) else {
            print("[Greenhouse Probe] Failed")
            return nil
        }
        
        print("[Greenhouse Probe] Success!")
        return result
    }
    
    private func fetchGreenhouseAPIDetails(apiUrl: String) async throws -> DetectionResult {
        guard let url = URL(string: apiUrl) else {
            throw FetchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        
        let (data, httpResponse) = try await URLSession.shared.data(for: request)
        
        guard let response = httpResponse as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw FetchError.invalidResponse
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobs = json["jobs"] as? [[String: Any]],
              !jobs.isEmpty,
              let firstJob = jobs.first,
              let absoluteUrl = firstJob["absolute_url"] as? String else {
            throw FetchError.invalidResponse
        }
        
        let baseUrl = extractGreenhouseBaseUrl(from: absoluteUrl)
        
        return DetectionResult(
            source: .greenhouse,
            confidence: .certain,
            apiEndpoint: apiUrl,
            actualATSUrl: baseUrl,
            message: "Found Greenhouse via API: \(baseUrl)"
        )
    }
    
    private func extractGreenhouseBaseUrl(from jobUrl: String) -> String {
        if let url = URL(string: jobUrl) {
            var pathComponents = url.pathComponents.filter { $0 != "/" }
            
            if let lastComponent = pathComponents.last, Int(lastComponent) != nil {
                pathComponents.removeLast()
            }
            
            if pathComponents.last == "jobs" {
                pathComponents.removeLast()
            }
            
            let basePath = "/" + pathComponents.joined(separator: "/")
            return "\(url.scheme ?? "https")://\(url.host ?? "")\(basePath)"
        }
        return jobUrl
    }
    
    // MARK: - Lever Probing
    
    private func probeLever(companySlug: String) async -> DetectionResult? {
        let apiUrl = "https://api.lever.co/v0/postings/\(companySlug)?mode=json"
        
        print("[Lever Probe] Testing: \(apiUrl)")
        
        guard let result = try? await fetchLeverAPIDetails(apiUrl: apiUrl, companySlug: companySlug) else {
            print("[Lever Probe] Failed")
            return nil
        }
        
        print("[Lever Probe] Success!")
        return result
    }
    
    private func fetchLeverAPIDetails(apiUrl: String, companySlug: String) async throws -> DetectionResult {
        guard let url = URL(string: apiUrl) else {
            throw FetchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        
        let (data, httpResponse) = try await URLSession.shared.data(for: request)
        
        guard let response = httpResponse as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw FetchError.invalidResponse
        }
        
        guard let jobs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !jobs.isEmpty else {
            throw FetchError.invalidResponse
        }
        
        let baseUrl = "https://jobs.lever.co/\(companySlug)"
        
        return DetectionResult(
            source: .lever,
            confidence: .certain,
            apiEndpoint: apiUrl,
            actualATSUrl: baseUrl,
            message: "Found Lever via API: \(baseUrl)"
        )
    }
    
    // MARK: - Ashby Probing
    
    private func probeAshby(companySlug: String) async -> DetectionResult? {
        let baseUrl = "https://jobs.ashbyhq.com/\(companySlug)/"
        
        print("[Ashby Probe] Testing: \(baseUrl)")
        
        guard let result = try? await fetchAshbyJobBoard(baseUrl: baseUrl) else {
            print("[Ashby Probe] Failed")
            return nil
        }
        
        print("[Ashby Probe] Success!")
        return result
    }
    
    private func fetchAshbyJobBoard(baseUrl: String) async throws -> DetectionResult {
        guard let url = URL(string: baseUrl) else {
            throw FetchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        
        let (data, httpResponse) = try await URLSession.shared.data(for: request)
        
        guard let response = httpResponse as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let html = String(data: data, encoding: .utf8),
              html.contains("ashbyhq") || html.contains("Ashby") else {
            throw FetchError.invalidResponse
        }
        
        return DetectionResult(
            source: .ashby,
            confidence: .certain,
            apiEndpoint: nil,
            actualATSUrl: baseUrl,
            message: "Found Ashby job board: \(baseUrl)"
        )
    }
    
    // MARK: - Workday Probing
    
    private func probeWorkdayVariations(companySlug: String, originalURL: URL) async -> DetectionResult? {
        // Try common Workday patterns
        let workdayPatterns = [
            "https://\(companySlug).wd1.myworkdayjobs.com/careers",
            "https://\(companySlug).wd3.myworkdayjobs.com/careers",
            "https://\(companySlug).wd5.myworkdayjobs.com/careers",
            "https://\(companySlug).wd1.myworkdayjobs.com/en-US/careers",
            "https://\(companySlug).wd3.myworkdayjobs.com/en-US/careers",
            "https://\(companySlug).wd5.myworkdayjobs.com/en-US/careers"
        ]
        
        for pattern in workdayPatterns {
            print("[Workday Probe] Testing: \(pattern)")
            if let result = try? await testWorkdayURL(pattern) {
                print("[Workday Probe] Success!")
                return result
            }
        }
        
        print("[Workday Probe] All patterns failed")
        
        if let host = originalURL.host, (host.contains("search-careers") || host.contains("careers")) {
            return DetectionResult(
                source: .workday,
                confidence: .likely,
                apiEndpoint: nil,
                actualATSUrl: originalURL.absoluteString,
                message: "Likely Workday/Beamery site (custom URL structure). Original URL will be used. If jobs don't load, try finding the actual myworkdayjobs.com URL in the page source."
            )
        }
        
        return nil
    }
    
    private func testWorkdayURL(_ urlString: String) async throws -> DetectionResult {
        guard let url = URL(string: urlString) else {
            throw FetchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5
        
        let (data, httpResponse) = try await URLSession.shared.data(for: request)
        
        guard let response = httpResponse as? HTTPURLResponse,
              (200...299).contains(response.statusCode) || response.statusCode == 301 || response.statusCode == 302,
              let html = String(data: data, encoding: .utf8),
              (html.contains("myworkdayjobs") || html.contains("workday")) else {
            throw FetchError.invalidResponse
        }
        
        return DetectionResult(
            source: .workday,
            confidence: .certain,
            apiEndpoint: nil,
            actualATSUrl: urlString,
            message: "Found Workday job board: \(urlString)"
        )
    }
    
    // MARK: - Helper Methods
    
    private func extractCompanySlug(from url: URL) -> String {
        if let host = url.host {
            let parts = host.components(separatedBy: ".")
            if parts.count >= 2 {
                let domain = parts[parts.count - 2]
                return domain.lowercased()
            }
        }
        return "company"
    }
    
    private func normalizeAshbyUrl(_ url: String) -> String {
        guard let urlObj = URL(string: url) else { return url }
        
        let pathComponents = urlObj.pathComponents.filter { $0 != "/" }
        
        if pathComponents.count > 1 {
            let lastComponent = pathComponents.last ?? ""
            
            let uuidPattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
            if let regex = try? NSRegularExpression(pattern: uuidPattern, options: .caseInsensitive),
               regex.firstMatch(in: lastComponent, range: NSRange(lastComponent.startIndex..., in: lastComponent)) != nil {
                
                let baseComponents = pathComponents.dropLast()
                let basePath = "/" + baseComponents.joined(separator: "/") + "/"
                return "\(urlObj.scheme ?? "https")://\(urlObj.host ?? "")\(basePath)"
            }
        }
        
        return url
    }
    
    // MARK: - Embedded URLs Detection
    
    private func findEmbeddedATSUrls(in html: String, originalURL: URL) async -> DetectionResult? {
        print("[Embedded Search] Searching for embedded ATS URLs...")
        
        let atsUrlPatterns: [(pattern: String, source: JobSource)] = [
            (#"https?://[^"'\s]*\.wd[0-9]+\.myworkdayjobs\.com/[^"'\s]*"#, .workday),
            (#"https?://[^"'\s]*\.myworkdayjobs\.com/[^"'\s]*"#, .workday),
            (#"https?://[^"'\s]*\.greenhouse\.io/[^"'\s]*"#, .greenhouse),
            (#"https?://boards-api\.greenhouse\.io/[^"'\s]*"#, .greenhouse),
            (#"https?://job-boards\.greenhouse\.io/[^"'\s]*"#, .greenhouse),
            (#"https?://jobs\.lever\.co/[^"'\s]*"#, .lever),
            (#"https?://[^"'\s]*\.lever\.co[^"'\s]*"#, .lever),
            (#"https?://jobs\.ashbyhq\.com/[^"'\s]*"#, .ashby),
            (#"https?://[^"'\s]*\.workable\.com/[^"'\s]*"#, .workable),
            (#"https?://[^"'\s]*\.smartrecruiters\.com/[^"'\s]*"#, .smartrecruiters),
            (#"https?://[^"'\s]*\.jobvite\.com/[^"'\s]*"#, .jobvite),
        ]
        
        for (_, (pattern, source)) in atsUrlPatterns.enumerated() {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range, in: html) {
                
                var foundUrl = String(html[range])
                foundUrl = foundUrl.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                
                print("[Embedded Search] Found \(source.rawValue) URL: \(foundUrl)")
                
                if source == .workday {
                    if let workdayConfig = parseWorkdayUrl(foundUrl) {
                        let normalizedUrl = normalizeWorkdayUrl(foundUrl)
                        return DetectionResult(
                            source: .workday,
                            confidence: .certain,
                            apiEndpoint: nil,
                            actualATSUrl: normalizedUrl,
                            message: "Found Workday ATS: \(workdayConfig.company).\(workdayConfig.instance).myworkdayjobs.com/\(workdayConfig.siteName)"
                        )
                    }
                }
                
                var normalizedUrl = foundUrl
                if source == .ashby {
                    normalizedUrl = normalizeAshbyUrl(foundUrl)
                } else if source == .workday {
                    normalizedUrl = normalizeWorkdayUrl(foundUrl)
                }
                
                return DetectionResult(
                    source: source,
                    confidence: .certain,
                    apiEndpoint: nil,
                    actualATSUrl: normalizedUrl,
                    message: "Found \(source.rawValue) ATS embedded in page: \(normalizedUrl)"
                )
            }
        }
        
        if let redirectUrl = findMetaRedirect(in: html) {
            if let source = JobSource.detectFromURL(redirectUrl) {
                return DetectionResult(
                    source: source,
                    confidence: .likely,
                    apiEndpoint: nil,
                    actualATSUrl: redirectUrl,
                    message: "Found redirect to \(source.rawValue): \(redirectUrl)"
                )
            }
        }
        
        if let jsRedirect = findJavaScriptRedirect(in: html) {
            if let source = JobSource.detectFromURL(jsRedirect) {
                return DetectionResult(
                    source: source,
                    confidence: .likely,
                    apiEndpoint: nil,
                    actualATSUrl: jsRedirect,
                    message: "Found JS redirect to \(source.rawValue)"
                )
            }
        }
        
        return nil
    }
    
    private func normalizeWorkdayUrl(_ url: String) -> String {
        guard let urlObj = URL(string: url),
              let host = urlObj.host else { return url }
        
        let path = urlObj.path
        let stripPatterns = ["/job/", "/details/", "/apply"]
        var basePath = path
        
        for pattern in stripPatterns {
            if let range = path.range(of: pattern) {
                basePath = String(path[..<range.lowerBound])
                break
            }
        }
        
        if !basePath.hasSuffix("/") {
            basePath += "/"
        }
        
        return "\(urlObj.scheme ?? "https")://\(host)\(basePath)"
    }
    
    private func parseWorkdayUrl(_ url: String) -> (company: String, instance: String, siteName: String)? {
        guard let urlComponents = URL(string: url),
              let host = urlComponents.host else { return nil }
        
        let hostParts = host.components(separatedBy: ".")
        guard hostParts.count >= 3,
              hostParts[1].hasPrefix("wd"),
              hostParts[2] == "myworkdayjobs" else { return nil }
        
        let company = hostParts[0]
        let instance = hostParts[1]
        
        let normalizedUrl = normalizeWorkdayUrl(url)
        guard let normalizedComponents = URL(string: normalizedUrl) else {
            return (company: company, instance: instance, siteName: "careers")
        }
        
        var siteName = normalizedComponents.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        if siteName.isEmpty {
            siteName = "careers"
        }
        
        return (company: company, instance: instance, siteName: siteName)
    }
    
    private func findMetaRedirect(in html: String) -> String? {
        let pattern = #"<meta[^>]*http-equiv=[\"']refresh[\"'][^>]*content=[\"'][^\"']*url=([^\"'\s]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }
        return nil
    }
    
    private func findJavaScriptRedirect(in html: String) -> String? {
        let patterns = [
            #"window\.location\.href\s*=\s*[\"']([^\"']+)[\"']"#,
            #"window\.location\.replace\([\"']([^\"']+)[\"']\)"#,
            #"location\.href\s*=\s*[\"']([^\"']+)[\"']"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: html) {
                return String(html[range])
            }
        }
        return nil
    }
    
    private func findATSUrlsInJSON(in html: String, originalURL: URL) -> DetectionResult? {
        let jsonPatterns = [
            #"["\']?(https?://(?:boards?-?api)?\.greenhouse\.io/[^"'\s]+)["\']?"#,
            #"["\']?(https?://jobs\.lever\.co/[^"'\s]+)["\']?"#,
            #"["\']?(https?://jobs\.ashbyhq\.com/[^"'\s]+)["\']?"#,
            #"["\']?(https?://[^"'\s]*\.myworkdayjobs\.com/[^"'\s]+)["\']?"#,
        ]
        
        for (_, pattern) in jsonPatterns.enumerated() {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: html) {
                
                let foundUrl = String(html[range])
                
                if let source = JobSource.detectFromURL(foundUrl) {
                    var normalizedUrl = foundUrl
                    if source == .ashby {
                        normalizedUrl = normalizeAshbyUrl(foundUrl)
                    } else if source == .workday {
                        normalizedUrl = normalizeWorkdayUrl(foundUrl)
                    }
                    
                    return DetectionResult(
                        source: source,
                        confidence: .certain,
                        apiEndpoint: nil,
                        actualATSUrl: normalizedUrl,
                        message: "Found \(source.rawValue) ATS URL in page data: \(normalizedUrl)"
                    )
                }
            }
        }
        
        return nil
    }
    
    private func findJobAPIPatterns(in html: String, originalURL: URL) -> DetectionResult? {
        let dynamicLoadingIndicators = [
            "graphql", "apollo", "__APOLLO", "careersPageQuery", "jobsQuery",
            "window.__INITIAL_STATE__", "window.__data", "react-root", "ng-app", "vue-app"
        ]
        
        var foundIndicators: [String] = []
        for indicator in dynamicLoadingIndicators {
            if html.localizedCaseInsensitiveContains(indicator) {
                foundIndicators.append(indicator)
            }
        }
        
        if foundIndicators.count >= 2 {
            var suggestionMessage = "This page loads jobs dynamically via JavaScript. "
            
            if html.contains("greenhouse") || html.contains("gh-") {
                suggestionMessage += "It appears to use Greenhouse. Try: https://boards.greenhouse.io/\(extractCompanySlug(from: originalURL))"
            } else if html.contains("lever") {
                suggestionMessage += "It appears to use Lever. Try: https://jobs.lever.co/\(extractCompanySlug(from: originalURL))"
            } else if html.contains("ashby") {
                suggestionMessage += "It appears to use Ashby. Try: https://jobs.ashbyhq.com/\(extractCompanySlug(from: originalURL))"
            } else {
                suggestionMessage += "Try finding a direct link to a specific job posting from this page."
            }
            
            return DetectionResult(
                source: nil,
                confidence: .uncertain,
                apiEndpoint: nil,
                actualATSUrl: nil,
                message: suggestionMessage
            )
        }
        
        return nil
    }
}

extension ATSDetectorService {
    
    // Add this method to enhance detection with JavaScript rendering
    func detectATSEnhanced(from url: URL) async throws -> DetectionResult {
        print("[ATS Detector] Starting enhanced detection for: \(url.absoluteString)")
        
        // Step 1: Try your existing quick detection first
        if let quickMatch = JobSource.detectFromURL(url.absoluteString) {
            print("[ATS Detector] Quick match found: \(quickMatch.rawValue)")
            return DetectionResult(
                source: quickMatch,
                confidence: .certain,
                apiEndpoint: nil,
                actualATSUrl: url.absoluteString,
                message: "Detected \(quickMatch.rawValue) from URL pattern"
            )
        }
        
        // Step 2: Try JavaScript rendering for dynamic content (NEW)
        if let jsResult = await detectWithJavaScriptRendering(url: url) {
            print("[ATS Detector] Found via JS rendering: \(jsResult.source?.rawValue ?? "unknown")")
            return jsResult
        }
        
        // Step 3: Fall back to your existing detection methods
        return try await detectATS(from: url)
    }
    
    // MARK: - JavaScript Rendering Detection (NEW)
    @MainActor
    private func detectWithJavaScriptRendering(url: URL) async -> DetectionResult? {
        return await withCheckedContinuation { continuation in
            print("[ATS Detector] Starting JavaScript rendering detection")
            var hasResumed = false

            let webView = WKWebView()
            let navigationDelegate = ATSNavigationDelegate { detectedURL in
                if let source = JobSource.detectFromURL(detectedURL) {
                    let result = DetectionResult(
                        source: source,
                        confidence: .certain,
                        apiEndpoint: nil,
                        actualATSUrl: detectedURL,
                        message: "Detected \(source.rawValue) via JavaScript rendering"
                    )
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(returning: result)
                    }
                }
            }

            webView.navigationDelegate = navigationDelegate
            
            // Enhanced JavaScript to detect ATS systems hidden in JS (including external scripts like GTM)
            let jsDetectionCode = """
            (async function() {
                const results = {
                    workday: [],
                    greenhouse: [],
                    lever: [],
                    ashby: [],
                    beamery: [],
                    found: false,
                    workdayConfig: null,
                    gtmScanned: false
                };

                // Helper function to scan content for ATS URLs
                function scanContentForATS(content) {
                    // Helper to find URLs with both normal and escaped formats (GTM uses \\/ escaping)
                    function findATSUrls(pattern, escapedPattern) {
                        let matches = content.match(pattern) || [];
                        let escaped = content.match(escapedPattern) || [];
                        // Unescape the escaped URLs
                        escaped = escaped.map(url => url.replace(/\\\\/g, ''));
                        return [...matches, ...escaped];
                    }

                    // Workday patterns
                    const workdayMatches = findATSUrls(
                        /https?:\\/\\/[^"'\\s]*\\.myworkdayjobs\\.com[^"'\\s,\\]\\}]*/g,
                        /https?:\\\\?\\/\\\\?\\/[^"'\\s]*\\.myworkdayjobs\\.com[^"'\\s,\\]\\}]*/g
                    );
                    if (workdayMatches.length > 0) {
                        results.workday = results.workday.concat(workdayMatches);
                        results.found = true;
                    }

                    // Greenhouse patterns (boards.greenhouse.io, api.greenhouse.io)
                    const greenhouseMatches = findATSUrls(
                        /https?:\\/\\/[^"'\\s]*greenhouse\\.io[^"'\\s,\\]\\}]*/g,
                        /https?:\\\\?\\/\\\\?\\/[^"'\\s]*greenhouse\\.io[^"'\\s,\\]\\}]*/g
                    );
                    if (greenhouseMatches.length > 0) {
                        results.greenhouse = results.greenhouse.concat(greenhouseMatches);
                        results.found = true;
                    }

                    // Lever patterns (jobs.lever.co)
                    const leverMatches = findATSUrls(
                        /https?:\\/\\/[^"'\\s]*lever\\.co[^"'\\s,\\]\\}]*/g,
                        /https?:\\\\?\\/\\\\?\\/[^"'\\s]*lever\\.co[^"'\\s,\\]\\}]*/g
                    );
                    if (leverMatches.length > 0) {
                        results.lever = results.lever.concat(leverMatches);
                        results.found = true;
                    }

                    // Ashby patterns (jobs.ashbyhq.com)
                    const ashbyMatches = findATSUrls(
                        /https?:\\/\\/[^"'\\s]*ashbyhq\\.com[^"'\\s,\\]\\}]*/g,
                        /https?:\\\\?\\/\\\\?\\/[^"'\\s]*ashbyhq\\.com[^"'\\s,\\]\\}]*/g
                    );
                    if (ashbyMatches.length > 0) {
                        results.ashby = results.ashby.concat(ashbyMatches);
                        results.found = true;
                    }

                    // Beamery patterns (often used with Workday)
                    const beameryPatterns = ['beamery', 'pages.beamery.com', 'flows.beamery.com'];
                    for (const pattern of beameryPatterns) {
                        if (content.includes(pattern)) {
                            results.beamery.push(pattern);
                            results.found = true;
                        }
                    }
                }

                // Fetch and scan GTM/external scripts
                const externalScripts = document.querySelectorAll('script[src*="googletagmanager.com"], script[src*="gtm.js"]');
                for (const script of externalScripts) {
                    try {
                        const response = await fetch(script.src);
                        const content = await response.text();
                        scanContentForATS(content);
                        results.gtmScanned = true;
                    } catch (e) {
                        console.log('[ATS] Failed to fetch GTM script:', e);
                    }
                }

                // Check all inline scripts for ATS URLs
                const scripts = document.querySelectorAll('script');
                scripts.forEach(script => {
                    const content = script.textContent || script.innerHTML || '';
                    scanContentForATS(content);

                    // Try to extract Workday config from URLs found
                    const beameryConfigMatch = content.match(/([\\w-]+)\\.wd([0-9]+)\\.myworkdayjobs\\.com\\/([\\w-]+)/);
                    if (beameryConfigMatch) {
                        results.workdayConfig = {
                            company: beameryConfigMatch[1],
                            instance: 'wd' + beameryConfigMatch[2],
                            siteName: beameryConfigMatch[3]
                        };
                    }
                });
                
                // Check iframes
                const iframes = document.querySelectorAll('iframe');
                iframes.forEach(iframe => {
                    const src = iframe.src || '';
                    scanContentForATS(src);
                });

                // Deduplicate results
                results.workday = [...new Set(results.workday)];
                results.greenhouse = [...new Set(results.greenhouse)];
                results.lever = [...new Set(results.lever)];
                results.ashby = [...new Set(results.ashby)];
                results.beamery = [...new Set(results.beamery)];

                // Also extract Workday config from results if not already found
                if (!results.workdayConfig && results.workday.length > 0) {
                    for (const url of results.workday) {
                        const match = url.match(/([\\w-]+)\\.wd([0-9]+)\\.myworkdayjobs\\.com\\/([\\w-]+)/);
                        if (match) {
                            results.workdayConfig = {
                                company: match[1],
                                instance: 'wd' + match[2],
                                siteName: match[3]
                            };
                            break;
                        }
                    }
                }

                return JSON.stringify(results);
            })();
            """
            
            webView.load(URLRequest(url: url))

            // Add timeout to prevent hanging
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if !hasResumed {
                    print("[ATS Detector] JavaScript rendering timed out after 10s")
                    hasResumed = true
                    continuation.resume(returning: nil)
                }
            }

            // Wait for page to load and execute detection
            // Increase wait time to 5s to allow GTM scripts to load
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                // Wrap the async IIFE call to handle the Promise
                let wrappedCode = """
                (async () => {
                    return await \(jsDetectionCode)
                })()
                """
                webView.callAsyncJavaScript(wrappedCode, arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case .success(let value):
                        guard let jsonString = value as? String,
                              let data = jsonString.data(using: .utf8),
                              let detection = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            print("[ATS Detector] Failed to parse JavaScript results")
                            if !hasResumed {
                                hasResumed = true
                                continuation.resume(returning: nil)
                            }
                            return
                        }

                        // Process results
                        var detectedSource: JobSource?
                        var detectedURL: String?

                        // Check for Workday config first (most reliable)
                        if let config = detection["workdayConfig"] as? [String: Any],
                           let company = config["company"] as? String,
                           let instance = config["instance"] as? String,
                           let siteName = config["siteName"] as? String {
                            detectedSource = .workday
                            detectedURL = "https://\(company).\(instance).myworkdayjobs.com/\(siteName)"
                            print("🟢 [ATS] Extracted Workday config: \(detectedURL ?? "none")")
                        } else if let workdayURLs = detection["workday"] as? [String], !workdayURLs.isEmpty {
                            detectedSource = .workday
                            if let firstURL = workdayURLs.first(where: { $0.contains("myworkdayjobs.com") && !$0.contains("via-beamery") && !$0.contains("workday-impl") }) {
                                detectedURL = firstURL
                            } else {
                                detectedURL = workdayURLs.first
                            }
                        } else if let beameryURLs = detection["beamery"] as? [String], !beameryURLs.isEmpty {
                            detectedSource = .workday
                            detectedURL = "Beamery-powered Workday site detected"
                        } else if let greenhouseURLs = detection["greenhouse"] as? [String], !greenhouseURLs.isEmpty {
                            detectedSource = .greenhouse
                            detectedURL = greenhouseURLs.first
                        } else if let leverURLs = detection["lever"] as? [String], !leverURLs.isEmpty {
                            detectedSource = .lever
                            detectedURL = leverURLs.first
                        } else if let ashbyURLs = detection["ashby"] as? [String], !ashbyURLs.isEmpty {
                            detectedSource = .ashby
                            detectedURL = ashbyURLs.first
                        }

                        let gtmScanned = (detection["gtmScanned"] as? Bool) ?? false
                        print("[ATS Detector] GTM scanned: \(gtmScanned)")

                        if let source = detectedSource {
                            let result = DetectionResult(
                                source: source,
                                confidence: .certain,
                                apiEndpoint: nil,
                                actualATSUrl: detectedURL ?? url.absoluteString,
                                message: "Detected \(source.rawValue) via JavaScript analysis\(gtmScanned ? " (including GTM)" : "")"
                            )
                            print("[ATS Detector] Successfully detected \(source.rawValue) via JS")
                            if !hasResumed {
                                hasResumed = true
                                continuation.resume(returning: result)
                            }
                        } else {
                            print("[ATS Detector] No ATS detected via JavaScript")
                            if !hasResumed {
                                hasResumed = true
                                continuation.resume(returning: nil)
                            }
                        }

                    case .failure(let error):
                        print("[ATS Detector] JavaScript evaluation error: \(error.localizedDescription)")
                        if !hasResumed {
                            hasResumed = true
                            continuation.resume(returning: nil)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Navigation Delegate Helper
class ATSNavigationDelegate: NSObject, WKNavigationDelegate {
    let onRedirect: (String) -> Void
    
    init(onRedirect: @escaping (String) -> Void) {
        self.onRedirect = onRedirect
        super.init()
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            onRedirect(url.absoluteString)
        }
        decisionHandler(.allow)
    }
}

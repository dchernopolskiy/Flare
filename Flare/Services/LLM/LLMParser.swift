//
//  LLMParser.swift
//  Flare
//
//  Created by Dan on 12/9/25.
//

import Foundation
import SwiftLlama

actor LLMParser {
    private var llama: SwiftLlama?
    private var isLoaded = false

    static let shared = LLMParser()

    private init() {}

    func loadModel() async throws {
        guard !isLoaded else { return }

        print("[LLM] Loading Llama 3.2 3B model...")
        let startTime = Date()

        var modelPath: String?
        if let bundlePath = Bundle.main.path(forResource: "llama32-3b-instruct-q4_k_m", ofType: "gguf") {
            modelPath = bundlePath
            print("[LLM] Using bundled model")
        } else {
            let downloadedPath = await ModelDownloader.shared.getModelPath()
            if FileManager.default.fileExists(atPath: downloadedPath.path) {
                modelPath = downloadedPath.path
                print("[LLM] Using downloaded model")
            } else {
                print("[LLM] Model not found. Please enable AI parsing in Settings to download.")
                throw LLMError.modelNotFound
            }
        }

        guard let finalPath = modelPath else {
            throw LLMError.modelNotFound
        }

        print("[LLM] Model path: \(finalPath)")

        do {
            let config = Configuration(
                nCTX: 4096,            // Context length for larger API responses
                temperature: 0.1,      // Low temperature for consistent JSON output
                batchSize: 512,        // Batch size (limits input to ~1500 chars)
                maxTokenCount: 1024    // Max tokens to generate
            )
            llama = try SwiftLlama(modelPath: finalPath, modelConfiguration: config)
            isLoaded = true

            let loadTime = Date().timeIntervalSince(startTime)
            print("[LLM] Model loaded in \(String(format: "%.2f", loadTime))s")
        } catch {
            print("[LLM] Failed to load model: \(error)")
            throw LLMError.failedToLoadModel(error)
        }
    }

    func discoverJSONSchema(from json: String) async throws -> JobResponseStructure? {
        if !isLoaded {
            try await loadModel()
        }

        guard let llama = llama else {
            throw LLMError.modelNotLoaded
        }

        print("[LLM] Analyzing JSON structure to discover schema...")

        let truncatedJSON = smartTruncateJSON(json, maxChars: 3500)
        let promptText = """
        Find where job listings are in this JSON.

        Return this exact JSON format:
        {"jobsArrayPath":"path.to.array","titleField":"title","locationField":"location","urlField":"url","paginationParam":null,"pageSizeParam":null}

        Field rules:
        - jobsArrayPath: Dot-separated path to the jobs array (e.g., "data.jobs" or just "jobs")
        - titleField: Field name containing job title (usually "title", "text", "name")
        - locationField: Field with location (or "location" if nested object)
        - urlField: Field with job URL (check "url", "link", "href", "applyUrl")
        - paginationParam: "offset", "page", "cursor", or null
        - pageSizeParam: "limit", "size", "pageSize", or null

        JSON:
        \(truncatedJSON)

        Schema:
        """

        let prompt = Prompt(
            type: .llama3,
            systemPrompt: "You analyze JSON APIs and return extraction schemas. No explanations.",
            userMessage: promptText
        )

        let response = try await llama.start(for: prompt)
        print("[LLM] Schema discovery response: \(response.prefix(200))...")

        // Try to extract JSON object with improved parsing
        guard let jsonString = extractJSONObject(from: response) else {
            print("[LLM] No JSON object found in schema response")
            return nil
        }

        guard let data = jsonString.data(using: .utf8) else {
            return nil
        }

        do {
            let schema = try JSONDecoder().decode(JobResponseStructure.self, from: data)
            print("[LLM] Discovered schema: jobs at '\(schema.jobsArrayPath)', title field: '\(schema.titleField)'")
            return schema
        } catch {
            print("[LLM] Failed to decode schema: \(error)")
            print("[LLM] Attempted to parse: \(jsonString.prefix(300))...")
            return nil
        }
    }

    // MARK: - LLM-based ATS and API Detection

    /// Result of LLM pattern detection
    struct PatternDetectionResult {
        let atsURL: String?           // Detected ATS URL (Workday, Greenhouse, etc.)
        let atsType: String?          // Type of ATS detected
        let apiEndpoint: String?      // Detected API endpoint
        let apiType: String?          // Type of API (graphql, rest, etc.)
        let confidence: String        // high, medium, low
    }

    /// Use LLM to detect ATS URLs and API endpoints in HTML/JS content
    /// This catches patterns that regex might miss (e.g., obfuscated URLs, context-based detection)
    func detectPatternsInContent(_ content: String, sourceURL: URL) async throws -> PatternDetectionResult? {
        if !isLoaded {
            try await loadModel()
        }

        guard let llama = llama else {
            throw LLMError.modelNotLoaded
        }

        print("[LLM] Detecting ATS/API patterns in content...")
        let startTime = Date()

        // Strip irrelevant HTML elements first
        let strippedContent = HTMLCleaner.stripForLLM(content)
        print("[LLM] Stripped content from \(content.count) to \(strippedContent.count) chars for pattern detection")

        // Truncate content intelligently
        let truncatedContent = smartTruncateHTML(strippedContent, maxChars: 3500)

        let promptText = """
        Find job board URLs or API endpoints in this content.

        Look for these ATS patterns:
        - Workday: *.myworkdayjobs.com
        - Greenhouse: boards.greenhouse.io or api.greenhouse.io
        - Lever: jobs.lever.co
        - Ashby: jobs.ashbyhq.com

        And API endpoints like /api/jobs, /careers/api, or /graphql

        Return this exact JSON format:
        {"atsURL":null,"atsType":null,"apiEndpoint":null,"apiType":null,"confidence":"low"}

        Field values:
        - atsURL: Full ATS URL found, or null
        - atsType: "workday", "greenhouse", "lever", "ashby", or null
        - apiEndpoint: Full API URL found, or null
        - apiType: "graphql" or "rest", or null
        - confidence: "high", "medium", or "low"

        Content from \(sourceURL.host ?? "unknown"):
        \(truncatedContent)

        JSON:
        """

        let prompt = Prompt(
            type: .llama3,
            systemPrompt: "You find job board URLs and APIs in HTML. Return JSON only.",
            userMessage: promptText
        )

        let response = try await llama.start(for: prompt)
        let inferenceTime = Date().timeIntervalSince(startTime)
        print("[LLM] Pattern detection completed in \(String(format: "%.2f", inferenceTime))s")
        print("[LLM] Pattern detection response: \(response.prefix(300))...")

        // Parse response with improved JSON extraction
        guard let jsonString = extractJSONObject(from: response) else {
            print("[LLM] No JSON object found in pattern detection response")
            return nil
        }

        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[LLM] Failed to parse pattern detection JSON: \(jsonString.prefix(200))...")
            return nil
        }

        let result = PatternDetectionResult(
            atsURL: parsed["atsURL"] as? String,
            atsType: parsed["atsType"] as? String,
            apiEndpoint: parsed["apiEndpoint"] as? String,
            apiType: parsed["apiType"] as? String,
            confidence: (parsed["confidence"] as? String) ?? "low"
        )

        // Log findings
        if let atsURL = result.atsURL {
            print("[LLM] Detected ATS URL: \(atsURL) (type: \(result.atsType ?? "unknown"), confidence: \(result.confidence))")
        }
        if let apiEndpoint = result.apiEndpoint {
            print("[LLM] Detected API endpoint: \(apiEndpoint) (type: \(result.apiType ?? "unknown"), confidence: \(result.confidence))")
        }

        // Only return if we found something meaningful
        if result.atsURL != nil || result.apiEndpoint != nil {
            return result
        }

        return nil
    }

    func extractJobs(from html: String, url: URL) async throws -> [ParsedJob] {
        if !isLoaded {
            try await loadModel()
        }

        guard let llama = llama else {
            throw LLMError.modelNotLoaded
        }

        print("[LLM] Extracting jobs from HTML")
        let startTime = Date()

        // Strip irrelevant HTML elements first (nav, header, footer, scripts, etc.)
        let strippedHTML = HTMLCleaner.stripForLLM(html)
        print("[LLM] Stripped HTML from \(html.count) to \(strippedHTML.count) chars")

        // Truncate HTML intelligently - look for job-related content
        let truncatedHTML = smartTruncateHTML(strippedHTML, maxChars: 3500)

        let promptText = """
        Extract job listings from this HTML.

        Return ONLY a JSON array with this structure:
        [{"title":"Job Title","location":"City, State","url":"/jobs/123"}]

        Rules:
        - title: Required. The job title text.
        - location: City/state if shown, or "Remote" if remote job.
        - url: The href from the job link. Keep relative URLs as-is.

        If no jobs found, return: []

        HTML:
        \(truncatedHTML)

        JSON:
        """

        let prompt = Prompt(
            type: .llama3,
            systemPrompt: "You extract job listings from HTML and return JSON. No explanations.",
            userMessage: promptText
        )

        do {
            let response = try await llama.start(for: prompt)
            print("[LLM] Raw response: \(response.prefix(200))...")

            let jobs = parseJobsFromResponse(response)

            let inferenceTime = Date().timeIntervalSince(startTime)
            print("[LLM] Extracted \(jobs.count) jobs in \(String(format: "%.2f", inferenceTime))s")

            return jobs
        } catch {
            print("[LLM] Inference error: \(error)")
            throw LLMError.inferenceFailed(error)
        }
    }

    private func parseJobsFromResponse(_ response: String) -> [ParsedJob] {
        guard let jsonStart = response.firstIndex(of: "["),
              let jsonEnd = response.lastIndex(of: "]") else {
            print("[LLM] No JSON array found in response")
            return []
        }

        let jsonString = String(response[jsonStart...jsonEnd])

        guard let data = jsonString.data(using: .utf8) else {
            print("[LLM] Failed to convert to data")
            return []
        }

        do {
            let decoder = JSONDecoder()
            let jobs = try decoder.decode([ParsedJob].self, from: data)
            print("[LLM] Successfully parsed \(jobs.count) jobs from JSON")
            return jobs
        } catch {
            print("[LLM] JSON parsing error: \(error)")
            print("[LLM] Attempted to parse: \(jsonString.prefix(200))...")
            return []
        }
    }

    func unloadModel() {
        guard isLoaded else { return }

        print("[LLM] Unloading model")
        llama = nil
        isLoaded = false
    }

    // MARK: - JSON Extraction

    /// Extract a valid JSON object from LLM response, handling common issues like
    /// markdown code blocks, extra text, and incomplete JSON
    private func extractJSONObject(from response: String) -> String? {
        var text = response

        // Remove markdown code blocks if present
        if let codeBlockStart = text.range(of: "```json") {
            text = String(text[codeBlockStart.upperBound...])
            if let codeBlockEnd = text.range(of: "```") {
                text = String(text[..<codeBlockEnd.lowerBound])
            }
        } else if let codeBlockStart = text.range(of: "```") {
            text = String(text[codeBlockStart.upperBound...])
            if let codeBlockEnd = text.range(of: "```") {
                text = String(text[..<codeBlockEnd.lowerBound])
            }
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find the first { and try to find matching }
        guard let firstBrace = text.firstIndex(of: "{") else {
            return nil
        }

        // Track brace depth to find matching closing brace
        var depth = 0
        var inString = false
        var escapeNext = false
        var endIndex: String.Index?

        for i in text.indices[firstBrace...] {
            let char = text[i]

            if escapeNext {
                escapeNext = false
                continue
            }

            if char == "\\" && inString {
                escapeNext = true
                continue
            }

            if char == "\"" {
                inString = !inString
                continue
            }

            if !inString {
                if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = text.index(after: i)
                        break
                    }
                }
            }
        }

        guard let end = endIndex else {
            // If we didn't find a matching brace, try the simple approach as fallback
            if let lastBrace = text.lastIndex(of: "}") {
                let jsonString = String(text[firstBrace...lastBrace])
                // Verify it's valid JSON
                if let data = jsonString.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: data)) != nil {
                    return jsonString
                }
            }
            return nil
        }

        return String(text[firstBrace..<end])
    }

    // MARK: - Truncation

    private func smartTruncateJSON(_ json: String, maxChars: Int) -> String {
        guard json.count > maxChars else { return json }

        let arrayPatterns = [
            "\"jobs\":",
            "\"results\":",
            "\"data\":",
            "\"items\":",
            "\"jobCards\":",
            "\"positions\":",
            "\"postings\":",
            "\"openings\":",
            "\"listings\":",
            "\"roles\":",
            "\"requisitions\":",
            "\"opportunities\":",
            "\"hits\":",
            "\"records\":",
            "\"content\":",
            "\"entries\":"
        ]

        var bestTruncation = String(json.prefix(maxChars))

        for pattern in arrayPatterns {
            if let arrayStart = json.range(of: pattern) {
                let startIndex = arrayStart.lowerBound
                let endIndex = json.index(startIndex, offsetBy: min(maxChars, json.distance(from: startIndex, to: json.endIndex)))

                let truncated = String(json[..<endIndex])

                // Find the array opening bracket after the pattern
                guard let arrayBracket = truncated.range(of: "[", options: [], range: arrayStart.upperBound..<truncated.endIndex) else {
                    continue
                }

                // Find the first complete object in the array
                if let firstObjStart = truncated.range(of: "{", options: [], range: arrayBracket.upperBound..<truncated.endIndex) {
                    var braceCount = 1
                    var searchIndex = firstObjStart.upperBound

                    while braceCount > 0 && searchIndex < truncated.endIndex {
                        let char = truncated[searchIndex]
                        if char == "{" { braceCount += 1 }
                        else if char == "}" { braceCount -= 1 }
                        searchIndex = truncated.index(after: searchIndex)

                        if braceCount == 0 {
                            // We found a complete object, now properly close the JSON
                            // Count how many brackets we need to close from the start
                            let prefix = String(json[..<arrayStart.lowerBound])
                            let openBraces = prefix.filter { $0 == "{" }.count - prefix.filter { $0 == "}" }.count

                            var result = String(truncated[..<searchIndex]) + "]"
                            for _ in 0..<openBraces {
                                result += "}"
                            }
                            bestTruncation = result
                            break
                        }
                    }
                }

                if bestTruncation != String(json.prefix(maxChars)) {
                    break // Found a good truncation
                }
            }
        }

        print("[LLM] Truncated JSON from \(json.count) to \(bestTruncation.count) chars")
        return bestTruncation
    }

    private func smartTruncateHTML(_ html: String, maxChars: Int) -> String {
        guard html.count > maxChars else { return html }

        // Try to find job-related content sections
        let jobPatterns = [
            "<div[^>]*class=\"[^\"]*job[^\"]*\"",
            "<ul[^>]*class=\"[^\"]*job[^\"]*\"",
            "<section[^>]*class=\"[^\"]*career[^\"]*\"",
            "<div[^>]*class=\"[^\"]*position[^\"]*\"",
            "<div[^>]*class=\"[^\"]*opening[^\"]*\"",
            "<table[^>]*class=\"[^\"]*job[^\"]*\"",
            "<div[^>]*id=\"jobs\"",
            "<div[^>]*id=\"careers\""
        ]

        let lowercaseHTML = html.lowercased()

        for pattern in jobPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: lowercaseHTML, range: NSRange(lowercaseHTML.startIndex..., in: lowercaseHTML)) {

                let matchStart = match.range.lowerBound
                let startIndex = html.index(html.startIndex, offsetBy: max(0, matchStart - 100))
                let endIndex = html.index(startIndex, offsetBy: min(maxChars, html.distance(from: startIndex, to: html.endIndex)))

                let truncated = String(html[startIndex..<endIndex])
                print("[LLM] Truncated HTML from \(html.count) to \(truncated.count) chars (found job section)")
                return truncated
            }
        }

        // Fallback: skip past the <head> section if possible
        if let bodyStart = html.range(of: "<body", options: .caseInsensitive) {
            let startIndex = bodyStart.lowerBound
            let endIndex = html.index(startIndex, offsetBy: min(maxChars, html.distance(from: startIndex, to: html.endIndex)))
            let truncated = String(html[startIndex..<endIndex])
            print("[LLM] Truncated HTML from \(html.count) to \(truncated.count) chars (from body)")
            return truncated
        }

        print("[LLM] Truncated HTML from \(html.count) to \(maxChars) chars (simple prefix)")
        return String(html.prefix(maxChars))
    }

    deinit {
        unloadModel()
    }
}

enum LLMError: Error {
    case modelNotFound
    case failedToLoadModel(Error)
    case modelNotLoaded
    case inferenceFailed(Error)
}

/// Parsed job data from LLM
struct ParsedJob: Codable {
    let title: String
    let location: String?
    let description: String?
    let postingDate: String?
    let url: String?
    let requirements: [String]?
}

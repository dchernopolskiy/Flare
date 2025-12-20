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
        Analyze this JSON API response and tell me how to extract job listings.

        Return ONLY a JSON object with this exact structure:
        {
          "jobsArrayPath": "path.to.jobs.array",
          "titleField": "fieldName",
          "locationField": "fieldName",
          "urlField": "fieldName",
          "paginationParam": "offset|page|cursor|null",
          "pageSizeParam": "limit|size|pageSize|null"
        }

        For example, if jobs are at data.results[] with offset pagination:
        {"jobsArrayPath":"data.results","titleField":"title","locationField":"location","urlField":"jobUrl","paginationParam":"offset","pageSizeParam":"limit"}

        If no pagination info found, use null for pagination fields.

        JSON Response:
        \(truncatedJSON)

        Schema:
        """

        let prompt = Prompt(
            type: .llama3,
            systemPrompt: "You are an expert at analyzing JSON API structures.",
            userMessage: promptText
        )

        let response = try await llama.start(for: prompt)
        print("[LLM] Schema discovery response: \(response.prefix(200))...")

        guard let jsonStart = response.firstIndex(of: "{"),
              let jsonEnd = response.lastIndex(of: "}") else {
            print("[LLM] No JSON object found in schema response")
            return nil
        }

        let jsonString = String(response[jsonStart...jsonEnd])
        guard let data = jsonString.data(using: .utf8) else {
            return nil
        }

        do {
            let schema = try JSONDecoder().decode(JobResponseStructure.self, from: data)
            print("[LLM] Discovered schema: jobs at '\(schema.jobsArrayPath)', title field: '\(schema.titleField)'")
            return schema
        } catch {
            print("[LLM] Failed to decode schema: \(error)")
            return nil
        }
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

        // Truncate HTML intelligently - look for job-related content
        let truncatedHTML = smartTruncateHTML(html, maxChars: 3500)

        let promptText = """
        Extract job listings from this HTML page.

        CRITICAL: Return ONLY a JSON array, nothing else. No explanations, no markdown.

        HTML:
        \(truncatedHTML)

        If you find jobs, return this format with real data:
        [{"title":"Software Engineer","location":"Seattle, WA","url":"https://example.com/job/123"}]

        If NO jobs found in the HTML, return:
        []

        JSON:
        """

        let prompt = Prompt(
            type: .llama3,
            systemPrompt: "You are a helpful assistant that extracts job listings from HTML.",
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

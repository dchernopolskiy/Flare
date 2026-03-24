//
//  LLMParser.swift
//  Flare
//

import Foundation
import SwiftLlama

actor LLMParser {
    private var llama: SwiftLlama?
    private var isLoaded = false
    private var activeUsers: Int = 0
    private var unloadTask: Task<Void, Never>?
    private let unloadDelay: TimeInterval = 60

    static let shared = LLMParser()
    private init() {}

    var modelStatus: (isLoaded: Bool, activeUsers: Int) { (isLoaded, activeUsers) }

    func acquireModel() async throws {
        activeUsers += 1
        unloadTask?.cancel()
        unloadTask = nil
        if !isLoaded { try await loadModel() }
        print("[LLM] Model acquired (active users: \(activeUsers))")
    }

    func releaseModel() {
        activeUsers = max(0, activeUsers - 1)
        print("[LLM] Model released (active users: \(activeUsers))")
        if activeUsers == 0 { scheduleUnload() }
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(60 * 1_000_000_000))
                await self?.unloadIfIdle()
            } catch {}
        }
    }

    private func unloadIfIdle() {
        guard activeUsers == 0, isLoaded else { return }
        print("[LLM] Unloading model after idle timeout")
        unloadModel()
    }

    private func loadModel() async throws {
        guard !isLoaded else { return }
        print("[LLM] Loading Llama 3.2 3B model...")
        let startTime = Date()

        var modelPath: String?
        if let bundlePath = Bundle.main.path(forResource: "llama32-3b-instruct-q4_k_m", ofType: "gguf") {
            modelPath = bundlePath
        } else {
            let downloadedPath = await ModelDownloader.shared.getModelPath()
            if FileManager.default.fileExists(atPath: downloadedPath.path) {
                modelPath = downloadedPath.path
            } else {
                throw LLMError.modelNotFound
            }
        }

        guard let finalPath = modelPath else { throw LLMError.modelNotFound }

        do {
            let config = Configuration(nCTX: 4096, temperature: 0.1, batchSize: 512, maxTokenCount: 1024)
            llama = try SwiftLlama(modelPath: finalPath, modelConfiguration: config)
            isLoaded = true
            print("[LLM] Model loaded in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
        } catch {
            throw LLMError.failedToLoadModel(error)
        }
    }

    func discoverJSONSchema(from json: String) async throws -> JobResponseStructure? {
        try await acquireModel()
        defer { releaseModel() }
        guard let llama = llama else { throw LLMError.modelNotLoaded }

        let truncatedJSON = smartTruncateJSON(json, maxChars: 3500)
        let promptText = """
        Find where job listings are in this JSON.

        Return this exact JSON format:
        {"jobsArrayPath":"path.to.array","titleField":"title","locationField":"location","urlField":"url","paginationParam":null,"pageSizeParam":null}

        Field rules:
        - jobsArrayPath: Dot-separated path to the jobs array
        - titleField: Field name containing job title
        - locationField: Field with location
        - urlField: Field with job URL
        - paginationParam: "offset", "page", "cursor", or null
        - pageSizeParam: "limit", "size", "pageSize", or null

        JSON:
        \(truncatedJSON)

        Schema:
        """

        let prompt = Prompt(type: .llama3, systemPrompt: "You analyze JSON APIs and return extraction schemas. No explanations.", userMessage: promptText)
        let response = try await llama.start(for: prompt)

        guard let jsonString = extractJSONObject(from: response),
              let data = jsonString.data(using: .utf8) else { return nil }

        return try? JSONDecoder().decode(JobResponseStructure.self, from: data)
    }

    struct PatternDetectionResult {
        let atsURL: String?
        let atsType: String?
        let apiEndpoint: String?
        let apiType: String?
        let confidence: String
    }

    func detectPatternsInContent(_ content: String, sourceURL: URL) async throws -> PatternDetectionResult? {
        try await acquireModel()
        defer { releaseModel() }
        guard let llama = llama else { throw LLMError.modelNotLoaded }

        let strippedContent = HTMLCleaner.stripForLLM(content)
        let truncatedContent = smartTruncateHTML(strippedContent, maxChars: 3500)

        let promptText = """
        Find job board URLs or API endpoints in this content.

        Look for these ATS patterns:
        - Workday: *.myworkdayjobs.com
        - Greenhouse: boards.greenhouse.io or api.greenhouse.io
        - Lever: jobs.lever.co
        - Ashby: jobs.ashbyhq.com

        Return this exact JSON format:
        {"atsURL":null,"atsType":null,"apiEndpoint":null,"apiType":null,"confidence":"low"}

        Content from \(sourceURL.host ?? "unknown"):
        \(truncatedContent)

        JSON:
        """

        let prompt = Prompt(type: .llama3, systemPrompt: "You find job board URLs and APIs in HTML. Return JSON only.", userMessage: promptText)
        let response = try await llama.start(for: prompt)

        guard let jsonString = extractJSONObject(from: response),
              let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let result = PatternDetectionResult(
            atsURL: parsed["atsURL"] as? String,
            atsType: parsed["atsType"] as? String,
            apiEndpoint: parsed["apiEndpoint"] as? String,
            apiType: parsed["apiType"] as? String,
            confidence: (parsed["confidence"] as? String) ?? "low"
        )

        return (result.atsURL != nil || result.apiEndpoint != nil) ? result : nil
    }

    func extractJobs(from html: String, url: URL) async throws -> [ParsedJob] {
        try await acquireModel()
        defer { releaseModel() }
        guard let llama = llama else { throw LLMError.modelNotLoaded }

        let strippedHTML = HTMLCleaner.stripForLLM(html)
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

        let prompt = Prompt(type: .llama3, systemPrompt: "You extract job listings from HTML and return JSON. No explanations.", userMessage: promptText)
        let response = try await llama.start(for: prompt)
        return parseJobsFromResponse(response)
    }

    private func parseJobsFromResponse(_ response: String) -> [ParsedJob] {
        guard let jsonStart = response.firstIndex(of: "["),
              let jsonEnd = response.lastIndex(of: "]"),
              let data = String(response[jsonStart...jsonEnd]).data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ParsedJob].self, from: data)) ?? []
    }

    func unloadModel() {
        guard isLoaded else { return }
        print("[LLM] Unloading model")
        llama = nil
        isLoaded = false
    }

    private func extractJSONObject(from response: String) -> String? {
        var text = response

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
        guard let firstBrace = text.firstIndex(of: "{") else { return nil }

        var depth = 0, inString = false, escapeNext = false
        var endIndex: String.Index?

        for i in text.indices[firstBrace...] {
            let char = text[i]
            if escapeNext { escapeNext = false; continue }
            if char == "\\" && inString { escapeNext = true; continue }
            if char == "\"" { inString = !inString; continue }
            if !inString {
                if char == "{" { depth += 1 }
                else if char == "}" {
                    depth -= 1
                    if depth == 0 { endIndex = text.index(after: i); break }
                }
            }
        }

        if let end = endIndex { return String(text[firstBrace..<end]) }
        if let lastBrace = text.lastIndex(of: "}") {
            let jsonString = String(text[firstBrace...lastBrace])
            if let data = jsonString.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
                return jsonString
            }
        }
        return nil
    }

    private func smartTruncateJSON(_ json: String, maxChars: Int) -> String {
        guard json.count > maxChars else { return json }

        let arrayPatterns = ["\"jobs\":", "\"results\":", "\"data\":", "\"items\":", "\"jobCards\":", "\"positions\":",
                            "\"postings\":", "\"openings\":", "\"listings\":", "\"roles\":", "\"requisitions\":",
                            "\"opportunities\":", "\"hits\":", "\"records\":", "\"content\":", "\"entries\":"]

        for pattern in arrayPatterns {
            if let arrayStart = json.range(of: pattern) {
                let startIndex = arrayStart.lowerBound
                let endIndex = json.index(startIndex, offsetBy: min(maxChars, json.distance(from: startIndex, to: json.endIndex)))
                let truncated = String(json[..<endIndex])

                guard let arrayBracket = truncated.range(of: "[", range: arrayStart.upperBound..<truncated.endIndex),
                      let firstObjStart = truncated.range(of: "{", range: arrayBracket.upperBound..<truncated.endIndex) else { continue }

                var braceCount = 1
                var searchIndex = firstObjStart.upperBound

                while braceCount > 0 && searchIndex < truncated.endIndex {
                    let char = truncated[searchIndex]
                    if char == "{" { braceCount += 1 }
                    else if char == "}" { braceCount -= 1 }
                    searchIndex = truncated.index(after: searchIndex)

                    if braceCount == 0 {
                        let prefix = String(json[..<arrayStart.lowerBound])
                        let openBraces = prefix.filter { $0 == "{" }.count - prefix.filter { $0 == "}" }.count
                        var result = String(truncated[..<searchIndex]) + "]"
                        for _ in 0..<openBraces { result += "}" }
                        return result
                    }
                }
            }
        }
        return String(json.prefix(maxChars))
    }

    private func smartTruncateHTML(_ html: String, maxChars: Int) -> String {
        guard html.count > maxChars else { return html }

        let jobPatterns = [
            "<div[^>]*class=\"[^\"]*job[^\"]*\"", "<ul[^>]*class=\"[^\"]*job[^\"]*\"",
            "<section[^>]*class=\"[^\"]*career[^\"]*\"", "<div[^>]*class=\"[^\"]*position[^\"]*\"",
            "<div[^>]*class=\"[^\"]*opening[^\"]*\"", "<table[^>]*class=\"[^\"]*job[^\"]*\"",
            "<div[^>]*id=\"jobs\"", "<div[^>]*id=\"careers\""
        ]

        let lowercaseHTML = html.lowercased()
        for pattern in jobPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: lowercaseHTML, range: NSRange(lowercaseHTML.startIndex..., in: lowercaseHTML)) {
                let matchStart = match.range.lowerBound
                let startIndex = html.index(html.startIndex, offsetBy: max(0, matchStart - 100))
                let endIndex = html.index(startIndex, offsetBy: min(maxChars, html.distance(from: startIndex, to: html.endIndex)))
                return String(html[startIndex..<endIndex])
            }
        }

        if let bodyStart = html.range(of: "<body", options: .caseInsensitive) {
            let endIndex = html.index(bodyStart.lowerBound, offsetBy: min(maxChars, html.distance(from: bodyStart.lowerBound, to: html.endIndex)))
            return String(html[bodyStart.lowerBound..<endIndex])
        }

        return String(html.prefix(maxChars))
    }

    deinit { unloadModel() }
}

enum LLMError: Error {
    case modelNotFound
    case failedToLoadModel(Error)
    case modelNotLoaded
    case inferenceFailed(Error)
}

struct ParsedJob: Codable {
    let title: String
    let location: String?
    let description: String?
    let postingDate: String?
    let url: String?
    let requirements: [String]?
}

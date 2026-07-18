import Foundation

struct EnrichedJobDescription: Codable {
    let text: String
    let source: String
    let fetchedAt: Date
    let contentHash: String
}

/// On-demand cache for individual job descriptions.
actor JobDescriptionService {
    static let shared = JobDescriptionService()

    private var cache: [String: EnrichedJobDescription]
    private let cacheFile: URL
    private var inFlight: [String: Task<EnrichedJobDescription?, Never>] = [:]

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flare", isDirectory: true)
        cacheFile = directory.appendingPathComponent("job-descriptions.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = Self.loadCache(from: cacheFile)
    }

    func enrich(_ job: Job) async -> EnrichedJobDescription? {
        guard Self.shouldEnrich(job.description), let url = URL(string: job.url) else { return nil }

        if let cached = cache[job.id], Date().timeIntervalSince(cached.fetchedAt) < 14 * 24 * 60 * 60 {
            return cached
        }

        if let task = inFlight[job.id] {
            return await task.value
        }

        let task = Task { [url] in
            await Self.fetchDescription(from: url)
        }
        inFlight[job.id] = task
        let result = await task.value
        inFlight[job.id] = nil

        if let result {
            cache[job.id] = result
            persistCache()
        }
        return result
    }

    private static func shouldEnrich(_ description: String) -> Bool {
        let normalized = HTMLCleaner.cleanHTML(description)
        return normalized.count < 280 || normalized == "No description available."
    }

    private static func fetchDescription(from url: URL) async -> EnrichedJobDescription? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        let candidate = descriptionFromJobPostingSchema(in: html)
            ?? descriptionFromPrimaryContent(in: html)
        guard let candidate, candidate.count >= 280 else { return nil }

        return EnrichedJobDescription(
            text: candidate,
            source: descriptionFromJobPostingSchema(in: html) == nil ? "job page" : "JobPosting schema",
            fetchedAt: Date(),
            contentHash: html.sha256() ?? ""
        )
    }

    private static func descriptionFromJobPostingSchema(in html: String) -> String? {
        let pattern = #"<script[^>]+type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)

        for match in regex.matches(in: html, range: range) {
            guard let bodyRange = Range(match.range(at: 1), in: html),
                  let data = String(html[bodyRange]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let description = findJobPostingDescription(in: object) {
                return HTMLCleaner.cleanHTML(description)
            }
        }
        return nil
    }

    private static func findJobPostingDescription(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            let type = dictionary["@type"] as? String
            if type == "JobPosting", let description = dictionary["description"] as? String { return description }
            for child in dictionary.values {
                if let result = findJobPostingDescription(in: child) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = findJobPostingDescription(in: child) { return result }
            }
        }
        return nil
    }

    private static func descriptionFromPrimaryContent(in html: String) -> String? {
        let patterns = [
            #"<(?:main|article)[^>]*>(.*?)</(?:main|article)>"#,
            #"<div[^>]+(?:job-description|jobDescription|description)[^>]*>(.*?)</div>"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let text = HTMLCleaner.cleanHTML(String(html[range]))
            if text.count >= 280 { return text }
        }
        return nil
    }

    private static func loadCache(from url: URL) -> [String: EnrichedJobDescription] {
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode([String: EnrichedJobDescription].self, from: data) else { return [:] }
        return cached
    }

    private func persistCache() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }
}

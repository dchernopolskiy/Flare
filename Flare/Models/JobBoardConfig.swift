//
//  JobBoardConfig.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import Foundation

enum ParsingMethod: String, Codable {
    case directATS = "Direct ATS"
    case apiDiscovery = "API Discovery"
    case schemaOrg = "Schema.org"
    case embeddedJSON = "Embedded JSON"
    case llmExtraction = "AI Parsing"
    case htmlPatterns = "HTML Patterns"
    case unknown = "Unknown"

    var icon: String {
        switch self {
        case .directATS: return "link.circle.fill"
        case .apiDiscovery: return "antenna.radiowaves.left.and.right"
        case .schemaOrg: return "doc.text.fill"
        case .embeddedJSON: return "curlybraces"
        case .llmExtraction: return "cpu"
        case .htmlPatterns: return "text.magnifyingglass"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct JobBoardConfig: Identifiable, Codable {
    var id = UUID()
    var name: String
    var url: String
    var source: JobSource
    var isEnabled: Bool = true
    var lastFetched: Date?
    var detectedATSURL: String?
    var detectedATSType: String?
    var parsingMethod: ParsingMethod?
    var lastJobCount: Int?

    var displayName: String {
        if name.isEmpty {
            return "\(source.rawValue) Board"
        }
        return name
    }

    var isSupported: Bool {
        return source.isSupported
    }

    var effectiveURL: String {
        return detectedATSURL ?? url
    }

    var queryURL: String {
        detectedATSURL ?? url
    }

    var parsingMethodDisplay: String {
        if let method = parsingMethod {
            return method.rawValue
        }
        if detectedATSType != nil {
            return "Direct ATS"
        }
        return "Not tested"
    }

    init?(name: String, url: String, isEnabled: Bool = true, detectedATSURL: String? = nil, detectedATSType: String? = nil, parsingMethod: ParsingMethod? = nil) {
        guard let normalizedURL = Self.normalizedURLString(url) else { return nil }
        let normalizedATSURL = detectedATSURL.flatMap { Self.normalizedURLString($0) }
        let detectedSource = JobSource.detectFromURL(normalizedATSURL ?? normalizedURL) ?? .unknown

        self.name = name
        self.url = normalizedURL
        self.source = detectedSource
        self.isEnabled = isEnabled
        self.detectedATSURL = normalizedATSURL
        self.detectedATSType = detectedATSType
        self.parsingMethod = parsingMethod
    }

    static func normalizedURLString(_ rawURL: String) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        components.scheme = scheme
        components.fragment = nil
        return components.url?.absoluteString
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        source = try container.decode(JobSource.self, forKey: .source)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lastFetched = try container.decodeIfPresent(Date.self, forKey: .lastFetched)
        detectedATSURL = try container.decodeIfPresent(String.self, forKey: .detectedATSURL)
        detectedATSType = try container.decodeIfPresent(String.self, forKey: .detectedATSType)
        parsingMethod = try container.decodeIfPresent(ParsingMethod.self, forKey: .parsingMethod)
        lastJobCount = try container.decodeIfPresent(Int.self, forKey: .lastJobCount)
    }
}

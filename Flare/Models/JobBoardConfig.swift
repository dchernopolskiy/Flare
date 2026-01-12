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

    /// The effective URL to use for fetching jobs
    /// Returns detectedATSURL if available, otherwise the original URL
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
        let detectedSource = JobSource.detectFromURL(url) ?? .unknown

        self.name = name
        self.url = url
        self.source = detectedSource
        self.isEnabled = isEnabled
        self.detectedATSURL = detectedATSURL
        self.detectedATSType = detectedATSType
        self.parsingMethod = parsingMethod
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

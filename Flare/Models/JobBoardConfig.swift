//
//  JobBoardConfig.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import Foundation

struct JobBoardConfig: Identifiable, Codable {
    var id = UUID()
    var name: String
    var url: String
    var source: JobSource
    var isEnabled: Bool = true
    var lastFetched: Date?
    /// Discovered ATS URL (e.g., Workday URL found via GTM scanning)
    /// Used to skip re-detection on refresh
    var detectedATSURL: String?
    /// The ATS type of the detected URL (workday, greenhouse, etc.)
    var detectedATSType: String?

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

    init?(name: String, url: String, isEnabled: Bool = true, detectedATSURL: String? = nil, detectedATSType: String? = nil) {
        // Detect source from URL, or use .unknown for custom sites
        let detectedSource = JobSource.detectFromURL(url) ?? .unknown

        self.name = name
        self.url = url
        self.source = detectedSource
        self.isEnabled = isEnabled
        self.detectedATSURL = detectedATSURL
        self.detectedATSType = detectedATSType
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
    }
}

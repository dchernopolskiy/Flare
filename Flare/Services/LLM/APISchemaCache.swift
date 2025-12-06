//
//  ModelDownloader 2.swift
//  Flare
//
//  Created by Dan on 12/9/25.
//

import Foundation

/// Cached API schema discovered by LLM
struct DiscoveredAPISchema: Codable {
    let domain: String
    let endpoint: String
    let method: String  // GET or POST
    let requestBody: String?  // Template for POST requests
    let requestHeaders: [String: String]?  // Headers needed for the request
    let responseStructure: JobResponseStructure
    let paginationInfo: PaginationInfo?  // How to paginate through results
    let sortInfo: SortInfo?  // How to sort by date/newest
    let discoveredAt: Date
    let llmAttempted: Bool  // Whether we've tried using LLM on this domain
    let schemaDiscovered: Bool  // Whether we successfully discovered a schema
    let lastAttempt: Date  // Last time we tried to parse this domain
    var lastFetchedAt: Date?  // Last time we successfully fetched jobs
}

/// Pagination information
struct PaginationInfo: Codable {
    let type: PaginationType
    let pageParam: String?  // e.g., "page" or "offset"
    let pageSizeParam: String?  // e.g., "limit" or "pageSize"
    let maxPages: Int  // Maximum pages to fetch (default 3)
}

enum PaginationType: String, Codable {
    case offset  // offset=0, offset=20, offset=40
    case page    // page=1, page=2, page=3
    case cursor  // cursor=next_token
    case none    // No pagination
}

/// Sort information
struct SortInfo: Codable {
    let sortParam: String?  // e.g., "sort" or "orderBy"
    let sortValue: String?  // e.g., "date_desc" or "newest"
}

/// Describes how to extract jobs from JSON response
struct JobResponseStructure: Codable {
    let jobsArrayPath: String   // e.g., "data.searchJobCardsByLocation.jobCards"
    let titleField: String      // e.g., "jobTitle"
    let locationField: String?  // e.g., "location"
    let urlField: String?       // e.g., "jobId" (might need to construct URL)
    let urlTemplate: String?    // e.g., "https://hiring.amazon.com/job/\(jobId)"
    let paginationParam: String?  // LLM-discovered pagination param (e.g., "offset", "page")
    let pageSizeParam: String?    // LLM-discovered page size param (e.g., "limit", "pageSize")
}

/// Actor that manages cached API schemas discovered by the LLM
actor APISchemaCache {
    static let shared = APISchemaCache()

    private var cache: [String: DiscoveredAPISchema] = [:]
    private let cacheFile: URL

    private init() {
        // Store cache in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let flareDir = appSupport.appendingPathComponent("Flare", isDirectory: true)
        cacheFile = flareDir.appendingPathComponent("api-schemas.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: flareDir, withIntermediateDirectories: true)

        // Load existing cache
        loadCache()
    }

    /// Get cached schema for a domain
    func getSchema(for domain: String) -> DiscoveredAPISchema? {
        return cache[domain]
    }

    /// Save a discovered schema
    func saveSchema(_ schema: DiscoveredAPISchema) {
        cache[schema.domain] = schema
        persistCache()
        print("[APISchemaCache] Saved schema for \(schema.domain)")
    }

    /// Check if we have a schema for this domain
    func hasSchema(for domain: String) -> Bool {
        return cache[domain] != nil
    }

    /// Check if LLM has already been attempted on this domain (success or failure)
    func hasLLMAttempted(for domain: String) -> Bool {
        return cache[domain]?.llmAttempted ?? false
    }

    /// Mark that we attempted LLM parsing on this domain but failed
    func markLLMAttemptFailed(for domain: String) {
        let failedSchema = DiscoveredAPISchema(
            domain: domain,
            endpoint: "",
            method: "GET",
            requestBody: nil,
            requestHeaders: nil,
            responseStructure: JobResponseStructure(
                jobsArrayPath: "",
                titleField: "",
                locationField: nil,
                urlField: nil,
                urlTemplate: nil,
                paginationParam: nil,
                pageSizeParam: nil
            ),
            paginationInfo: nil,
            sortInfo: nil,
            discoveredAt: Date(),
            llmAttempted: true,
            schemaDiscovered: false,
            lastAttempt: Date(),
            lastFetchedAt: nil
        )
        cache[domain] = failedSchema
        persistCache()
        print("[APISchemaCache] Marked LLM attempt failed for \(domain)")
    }

    /// Update last fetched time for a domain
    func updateLastFetched(for domain: String) {
        if var schema = cache[domain] {
            schema.lastFetchedAt = Date()
            cache[domain] = schema
            persistCache()
        }
    }

    /// Remove cached schema (for testing/debugging)
    func clearSchema(for domain: String) {
        cache.removeValue(forKey: domain)
        persistCache()
        print("[APISchemaCache] Cleared schema for \(domain)")
    }

    /// Clear all cached schemas
    func clearAll() {
        cache.removeAll()
        persistCache()
        print("[APISchemaCache] Cleared all schemas")
    }

    /// Force retry by clearing failed status (useful for immediate debugging)
    func forceRetry(for domain: String) {
        if let schema = cache[domain], schema.llmAttempted && !schema.schemaDiscovered {
            clearSchema(for: domain)
            print("[APISchemaCache] Forced retry enabled for \(domain)")
        } else {
            print("[APISchemaCache] No failed schema found for \(domain)")
        }
    }

    // MARK: - Persistence

    private func loadCache() {
        guard FileManager.default.fileExists(atPath: cacheFile.path) else {
            print("[APISchemaCache] No cache file found")
            return
        }

        do {
            let data = try Data(contentsOf: cacheFile)
            let schemas = try JSONDecoder().decode([DiscoveredAPISchema].self, from: data)
            cache = Dictionary(uniqueKeysWithValues: schemas.map { ($0.domain, $0) })
            print("[APISchemaCache] Loaded \(cache.count) cached schemas")
        } catch {
            print("[APISchemaCache] Failed to load cache: \(error)")
        }
    }

    private func persistCache() {
        do {
            let schemas = Array(cache.values)
            let data = try JSONEncoder().encode(schemas)
            try data.write(to: cacheFile)
            print("[APISchemaCache] Persisted \(schemas.count) schemas")
        } catch {
            print("[APISchemaCache] Failed to persist cache: \(error)")
        }
    }
}

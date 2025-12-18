//
//  CachedSchemaFetcher.swift
//  Flare
//
//  Created by Dan on 12/9/25.
//

import Foundation

struct CachedSchemaFetcher {
    private let jsonParser = UniversalJSONParser()
    private let jobTracker = JobTracker.shared

    func fetchJobs(
        schema: DiscoveredAPISchema,
        titleFilter: String = "",
        locationFilter: String = ""
    ) async -> [Job] {
        var allJobs: [Job] = []
        var page = 0

        let maxPages = schema.paginationInfo?.maxPages ?? 3

        for pageNum in 0..<maxPages {
            guard let jobs = await fetchPage(
                schema: schema,
                page: pageNum,
                titleFilter: titleFilter,
                locationFilter: locationFilter
            ) else {
                break
            }

            if jobs.isEmpty {
                break
            }

            allJobs.append(contentsOf: jobs)
            page += 1

            print("[RobustFetcher] Fetched page \(pageNum): \(jobs.count) jobs (total: \(allJobs.count))")

            if jobs.count < 20 {
                break
            }
        }

        return allJobs
    }

    private func fetchPage(
        schema: DiscoveredAPISchema,
        page: Int,
        titleFilter: String,
        locationFilter: String
    ) async -> [Job]? {
        guard let apiURL = URL(string: schema.endpoint) else {
            return nil
        }

        do {
            var request = URLRequest(url: apiURL)
            request.httpMethod = schema.method

            if let body = schema.requestBody {
                let modifiedBody = addPaginationAndSort(
                    to: body,
                    page: page,
                    pagination: schema.paginationInfo,
                    sort: schema.sortInfo
                )
                request.httpBody = modifiedBody.data(using: .utf8)
            }

            if let headers = schema.requestHeaders {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[RobustFetcher] Request failed with status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }

            guard let jsonString = String(data: data, encoding: .utf8) else {
                return nil
            }

            let parsedJobs = jsonParser.extractJobs(
                from: jsonString,
                using: schema.responseStructure,
                baseURL: apiURL
            )

            var jobs: [Job] = []

            for parsed in parsedJobs {
                guard let title = parsed.title.nilIfEmpty else { continue }
                let jobId = generateJobId(title: title, url: parsed.url)
                await jobTracker.trackJob(
                    id: jobId,
                    title: title,
                    url: parsed.url ?? apiURL.absoluteString,
                    source: schema.domain
                )

                let firstSeenDate = await jobTracker.getFirstSeenDate(for: jobId) ?? Date()
                let job = Job(
                    id: jobId,
                    title: title,
                    location: parsed.location ?? "Remote",
                    postingDate: nil,  // Use firstSeenDate instead
                    url: parsed.url ?? apiURL.absoluteString,
                    description: parsed.description ?? "",
                    workSiteFlexibility: nil,
                    source: .unknown,
                    companyName: schema.domain.replacingOccurrences(of: ".com", with: "").capitalized,
                    department: nil,
                    category: nil,
                    firstSeenDate: firstSeenDate,
                    originalPostingDate: nil,
                    wasBumped: false
                )

                jobs.append(job)
            }

            return applyFilters(jobs, titleFilter: titleFilter, locationFilter: locationFilter)

        } catch {
            print("[RobustFetcher] Fetch error: \(error)")
            return nil
        }
    }

    private func addPaginationAndSort(
        to body: String,
        page: Int,
        pagination: PaginationInfo?,
        sort: SortInfo?
    ) -> String {
        guard var jsonDict = parseJSON(body) else {
            return body
        }

        if let paginationInfo = pagination, page > 0 {
            switch paginationInfo.type {
            case .offset:
                if let param = paginationInfo.pageParam {
                    let offset = page * 20
                    jsonDict[param] = offset
                }
            case .page:
                if let param = paginationInfo.pageParam {
                    jsonDict[param] = page + 1
                }
            case .cursor, .none:
                break // not supported
            }
        }

        if let sortInfo = sort,
           let sortParam = sortInfo.sortParam,
           let sortValue = sortInfo.sortValue {
            jsonDict[sortParam] = sortValue
        }

        return serializeJSON(jsonDict) ?? body
    }

    /// Apply title and location filters
    private func applyFilters(_ jobs: [Job], titleFilter: String, locationFilter: String) -> [Job] {
        var filtered = jobs

        if !titleFilter.isEmpty {
            filtered = filtered.filter {
                $0.title.localizedCaseInsensitiveContains(titleFilter)
            }
        }

        if !locationFilter.isEmpty {
            filtered = filtered.filter {
                $0.location.localizedCaseInsensitiveContains(locationFilter)
            }
        }

        return filtered
    }

    /// Generate a unique ID for a job (for tracking)
    private func generateJobId(title: String, url: String?) -> String {
        if let url = url, !url.isEmpty {
            return url.sha256() ?? "\(title)-\(url)".sha256() ?? UUID().uuidString
        }
        return title.sha256() ?? UUID().uuidString
    }

    // MARK: - JSON Helpers

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func serializeJSON(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - String Extensions

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    func sha256() -> String? {
        guard let data = self.data(using: .utf8) else { return nil }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// Need to import CommonCrypto for SHA256
import CommonCrypto

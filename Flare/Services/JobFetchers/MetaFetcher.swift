//
//  MetaFetcher.swift
//  Flare
//
//  Created by Dan on 11/14/25.
//


import Foundation

actor MetaFetcher: JobFetcherProtocol {
    private let graphqlURL = URL(string: "https://www.metacareers.com/graphql")!
    private let baseURL = URL(string: "https://www.metacareers.com/jobs")!
    private let resultsPerPage = 10
    private let trackingService = JobTrackingService.shared

    private struct PageTokens {
        let lsd: String
        let rev: String
        let hsi: String
        let dtsg: String?
    }

    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        let trackingData = await trackingService.loadTrackingData(for: "meta")
        let currentDate = Date()
        let offices = MetaLocationService.getMetaOffices(from: location)
        let tokens = try await extractPageTokens()
        let allJobs = try await fetchJobsPage(
            query: titleKeywords.joined(separator: " "),
            offices: offices,
            tokens: tokens,
            trackingData: trackingData,
            currentDate: currentDate
        )
        
        guard !allJobs.isEmpty else {
            throw FetchError.noJobs
        }
        
        await trackingService.saveTrackingData(allJobs, for: "meta", currentDate: currentDate, retentionDays: 30)
        return allJobs
    }
    
    private func extractPageTokens() async throws -> PageTokens {
        var request = URLRequest(url: baseURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "user-agent")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""
        
        var lsd = "AdHIRfW3-F8"  // fallback
        if let lsdMatch = html.range(of: #""lsd":"([^"]+)""#, options: .regularExpression) {
            let lsdString = String(html[lsdMatch])
            if let extracted = lsdString.split(separator: "\"").dropFirst(2).first {
                lsd = String(extracted)
            }
        }
        
        var rev = "1029904231"  // fallback
        if let revMatch = html.range(of: #""rev":(\d+)"#, options: .regularExpression) {
            let revString = String(html[revMatch])
            if let extracted = revString.split(separator: ":").last {
                rev = String(extracted)
            }
        }
        
        var hsi = "7572712374240723453"  // fallback
        if let hsiMatch = html.range(of: #""hsi":"([^"]+)""#, options: .regularExpression) {
            let hsiString = String(html[hsiMatch])
            if let extracted = hsiString.split(separator: "\"").dropFirst(2).first {
                hsi = String(extracted)
            }
        }
        
        print("[Meta] Extracted tokens - lsd: \(lsd), rev: \(rev), hsi: \(hsi)")
        
        return PageTokens(lsd: lsd, rev: rev, hsi: hsi, dtsg: nil)
    }
    
    private func fetchJobsPage(
        query: String,
        offices: [String],
        tokens: PageTokens,
        trackingData: [String: Date],
        currentDate: Date
    ) async throws -> [Job] {
        
        var request = URLRequest(url: graphqlURL)
        request.httpMethod = "POST"
        
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("https://www.metacareers.com", forHTTPHeaderField: "origin")
        request.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36", forHTTPHeaderField: "user-agent")
        
        request.setValue("359341", forHTTPHeaderField: "x-asbd-id")
        request.setValue(tokens.lsd, forHTTPHeaderField: "x-fb-lsd")
        request.setValue("CareersJobSearchResultsV3DataQuery", forHTTPHeaderField: "x-fb-friendly-name")
        
        let searchInput: [String: Any] = [
            "q": query,
            "divisions": [],
            "offices": offices,
            "roles": [],
            "leadership_levels": [],
            "saved_jobs": [],
            "saved_searches": [],
            "sub_teams": [],
            "teams": [],
            "is_leadership": false,
            "is_remote_only": false,
            "sort_by_new": true,
            "results_per_page": NSNull()
        ]
        
        let variables = ["search_input": searchInput]
        let variablesJSON = try JSONSerialization.data(withJSONObject: variables)
        let variablesString = String(data: variablesJSON, encoding: .utf8) ?? "{}"
        
        let formData: [(String, String)] = [
            ("av", "0"),
            ("__user", "0"),
            ("__a", "1"),
            ("__req", "2"),
            ("__hs", "20406.BP:DEFAULT.2.0...0"),
            ("dpr", "2"),
            ("__ccg", "EXCELLENT"),
            ("__rev", tokens.rev),
            ("__s", "zxdy4b:m4u6iq:ceiap0"),
            ("__hsi", tokens.hsi),
            ("__dyn", "7xeUmwkHg7ebwKBAg5S1Dxu13wqovzEdEc8uxa1twYwJw5ux609vCwjE1EE2Cwooa81VohwnU14E9k2C0iK0D82Ixe0DopyE3bwkE5G0zE5W0HU15o2syES4E3PwbS1Lwqo3cwio6O1FxG0lW1TwmU3yw5Pw"),
            ("__hsdp", "gIMX2bkjxWEti48gCsZ92qpk-7EO37xmGy8C9w8S1wwhk0IE0AS09mxi0HE5G5VWwoE19o3nxmm1Xxe0hO22UC0Jo9oN2oKUjCU0aKo5i"),
            ("__hblp", "0Vw9O1nw6Vw31E6e0bQw75w4ww2bU3Gw13a0o23e0nO0nC04aU3aO01Au0ckw0ymw2582pwbW04WQq07Po1r80JW"),
            ("lsd", tokens.lsd),
            ("jazoest", "2803"),
            ("__spin_r", tokens.rev),
            ("__spin_b", "trunk"),
            ("__spin_t", String(Int(Date().timeIntervalSince1970))),
            ("__jssesw", "1"),
            ("fb_api_caller_class", "RelayModern"),
            ("fb_api_req_friendly_name", "CareersJobSearchResultsV3DataQuery"),
            ("server_timestamps", "true"),
            ("variables", variablesString),
            ("doc_id", "24330890369943030")
        ]
        
        let bodyString = formData
            .map { key, value in
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(key)=\(encodedValue)"
            }
            .joined(separator: "&")
        
        request.httpBody = bodyString.data(using: .utf8)
        
        print("[Meta] Making GraphQL request with \(offices.count) offices")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
            print("[Meta] HTTP \(httpResponse.statusCode) Response:")
            print(responseString)
        }
        
        guard httpResponse.statusCode == 200 else {
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }
        
        let decoded = try JSONDecoder().decode(MetaGraphQLResponse.self, from: data)

        guard let allJobs = decoded.data?.job_search_with_featured_jobs?.all_jobs else {
            print("[Meta] No jobs found in response")
            return []
        }

        print("[Meta] Found \(allJobs.count) jobs (firstSeenDate tracking enabled)")
        
        let jobs = allJobs.compactMap { metaJob -> Job? in
            let jobId = "meta-\(metaJob.id)"
            let firstSeenDate = trackingData[jobId] ?? currentDate
            let locationString = metaJob.locations.joined(separator: " / ")
            let teams = metaJob.teams.joined(separator: ", ")
            let subTeams = metaJob.sub_teams.joined(separator: ", ")
            
            return Job(
                id: jobId,
                title: metaJob.title,
                location: locationString,
                postingDate: nil,
                url: "https://www.metacareers.com/jobs/\(metaJob.id)",
                description: "",
                workSiteFlexibility: metaJob.locations.contains(where: { $0.contains("Remote") }) ? "Remote" : nil,
                source: .meta,
                companyName: "Meta",
                department: subTeams.isEmpty ? nil : subTeams,
                category: teams.isEmpty ? nil : teams,
                firstSeenDate: firstSeenDate,
                originalPostingDate: nil,  // Meta API doesn't provide dates
                wasBumped: false  // Meta API doesn't support bump detection
            )
        }

        return jobs
    }
}

// MARK: - Models

struct MetaGraphQLResponse: Codable {
    let data: MetaDataWrapper?
}

struct MetaDataWrapper: Codable {
    let job_search_with_featured_jobs: MetaJobSearchWrapper?
}

struct MetaJobSearchWrapper: Codable {
    let all_jobs: [MetaJob]
}

struct MetaJob: Codable {
    let id: String
    let title: String
    let locations: [String]
    let teams: [String]
    let sub_teams: [String]
}

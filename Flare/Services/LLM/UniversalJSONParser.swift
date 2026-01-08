//
//  UniversalJSONParser.swift
//  Flare
//
//  Created by Dan on 12/9/25.
//

import Foundation

struct UniversalJSONParser {

    func extractJobs(from jsonString: String, using schema: JobResponseStructure, baseURL: URL) -> [ParsedJob] {
        guard let data = jsonString.data(using: .utf8) else {
            print("[UniversalJSON] Failed to convert to data")
            return []
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[UniversalJSON] Failed to parse as JSON object")
                return []
            }

            guard let jobsArray = getValue(from: json, path: schema.jobsArrayPath) as? [[String: Any]] else {
                print("[UniversalJSON] Failed to find jobs array at path: \(schema.jobsArrayPath)")
                return []
            }

            print("[UniversalJSON] Found \(jobsArray.count) jobs in array")

            let jobs = jobsArray.compactMap { jobDict -> ParsedJob? in
                extractJob(from: jobDict, schema: schema, baseURL: baseURL)
            }

            print("[UniversalJSON] Successfully extracted \(jobs.count) jobs")
            return jobs

        } catch {
            print("[UniversalJSON] JSON parsing error: \(error)")
            return []
        }
    }

    private func extractJob(from dict: [String: Any], schema: JobResponseStructure, baseURL: URL) -> ParsedJob? {
        guard let title = dict[schema.titleField] as? String, !title.isEmpty else {
            return nil
        }

        let location: String? = if let locField = schema.locationField {
            dict[locField] as? String
        } else {
            nil
        }

        // Build URL from schema
        var url: String? = nil
        if let urlField = schema.urlField {
            if let urlStr = dict[urlField] as? String {
                if urlStr.starts(with: "http") {
                    url = urlStr
                } else if let urlTemplate = schema.urlTemplate {
                    // Replace {placeholder} style templates with the actual value
                    // e.g., "https://example.com/job/{jobId}" with urlField="jobId"
                    url = urlTemplate
                        .replacingOccurrences(of: "{\(urlField)}", with: urlStr)
                        .replacingOccurrences(of: "{id}", with: urlStr)  // Common fallback
                        .replacingOccurrences(of: "{jobId}", with: urlStr)  // Common pattern
                } else {
                    url = baseURL.appendingPathComponent(urlStr).absoluteString
                }
            } else if let urlId = dict[urlField] as? Int {
                // Handle numeric IDs
                let idStr = String(urlId)
                if let urlTemplate = schema.urlTemplate {
                    url = urlTemplate
                        .replacingOccurrences(of: "{\(urlField)}", with: idStr)
                        .replacingOccurrences(of: "{id}", with: idStr)
                        .replacingOccurrences(of: "{jobId}", with: idStr)
                } else {
                    url = baseURL.appendingPathComponent(idStr).absoluteString
                }
            }
        }

        return ParsedJob(
            title: title,
            location: location,
            description: nil,
            postingDate: nil,
            url: url,
            requirements: nil
        )
    }

    private func getValue(from json: Any, path: String) -> Any? {
        let components = path.split(separator: ".").map(String.init)
        var current: Any = json

        for component in components {
            if let dict = current as? [String: Any] {
                guard let next = dict[component] else {
                    print("[UniversalJSON] Path component '\(component)' not found")
                    return nil
                }
                current = next
            } else {
                print("[UniversalJSON] Cannot navigate into non-dictionary at '\(component)'")
                return nil
            }
        }

        return current
    }
}

//
//  Jobs.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import SwiftUI
import Foundation
import Combine
import UserNotifications
import AppKit
import os.log

// MARK: - Filter String Parsing
extension String {
    func parseAsFilterKeywords() -> [String] {
        guard !isEmpty else { return [] }
        return split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension Array where Element == String {
    func includingRemote() -> [String] {
        let remoteKeywords = ["remote", "work from home", "distributed", "anywhere"]
        let hasRemoteKeyword = contains { keyword in
            remoteKeywords.contains { remote in
                keyword.localizedCaseInsensitiveContains(remote)
            }
        }
        return hasRemoteKeyword ? self : self + ["remote"]
    }
}

// MARK: - Job Filtering
extension Array where Element == Job {
    func filtered(titleFilter: String = "", locationFilter: String = "") -> [Job] {
        var result = self

        if !titleFilter.isEmpty {
            let keywords = titleFilter.lowercased().components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            result = result.filter { job in
                let title = job.title.lowercased()
                return keywords.contains { title.contains($0) }
            }
        }

        if !locationFilter.isEmpty {
            let keywords = locationFilter.lowercased().components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            result = result.filter { job in
                let location = job.location.lowercased()
                return keywords.contains { location.contains($0) }
            }
        }

        return result
    }

    func merging(_ other: [Job]) -> [Job] {
        let existingIds = Set(map { $0.id })
        let newJobs = other.filter { !existingIds.contains($0.id) }
        return self + newJobs
    }

    func applying(titleKeywords: [String], locationKeywords: [String]) -> [Job] {
        var result = self

        if !titleKeywords.isEmpty {
            let keywords = titleKeywords.filter { !$0.isEmpty }
            if !keywords.isEmpty {
                result = result.filter { job in
                    keywords.contains { keyword in
                        job.title.localizedCaseInsensitiveContains(keyword) ||
                        job.department?.localizedCaseInsensitiveContains(keyword) ?? false ||
                        job.category?.localizedCaseInsensitiveContains(keyword) ?? false
                    }
                }
            }
        }

        if !locationKeywords.isEmpty {
            let keywords = locationKeywords.filter { !$0.isEmpty }
            if !keywords.isEmpty {
                result = result.filter { job in
                    keywords.contains { keyword in
                        job.location.localizedCaseInsensitiveContains(keyword)
                    }
                }
            }
        }

        return result
    }
}

// MARK: - Work Flexibility Extraction
enum WorkFlexibility {
    private static let keywords = ["remote", "hybrid", "flexible", "work from home", "onsite", "on-site", "in-office"]

    static func extract(from text: String) -> String? {
        let lowercased = text.lowercased()
        for keyword in keywords {
            if lowercased.contains(keyword) {
                return keyword.capitalized
            }
        }
        return nil
    }
}

// MARK: - Fetcher Logging
enum FetcherLog {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.flare", category: "Fetcher")

    static func info(_ source: String, _ message: String) {
        logger.info("[\(source)] \(message)")
    }

    static func debug(_ source: String, _ message: String) {
        logger.debug("[\(source)] \(message)")
    }

    static func error(_ source: String, _ message: String) {
        logger.error("[\(source)] \(message)")
    }

    static func warning(_ source: String, _ message: String) {
        logger.warning("[\(source)] \(message)")
    }
}

struct Job: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let location: String
    let postingDate: Date?
    let url: String
    let description: String
    let workSiteFlexibility: String?
    let source: JobSource
    let companyName: String?
    let department: String?
    let category: String?
    let firstSeenDate: Date
    
    let originalPostingDate: Date?
    let wasBumped: Bool
    
    var isRecent: Bool {
        if let postingDate = postingDate {
            let hoursSincePosting = Date().timeIntervalSince(postingDate) / 3600
            return hoursSincePosting <= 24 && hoursSincePosting >= 0
        }
        // use first seen date for TikTok and such
        let hoursSinceFirstSeen = Date().timeIntervalSince(firstSeenDate) / 3600
        return hoursSinceFirstSeen <= 24 && hoursSinceFirstSeen >= 0
    }
    
    var isBumpedRecently: Bool {
        guard wasBumped, let postingDate = postingDate else { return false }
        let hoursSinceRefresh = Date().timeIntervalSince(postingDate) / 3600
        return hoursSinceRefresh <= 24 && hoursSinceRefresh >= 0
    }
    
    var cleanDescription: String {
        HTMLCleaner.cleanHTML(description)
    }
    
    var overview: String {
        let text = cleanDescription
        
        let qualificationMarkers = [
            "Required/Minimum Qualifications",
            "Required Qualifications",
            "Minimum Qualifications",
            "Basic Qualifications",
            "Qualifications",
            "Responsibilities"
        ]
        
        var endIndex = text.endIndex
        for marker in qualificationMarkers {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                if range.lowerBound < endIndex {
                    endIndex = range.lowerBound
                }
            }
        }
        
        let overview = String(text[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return overview.isEmpty ? "No description available." : overview
    }
    
    var requiredQualifications: String? {
        QualificationExtractor.extractRequired(from: cleanDescription)
    }
    
    var preferredQualifications: String? {
        QualificationExtractor.extractPreferred(from: cleanDescription)
    }
    
    var applyButtonText: String {
        source.applyButtonText
    }
}

// MARK: - Job Source Enum
enum JobSource: String, Codable, CaseIterable {
    case microsoft = "Microsoft"
    case apple = "Apple"
    case google = "Google"
    case amazon = "Amazon"
    case tiktok = "TikTok"
    case snap = "Snap"
    case amd = "AMD"
    case meta = "Meta"
    case workday = "Workday"
    case greenhouse = "Greenhouse"
    case workable = "Workable"
    case jobvite = "Jobvite"
    case lever = "Lever"
    case bamboohr = "BambooHR"
    case smartrecruiters = "SmartRecruiters"
    case ashby = "Ashby"
    case jazzhr = "JazzHR"
    case recruitee = "Recruitee"
    case breezyhr = "Breezy HR"
    case unknown = "Custom"
    
    var icon: String {
        switch self {
        case .microsoft: return "building.2.fill"
        case .apple: return "applelogo"
        case .google: return "g.circle.fill"
        case .amazon: return "shippingbox.fill"
        case .tiktok: return "music.note.tv.fill"
        case .snap: return "camera.fill"
        case .amd: return "cpu.fill"
        case .meta: return "infinity"
        case .workday: return "briefcase.fill"
        case .greenhouse: return "leaf.fill"
        case .workable: return "briefcase.circle.fill"
        case .jobvite: return "person.3.fill"
        case .lever: return "slider.horizontal.3"
        case .bamboohr: return "leaf.arrow.triangle.circlepath"
        case .smartrecruiters: return "brain.head.profile"
        case .ashby: return "person.crop.circle.badge.plus"
        case .jazzhr: return "music.note"
        case .recruitee: return "person.2.badge.plus"
        case .breezyhr: return "wind"
        case .unknown: return "globe"
        }
    }
    
    var color: Color {
        switch self {
        case .microsoft: return .indigo
        case .apple: return .gray
        case .google: return .blue
        case .amazon: return .orange
        case .tiktok: return .pink
        case .snap: return .yellow
        case .amd: return .red
        case .workday: return .purple
        case .meta: return .blue
        case .greenhouse: return .green
        case .workable: return .purple
        case .jobvite: return .orange
        case .lever: return .cyan
        case .bamboohr: return .brown
        case .smartrecruiters: return .indigo
        case .ashby: return .teal
        case .jazzhr: return .yellow
        case .recruitee: return .mint
        case .breezyhr: return .gray
        case .unknown: return .orange
        }
    }

    private static let applyButtonLabels: [JobSource: String] = [
        .microsoft: "Apply on Microsoft Careers",
        .apple: "Apply on Apple Careers",
        .tiktok: "Apply on Life at TikTok",
        .snap: "Apply on Snap Careers",
        .meta: "Apply on Meta Careers",
        .amd: "Apply on AMD Careers",
        .google: "Apply on Google Careers",
        .amazon: "Apply on Amazon Jobs"
    ]

    var applyButtonText: String {
        Self.applyButtonLabels[self] ?? "Apply on Company Website"
    }

    var isSupported: Bool {
        switch self {
        case .microsoft, .apple, .google, .amazon, .tiktok, .greenhouse,
             .ashby, .lever, .snap, .amd, .meta, .workday, .unknown:
            return true
        default:
            return false
        }
    }

    static func detectFromURL(_ urlString: String) -> JobSource? {
        let lowercased = urlString.lowercased()

        if lowercased.contains("careers.microsoft.com") {
            return .microsoft
        } else if lowercased.contains("jobs.apple.com") {
            return .apple
        } else if lowercased.contains("google.com/about/careers") || lowercased.contains("careers.google.com") {
            return .google
        } else if lowercased.contains("amazon.jobs") || lowercased.contains("hiring.amazon.com") {
            return .amazon
        } else if lowercased.contains("lifeattiktok.com") || lowercased.contains("tiktok.com") {
            return .tiktok
        } else if lowercased.contains("careers.snap.com") || lowercased.contains("snap.com/careers") {
            return .snap
        } else if lowercased.contains("careers.amd.com") {
            return .amd
        } else if lowercased.contains("www.metacareers.com") {
            return .meta
        } else if lowercased.contains("myworkdayjobs.com") || lowercased.contains(".wd") {
            return .workday
        } else if lowercased.contains("greenhouse.io") {
            return .greenhouse
        } else if lowercased.contains("workable.com") {
            return .workable
        } else if lowercased.contains("jobvite.com") {
            return .jobvite
        } else if lowercased.contains("lever.co") {
            return .lever
        } else if lowercased.contains("bamboohr.com") {
            return .bamboohr
        } else if lowercased.contains("smartrecruiters.com") {
            return .smartrecruiters
        } else if lowercased.contains("ashbyhq.com") {
            return .ashby
        } else if lowercased.contains("jazz.co") || lowercased.contains("jazzhr.com") {
            return .jazzhr
        } else if lowercased.contains("recruitee.com") {
            return .recruitee
        } else if lowercased.contains("breezy.hr") {
            return .breezyhr
        } else {
            // Unknown/custom career site - will use SmartJobParser with LLM fallback
            return .unknown
        }
    }
}

// MARK: - Helper Classes
class HTMLCleaner {
    static func stripForLLM(_ html: String) -> String {
        var result = html

        let elementsToRemove = [
            "head", "script", "style", "nav", "header", "footer",
            "aside", "iframe", "noscript", "svg", "form", "button",
            "input", "select", "textarea", "canvas", "video", "audio"
        ]

        for element in elementsToRemove {
            let pattern = "<\(element)[^>]*>[\\s\\S]*?</\(element)>"
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])

            let selfClosingPattern = "<\(element)[^>]*/>"
            result = result.replacingOccurrences(of: selfClosingPattern, with: "", options: [.regularExpression, .caseInsensitive])

            let openingOnlyPattern = "<\(element)[^>]*>"
            result = result.replacingOccurrences(of: openingOnlyPattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        let attributePatterns = [
            #"\s+class="[^"]*""#,
            #"\s+class='[^']*'"#,
            #"\s+style="[^"]*""#,
            #"\s+style='[^']*'"#,
            #"\s+data-[a-z0-9-]+="[^"]*""#,
            #"\s+data-[a-z0-9-]+'[^']*'"#,
            #"\s+aria-[a-z]+="[^"]*""#,
            #"\s+role="[^"]*""#,
            #"\s+onclick="[^"]*""#,
            #"\s+onload="[^"]*""#,
            #"\s+onerror="[^"]*""#
        ]

        for pattern in attributePatterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanHTML(_ html: String) -> String {
        let htmlDecoded = decodeHTMLEntities(html)

        var text = htmlDecoded
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n\n")
            .replacingOccurrences(of: "<p>", with: "")
            .replacingOccurrences(of: "</div>", with: "\n")
            .replacingOccurrences(of: "<div>", with: "")
            .replacingOccurrences(of: "<li>", with: "• ")
            .replacingOccurrences(of: "</li>", with: "\n")
            .replacingOccurrences(of: "<ul>", with: "\n")
            .replacingOccurrences(of: "</ul>", with: "\n")
            .replacingOccurrences(of: "<ol>", with: "\n")
            .replacingOccurrences(of: "</ol>", with: "\n")

        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        let lines = text.components(separatedBy: .newlines)
        let cleanedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }

        var result: [String] = []
        var previousWasEmpty = false

        for line in cleanedLines {
            if line.isEmpty {
                if !previousWasEmpty && !result.isEmpty {
                    result.append("")
                }
                previousWasEmpty = true
            } else {
                result.append(line)
                previousWasEmpty = false
            }
        }

        return result.joined(separator: "\n")
    }

    private static func decodeHTMLEntities(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }

        do {
            let attributedString = try NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            )
            return attributedString.string
        } catch {
            return manualDecodeHTMLEntities(html)
        }
    }

    private static func manualDecodeHTMLEntities(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\n", with: "\n")
    }
}

class QualificationExtractor {
    static func extractRequired(from text: String) -> String? {
        let requiredMarkers = [
            "Minimum Qualifications",
            "Required/Minimum Qualifications",
            "Required Qualifications",
            "Basic Qualifications"
        ]
        
        return extract(from: text, markers: requiredMarkers, endMarkers: [
            "Preferred Qualifications",
            "Additional Qualifications",
            "Preferred/Additional Qualifications",
            "equal opportunity employer"
        ])
    }
    
    static func extractPreferred(from text: String) -> String? {
        let preferredMarkers = [
            "Preferred Qualifications",
            "Additional Qualifications",
            "Preferred/Additional Qualifications"
        ]
        
        return extract(from: text, markers: preferredMarkers, endMarkers: [
            "equal opportunity employer",
            "Benefits/perks listed below",
            "#LI-"
        ])
    }
    
    private static func extract(from text: String, markers: [String], endMarkers: [String]) -> String? {
        for marker in markers {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                let afterMarker = String(text[range.upperBound...])
                
                var endIndex = afterMarker.endIndex
                for endMarker in endMarkers {
                    if let endRange = afterMarker.range(of: endMarker, options: .caseInsensitive) {
                        if endRange.lowerBound < endIndex {
                            endIndex = endRange.lowerBound
                        }
                    }
                }
                
                let qualifications = String(afterMarker[..<endIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                return qualifications.isEmpty ? nil : qualifications
            }
        }
        
        return nil
    }
}


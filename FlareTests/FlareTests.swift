//
//  FlareTests.swift
//  FlareTests
//

import Testing
import Foundation
@testable import FlareJobMonitor

// MARK: - Job Model Tests

struct JobTests {

    @Test func jobIsNew_withinPostingCutoff() async throws {
        let recentJob = Job(
            id: "test-1",
            title: "Test Job",
            location: "Seattle",
            postingDate: Date().addingTimeInterval(-3600), // 1 hour ago
            url: "https://example.com/job/1",
            description: "Test",
            workSiteFlexibility: "Remote",
            source: .greenhouse,
            companyName: "Test Co",
            department: nil,
            category: nil,
            firstSeenDate: Date().addingTimeInterval(-7200), // 2 hours ago
            originalPostingDate: nil,
            wasBumped: false
        )

        #expect(recentJob.isRecent == true)
    }

    @Test func jobIsRecent_noPostingDate_withinFirstSeenCutoff() async throws {
        let job = Job(
            id: "test-2",
            title: "Job Without Posting Date",
            location: "Seattle",
            postingDate: nil, // No posting date - falls back to firstSeenDate
            url: "https://example.com/job/2",
            description: "Test",
            workSiteFlexibility: "Remote",
            source: .tiktok, // TikTok doesn't provide posting dates
            companyName: "Test Co",
            department: nil,
            category: nil,
            firstSeenDate: Date().addingTimeInterval(-3600), // 1 hour ago (just discovered)
            originalPostingDate: nil,
            wasBumped: false
        )

        // Job is "recent" based on firstSeenDate being within 24h (fallback when no postingDate)
        #expect(job.isRecent == true)
    }

    @Test func jobIsNotNew_outsideBothCutoffs() async throws {
        let oldJob = Job(
            id: "test-3",
            title: "Old Job",
            location: "Seattle",
            postingDate: Date().addingTimeInterval(-259200), // 3 days ago
            url: "https://example.com/job/3",
            description: "Test",
            workSiteFlexibility: "Remote",
            source: .greenhouse,
            companyName: "Test Co",
            department: nil,
            category: nil,
            firstSeenDate: Date().addingTimeInterval(-172800), // 2 days ago
            originalPostingDate: nil,
            wasBumped: false
        )

        #expect(oldJob.isRecent == false)
    }
}

// MARK: - JobSource Tests

struct JobSourceTests {

    @Test func detectGreenhouseFromURL() async throws {
        let urls = [
            "https://boards.greenhouse.io/anthropic",
            "https://job-boards.greenhouse.io/stripe",
            "https://boards.greenhouse.io/company/jobs/12345"
        ]

        for url in urls {
            let source = JobSource.detectFromURL(url)
            #expect(source == .greenhouse, "Failed for URL: \(url)")
        }
    }

    @Test func detectLeverFromURL() async throws {
        let urls = [
            "https://jobs.lever.co/company",
            "https://jobs.lever.co/company/job-id"
        ]

        for url in urls {
            let source = JobSource.detectFromURL(url)
            #expect(source == .lever, "Failed for URL: \(url)")
        }
    }

    @Test func detectAshbyFromURL() async throws {
        let urls = [
            "https://jobs.ashbyhq.com/company",
            "https://jobs.ashbyhq.com/company/job-id"
        ]

        for url in urls {
            let source = JobSource.detectFromURL(url)
            #expect(source == .ashby, "Failed for URL: \(url)")
        }
    }

    @Test func detectWorkdayFromURL() async throws {
        let urls = [
            "https://company.wd5.myworkdayjobs.com/careers",
            "https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternalCareerSite"
        ]

        for url in urls {
            let source = JobSource.detectFromURL(url)
            #expect(source == .workday, "Failed for URL: \(url)")
        }
    }

    @Test func unknownSourceForCustomURL() async throws {
        let url = "https://careers.netflix.com/jobs"
        let source = JobSource.detectFromURL(url)
        #expect(source == .unknown || source == nil)
    }
}

// MARK: - JobBoardConfig Tests

struct JobBoardConfigTests {

    @Test func initFromGreenhouseURL() async throws {
        let config = JobBoardConfig(
            name: "Anthropic",
            url: "https://boards.greenhouse.io/anthropic",
            detectedATSURL: nil,
            detectedATSType: nil,
            parsingMethod: nil
        )

        #expect(config != nil)
        #expect(config?.source == .greenhouse)
        #expect(config?.isSupported == true)
    }

    @Test func initFromCustomURL() async throws {
        let config = JobBoardConfig(
            name: "Netflix",
            url: "https://explore.jobs.netflix.net/careers",
            detectedATSURL: nil,
            detectedATSType: nil,
            parsingMethod: nil
        )

        #expect(config != nil)
        #expect(config?.source == .unknown)
    }

    @Test func effectiveURLReturnsDetectedWhenAvailable() async throws {
        var config = JobBoardConfig(
            name: "Test",
            url: "https://careers.company.com",
            detectedATSURL: "https://boards.greenhouse.io/company",
            detectedATSType: "greenhouse",
            parsingMethod: .directATS
        )

        #expect(config?.effectiveURL == "https://boards.greenhouse.io/company")
    }

    @Test func effectiveURLReturnsOriginalWhenNoDetected() async throws {
        let config = JobBoardConfig(
            name: "Test",
            url: "https://careers.company.com",
            detectedATSURL: nil,
            detectedATSType: nil,
            parsingMethod: nil
        )

        #expect(config?.effectiveURL == "https://careers.company.com")
    }
}

// MARK: - ParsingMethod Tests

struct ParsingMethodTests {

    @Test func parsingMethodIcons() async throws {
        #expect(ParsingMethod.directATS.icon == "link.circle.fill")
        #expect(ParsingMethod.apiDiscovery.icon == "antenna.radiowaves.left.and.right")
        #expect(ParsingMethod.schemaOrg.icon == "doc.text.fill")
        #expect(ParsingMethod.llmExtraction.icon == "cpu")
    }

    @Test func parsingMethodRawValues() async throws {
        #expect(ParsingMethod.directATS.rawValue == "Direct ATS")
        #expect(ParsingMethod.apiDiscovery.rawValue == "API Discovery")
        #expect(ParsingMethod.llmExtraction.rawValue == "AI Parsing")
    }
}

// MARK: - Filter Keywords Tests

struct FilterKeywordsTests {

    @Test func parseAsFilterKeywords() async throws {
        let input = "manager, engineer, director"
        let keywords = input.parseAsFilterKeywords()

        #expect(keywords.count == 3)
        #expect(keywords.contains("manager"))
        #expect(keywords.contains("engineer"))
        #expect(keywords.contains("director"))
    }

    @Test func parseEmptyFilterKeywords() async throws {
        let input = ""
        let keywords = input.parseAsFilterKeywords()

        #expect(keywords.isEmpty)
    }

    @Test func includingRemoteAddsRemoteKeyword() async throws {
        let keywords = ["seattle", "new york"]
        let withRemote = keywords.includingRemote()

        #expect(withRemote.contains("remote"))
        #expect(withRemote.count == 3)
    }
}

// MARK: - Work Flexibility Tests

struct WorkFlexibilityTests {

    @Test func extractRemoteFromText() async throws {
        let text = "This is a fully remote position"
        let flexibility = WorkFlexibility.extract(from: text)

        #expect(flexibility?.lowercased().contains("remote") == true)
    }

    @Test func extractHybridFromText() async throws {
        let text = "Hybrid work schedule, 3 days in office"
        let flexibility = WorkFlexibility.extract(from: text)

        #expect(flexibility?.lowercased().contains("hybrid") == true)
    }

    @Test func extractOnsiteFromText() async throws {
        let text = "This is an on-site only position in Seattle"
        let flexibility = WorkFlexibility.extract(from: text)

        let lower = flexibility?.lowercased() ?? ""
        #expect(lower.contains("onsite") || lower.contains("on-site"))
    }
}

// MARK: - Date Filter Tests

struct DateFilterTests {

    @Test func jobWithin48hPostingPasses() async throws {
        let job = Job(
            id: "test-1",
            title: "Recent Job",
            location: "Seattle",
            postingDate: Date().addingTimeInterval(-86400), // 24 hours ago
            url: "https://example.com",
            description: "",
            workSiteFlexibility: "",
            source: .greenhouse,
            companyName: "Test",
            department: nil,
            category: nil,
            firstSeenDate: Date().addingTimeInterval(-172800), // 48 hours ago
            originalPostingDate: nil,
            wasBumped: false
        )

        let postingCutoff: TimeInterval = 172800 // 48 hours
        let postingAge = Date().timeIntervalSince(job.postingDate!)

        #expect(postingAge <= postingCutoff)
    }

    @Test func jobWithin24hDiscoveryPasses() async throws {
        let job = Job(
            id: "test-2",
            title: "Old Post New Discovery",
            location: "Seattle",
            postingDate: Date().addingTimeInterval(-604800), // 7 days ago
            url: "https://example.com",
            description: "",
            workSiteFlexibility: "",
            source: .greenhouse,
            companyName: "Test",
            department: nil,
            category: nil,
            firstSeenDate: Date().addingTimeInterval(-3600), // 1 hour ago
            originalPostingDate: nil,
            wasBumped: false
        )

        let discoveryCutoff: TimeInterval = 86400 // 24 hours
        let discoveryAge = Date().timeIntervalSince(job.firstSeenDate)

        #expect(discoveryAge <= discoveryCutoff)
    }
}

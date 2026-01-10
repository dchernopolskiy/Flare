//
//  JobBoardMonitor.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import Foundation
import SwiftUI

@MainActor
class JobBoardMonitor: ObservableObject {
    static let shared = JobBoardMonitor()
    
    @Published var boardConfigs: [JobBoardConfig] = []
    @Published var isMonitoring = false
    @Published var lastError: String?
    @Published var showConfigSheet = false
    @Published var testResults: [UUID: String] = [:]
    @Published var parsingStatus: [UUID: String] = [:]  // Detailed AI parsing status per board
    
    private let persistenceService = PersistenceService.shared
    private let greenhouseFetcher = GreenhouseFetcher()
    private let ashbyFetcher = AshbyFetcher()
    private let leverFetcher = LeverFetcher()
    private let workdayFetcher = WorkdayFetcher()
    private let smartParser = SmartJobParser()
    private var monitorTimer: Timer?
    
    private init() {
        Task {
            await loadConfigs()
        }
    }
    
    func loadConfigs() async {
        do {
            boardConfigs = try await persistenceService.loadBoardConfigs()
        } catch {
            print("[JobBoardMonitor] Failed to load configs: \(error)")
        }
    }

    func saveConfigs() async {
        do {
            try await persistenceService.saveBoardConfigs(boardConfigs)
        } catch {
            print("[JobBoardMonitor] Failed to save configs: \(error)")
        }
    }
    
    func addBoardConfig(_ config: JobBoardConfig) {
        // Prevent duplicates by checking URL
        guard !boardConfigs.contains(where: { $0.url == config.url }) else {
            print("[JobBoardMonitor] Board with URL '\(config.url)' already exists, skipping")
            return
        }

        boardConfigs.append(config)
        Task {
            await saveConfigs()
        }
    }
    
    func removeBoardConfig(at index: Int) {
        // Get the URL before removing to clear the LLM cache for this domain
        let config = boardConfigs[index]
        if let url = URL(string: config.url), let domain = url.host {
            // Clear any cached LLM failure for this domain so re-adding will retry LLM
            Task {
                await APISchemaCache.shared.clearSchema(for: domain)
                print("[JobBoardMonitor] Cleared LLM cache for \(domain)")
            }
        }

        boardConfigs.remove(at: index)
        Task {
            await saveConfigs()
        }
    }
    
    func updateBoardConfig(_ config: JobBoardConfig) {
        if let index = boardConfigs.firstIndex(where: { $0.id == config.id }) {
            boardConfigs[index] = config
            Task {
                await saveConfigs()
            }
        }
    }
    
    func startMonitoring() async {
        monitorTimer?.invalidate()
        
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { [weak self] in
                await self?.fetchAllBoardJobs()
            }
        }
    }
    
    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }
    
    func testSingleBoard(_ config: JobBoardConfig) async {
        testResults[config.id] = "Testing..."

        do {
            let jobs = try await fetchJobsFromBoard(config, titleFilter: "", locationFilter: "")
            testResults[config.id] = "Found \(jobs.count) jobs"

            var updatedConfig = config
            updatedConfig.lastFetched = Date()
            updateBoardConfig(updatedConfig)
        } catch {
            testResults[config.id] = "Error: \(error.localizedDescription)"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.testResults.removeValue(forKey: config.id)
        }
    }
    
    func fetchAllBoardJobs(titleFilter: String = "", locationFilter: String = "") async -> [Job] {
        isMonitoring = true
        lastError = nil
        var allJobs = [Job]()
        var errorMessages = [String]()

        for config in boardConfigs where config.isEnabled && config.isSupported {
            do {
                let jobs = try await fetchJobsFromBoard(config, titleFilter: titleFilter, locationFilter: locationFilter)
                allJobs.append(contentsOf: jobs)

                var updatedConfig = config
                updatedConfig.lastFetched = Date()
                updateBoardConfig(updatedConfig)
            } catch {
                let errorMsg = "\(config.displayName): \(error.localizedDescription)"
                errorMessages.append(errorMsg)
                print("[JobBoard] \(errorMsg)")
            }

            try? await Task.sleep(nanoseconds: FetchDelayConfig.boardFetchDelay)
        }

        if !errorMessages.isEmpty {
            lastError = errorMessages.joined(separator: " | ")
        }

        isMonitoring = false
        return allJobs
    }
    
    // MARK: - Import/Export
    
    func exportBoards() -> String {
        return boardConfigs.map { config in
            "\(config.url) | \(config.name) | \(config.isEnabled ? "enabled" : "disabled")"
        }.joined(separator: "\n")
    }
    
    func importBoards(from content: String) -> (added: Int, failed: [String]) {
        let lines = content.components(separatedBy: .newlines)
        var addedCount = 0
        var failedLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            let parts = trimmed.components(separatedBy: " | ")
            guard parts.count >= 1 else {
                failedLines.append(line)
                continue
            }
            
            let url = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let isEnabled = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "enabled" : true
            
            if let config = JobBoardConfig(name: name, url: url, isEnabled: isEnabled) {
                // Check if already exists
                if !boardConfigs.contains(where: { $0.url == config.url }) {
                    addBoardConfig(config)
                    addedCount += 1
                }
            } else {
                failedLines.append(line)
            }
        }
        
        return (added: addedCount, failed: failedLines)
    }
    
    // MARK: - Private Methods
    
    private func fetchJobsFromBoard(_ config: JobBoardConfig, titleFilter: String, locationFilter: String) async throws -> [Job] {
        guard let url = URL(string: config.url) else {
            throw FetchError.invalidURL
        }

        // Check if we have a previously detected ATS URL (e.g., Workday found via GTM)
        // First check the config, then check the runtime cache
        var detectedATSURL = config.detectedATSURL
        var detectedATSType = config.detectedATSType

        // Check runtime cache if not in config
        var needsPersist = false
        if detectedATSURL == nil, let domain = url.host {
            if let cached = await DetectedATSCache.shared.get(for: domain) {
                detectedATSURL = cached.atsURL
                detectedATSType = cached.atsType
                needsPersist = true  // Found in runtime cache but not in config - need to persist
                print("[JobBoard] Found ATS in runtime cache: \(cached.atsType) at \(cached.atsURL)")
            }
        }

        if let detectedATSURL = detectedATSURL,
           let detectedATSType = detectedATSType,
           let atsURL = URL(string: detectedATSURL) {
            print("[JobBoard] Using cached ATS: \(detectedATSType) at \(detectedATSURL)")
            parsingStatus[config.id] = "Fetching from \(detectedATSType.capitalized)..."

            let jobs: [Job]
            switch detectedATSType.lowercased() {
            case "workday":
                jobs = try await workdayFetcher.fetchJobs(from: atsURL, titleFilter: titleFilter, locationFilter: locationFilter)
            case "greenhouse":
                jobs = try await greenhouseFetcher.fetchGreenhouseJobs(from: atsURL, titleFilter: titleFilter, locationFilter: locationFilter)
            case "lever":
                jobs = try await leverFetcher.fetchJobs(from: atsURL, titleFilter: titleFilter, locationFilter: locationFilter)
            case "ashby":
                jobs = try await ashbyFetcher.fetchJobs(from: atsURL, titleFilter: titleFilter, locationFilter: locationFilter)
            default:
                jobs = []
            }

            if !jobs.isEmpty {
                parsingStatus[config.id] = "Found \(jobs.count) jobs"

                if needsPersist {
                    var updatedConfig = config
                    updatedConfig.detectedATSURL = detectedATSURL
                    updatedConfig.detectedATSType = detectedATSType
                    updateBoardConfig(updatedConfig)
                }

                let configId = config.id
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.parsingStatus.removeValue(forKey: configId)
                }
                return jobs
            } else {
                parsingStatus[config.id] = "No jobs found"
            }
        }

        switch config.source {
        case .greenhouse:
            return try await greenhouseFetcher.fetchGreenhouseJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case .ashby:
            return try await ashbyFetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case .lever:
            return try await leverFetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        case .workday:
            return try await workdayFetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        default:
            // Use SmartJobParser for unknown sources (falls back to LLM if enabled)
            // Pass status callback to show parsing progress
            let configId = config.id
            let jobs = await smartParser.parseJobs(
                from: url,
                titleFilter: titleFilter,
                locationFilter: locationFilter,
                statusCallback: { @MainActor [weak self] status in
                    self?.parsingStatus[configId] = status
                }
            )

            // After parsing, check if we detected an ATS URL and persist it to config
            if !jobs.isEmpty, let domain = url.host {
                if let cached = await DetectedATSCache.shared.get(for: domain) {
                    // Persist detected ATS to config for future refreshes
                    var updatedConfig = config
                    updatedConfig.detectedATSURL = cached.atsURL
                    updatedConfig.detectedATSType = cached.atsType
                    updateBoardConfig(updatedConfig)
                    print("[JobBoard] Persisted detected ATS to config: \(cached.atsType) at \(cached.atsURL)")
                }
            }

            return jobs
        }
    }
}

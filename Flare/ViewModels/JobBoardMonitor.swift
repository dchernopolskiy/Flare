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
    
    private let persistenceService = PersistenceService.shared
    private let greenhouseFetcher = GreenhouseFetcher()
    private let ashbyFetcher = AshbyFetcher()
    private let leverFetcher = LeverFetcher()
    private let workdayFetcher = WorkdayFetcher()
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
        }
    }
    
    func saveConfigs() async {
        do {
            try await persistenceService.saveBoardConfigs(boardConfigs)
        } catch {
        }
    }
    
    func addBoardConfig(_ config: JobBoardConfig) {
        boardConfigs.append(config)
        Task {
            await saveConfigs()
        }
    }
    
    func removeBoardConfig(at index: Int) {
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
            let message = "✅ Found \(jobs.count) jobs"
            testResults[config.id] = message
            
            var updatedConfig = config
            updatedConfig.lastFetched = Date()
            updateBoardConfig(updatedConfig)
            
            
        } catch {
            let message = "❌ Error: \(error.localizedDescription)"
            testResults[config.id] = message
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.testResults.removeValue(forKey: config.id)
        }
    }
    
    func fetchAllBoardJobs(titleFilter: String = "", locationFilter: String = "") async -> [Job] {
        isMonitoring = true
        lastError = nil
        var allJobs: [Job] = []
        var errorMessages: [String] = []
        
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
                print("🌐 [JobBoard] ❌ \(errorMsg)")
            }

            try? await Task.sleep(nanoseconds: FetchDelayConfig.boardFetchDelay)
        }
        
        // Set combined error message if any boards failed
        if !errorMessages.isEmpty {
            lastError = errorMessages.joined(separator: " • ")
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
            let universalFetcher = UniversalJobFetcher()
            return try await universalFetcher.fetchJobs(from: url, titleFilter: titleFilter, locationFilter: locationFilter)
        }
    }
}

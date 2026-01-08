//
//  PersistenceService.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import Foundation
import AppKit

actor PersistenceService {
    static let shared = PersistenceService()
    
    private let appSupportURL: URL
    
    private init() {
        appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flare")
        
        try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
    }
    
    // MARK: - Jobs
    func saveJobs(_ jobs: [Job]) async throws {
        let url = appSupportURL.appendingPathComponent("jobs.json")
        let data = try JSONEncoder().encode(jobs)
        try data.write(to: url)
    }
    
    func loadJobs() async throws -> [Job] {
        let url = appSupportURL.appendingPathComponent("jobs.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Job].self, from: data)
    }
    
    // MARK: - Stored Job IDs
    func saveStoredJobIds(_ ids: Set<String>) async throws {
        let url = appSupportURL.appendingPathComponent("storedIds.json")
        let data = try JSONEncoder().encode(Array(ids))
        try data.write(to: url)
    }
    
    func loadStoredJobIds() async throws -> Set<String> {
        let url = appSupportURL.appendingPathComponent("storedIds.json")
        let data = try Data(contentsOf: url)
        let ids = try JSONDecoder().decode([String].self, from: data)
        return Set(ids)
    }
    
    // MARK: - Applied Job IDs
    func saveAppliedJobIds(_ ids: Set<String>) async throws {
        let url = appSupportURL.appendingPathComponent("appliedJobs.json")
        let data = try JSONEncoder().encode(Array(ids))
        try data.write(to: url)
    }
    
    func loadAppliedJobIds() async throws -> Set<String> {
        let url = appSupportURL.appendingPathComponent("appliedJobs.json")
        let data = try Data(contentsOf: url)
        let ids = try JSONDecoder().decode([String].self, from: data)
        return Set(ids)
    }
    
    // MARK: - Board Configs
    func saveBoardConfigs(_ configs: [JobBoardConfig]) async throws {
        let url = appSupportURL.appendingPathComponent("boardConfigs.json")
        let data = try JSONEncoder().encode(configs)
        try data.write(to: url)
    }
    
    func loadBoardConfigs() async throws -> [JobBoardConfig] {
        let url = appSupportURL.appendingPathComponent("boardConfigs.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([JobBoardConfig].self, from: data)
    }
    
    // MARK: - Source-specific ID tracking
    func saveSourceJobIds(source: JobSource, ids: Set<String>) async throws {
        let url = appSupportURL.appendingPathComponent("\(source.rawValue.lowercased())JobIds.json")
        let data = try JSONEncoder().encode(Array(ids))
        try data.write(to: url)
    }
    
    func loadSourceJobIds(source: JobSource) async throws -> Set<String> {
        let url = appSupportURL.appendingPathComponent("\(source.rawValue.lowercased())JobIds.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Set<String>()
        }
        let data = try Data(contentsOf: url)
        let ids = try JSONDecoder().decode([String].self, from: data)
        return Set(ids)
    }
    
    // MARK: - Favorties
    func saveStarredJobIds(_ ids: Set<String>) async throws {
        let url = appSupportURL.appendingPathComponent("starredJobs.json")
        let data = try JSONEncoder().encode(Array(ids))
        try data.write(to: url)
    }

    func loadStarredJobIds() async throws -> Set<String> {
        let url = appSupportURL.appendingPathComponent("starredJobs.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Set<String>()
        }
        let data = try Data(contentsOf: url)
        let ids = try JSONDecoder().decode([String].self, from: data)
        return Set(ids)
    }
}

// MARK: - Debug files location
extension PersistenceService {
    nonisolated func getDataDirectoryPath() -> String {
        return appSupportURL.path
    }
    
    func openDataDirectoryInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appSupportURL.path)
    }
    
    func getStorageInfo() -> [String: Any] {
        let fileManager = FileManager.default
        var info: [String: Any] = [:]
        
        info["dataDirectory"] = appSupportURL.path
        
        let files = [
            "jobs.json",
            "storedIds.json",
            "appliedJobs.json",
            "starredJobs.json",
            "boardConfigs.json",
            "tiktokJobIds.json",
            "snapJobTracking.json"
        ]
        
        var fileInfo: [String: String] = [:]
        for file in files {
            let url = appSupportURL.appendingPathComponent(file)
            if fileManager.fileExists(atPath: url.path) {
                if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                   let size = attributes[.size] as? Int64 {
                    let formatter = ByteCountFormatter()
                    formatter.countStyle = .file
                    fileInfo[file] = formatter.string(fromByteCount: size)
                }
            } else {
                fileInfo[file] = "Not created yet"
            }
        }
        
        info["files"] = fileInfo
        return info
    }
}

//
//  JobManager.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import SwiftUI
import Foundation
import Combine
import UserNotifications
import AppKit

// MARK: - Delay Configuration
struct FetchDelayConfig {
    static let batchProcessingDelay: UInt64 = 10_000_000 // 10ms
    static let fetchPageDelay: UInt64 = 300_000_000 // 300ms
    static let statusClearDelay: UInt64 = 5_000_000_000 // 5s
    static let boardFetchDelay: UInt64 = 500_000_000 // 500ms
}

@MainActor
class JobManager: ObservableObject {
    static let shared = JobManager()

    // MARK: - Published Properties
    @Published var allJobs: [Job] = [] {
        didSet {
            allJobsSorted = allJobs.sorted { job1, job2 in
                let date1 = job1.postingDate ?? job1.firstSeenDate
                let date2 = job2.postingDate ?? job2.firstSeenDate
                return date1 > date2
            }
            // Invalidate filter cache synchronously to ensure fresh results on next query
            filterCache.invalidate()
            print("[JobManager] allJobs didSet: \(allJobs.count) jobs, cache invalidated")
        }
    }
    private var allJobsSorted: [Job] = []
    @Published var isLoading = false
    @Published var loadingProgress = ""
    @Published var showSettings = false
    @Published var lastError: String?
    @Published var selectedJob: Job?
    @Published var selectedTab = "jobs"
    @Published var newJobsCount = 0
    @Published var appliedJobIds: Set<String> = []
    @Published var fetchStatistics = FetchStatistics()
    @Published var starredJobIds: Set<String> = []
    @Published private var cachedFilteredJobs: [Job] = []
    @Published private var filterCache = FilterCache()
    private var filterCancellable: AnyCancellable?
    
    
    struct FilterCache {
        var lastTitleFilter: String = ""
        var lastLocationFilter: String = ""
        var lastSourceFilter: Set<JobSource> = []
        var cachedJobs: [Job] = []
        var lastComputedDate: Date = .distantPast  // Initialize to distant past so first call computes fresh
        var allJobsSnapshot: [Job] = []

        func isValid(titleFilter: String, locationFilter: String, sources: Set<JobSource>, allJobs: [Job]) -> Bool {
            let filtersMatch = lastTitleFilter == titleFilter &&
                               lastLocationFilter == locationFilter &&
                               lastSourceFilter == sources
            let jobsUnchanged = allJobsSnapshot.count == allJobs.count
            let cacheNotExpired = Date().timeIntervalSince(lastComputedDate) < 5

            // Cache is only valid if ALL conditions match
            return filtersMatch && jobsUnchanged && cacheNotExpired
        }

        mutating func invalidate() {
            allJobsSnapshot = []
            lastComputedDate = .distantPast
        }
    }
    
    func getFilteredJobs(
        titleFilter: String = "",
        locationFilter: String = "",
        sourcesFilter: Set<JobSource> = [],
        showStarred: Bool = false,
        showApplied: Bool = false
    ) -> [Job] {
        print("[JobManager] getFilteredJobs called - titleFilter: '\(titleFilter)', allJobs: \(allJobs.count)")

        if filterCache.isValid(titleFilter: titleFilter, locationFilter: locationFilter, sources: sourcesFilter, allJobs: allJobs) {
            print("[JobManager] Using cached filter results")
            return applyStatusFilters(filterCache.cachedJobs, showStarred: showStarred, showApplied: showApplied)
        }

        var filtered = allJobsSorted
        let beforeDateFilter = filtered.count
        filtered = filtered.filter { job in
            if job.isBumpedRecently {
                return true
            }

            if let postingDate = job.postingDate {
                let diff = Date().timeIntervalSince(postingDate)
                return diff <= 172800 && diff >= 0 // Within 48h and not future-dated
            } else {
                let diff = Date().timeIntervalSince(job.firstSeenDate)
                return diff <= 172800 && diff >= 0
            }
        }
        print("[JobManager] After 48h filter: \(filtered.count) jobs (was \(beforeDateFilter))")

        // Title filter
        if !titleFilter.isEmpty {
            let keywords = titleFilter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            print("[JobManager] Applying title filter with keywords: \(keywords)")
            let beforeTitleFilter = filtered.count
            filtered = filtered.filter { job in
                let jobTitle = job.title.lowercased()
                return keywords.contains { keyword in
                    jobTitle.contains(keyword)
                }
            }
            print("[JobManager] After title filter: \(filtered.count) jobs (was \(beforeTitleFilter))")
        }
        
        // Location filter
        if !locationFilter.isEmpty {
            let keywords = locationFilter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            filtered = filtered.filter { job in
                let jobLocation = job.location.lowercased()
                return keywords.contains { keyword in
                    jobLocation.contains(keyword)
                }
            }
        }
        
        // Source filter
        if !sourcesFilter.isEmpty {
            let beforeSourceFilter = filtered.count
            filtered = filtered.filter { job in
                sourcesFilter.contains(job.source)
            }
            print("[JobManager] After source filter: \(filtered.count) jobs (was \(beforeSourceFilter)), sources: \(sourcesFilter.map { $0.rawValue })")
        } else {
            print("[JobManager] Source filter empty - showing all \(filtered.count) jobs")
        }

        filterCache = FilterCache(
            lastTitleFilter: titleFilter,
            lastLocationFilter: locationFilter,
            lastSourceFilter: sourcesFilter,
            cachedJobs: filtered,
            lastComputedDate: Date(),
            allJobsSnapshot: allJobs
        )
        
        return applyStatusFilters(filtered, showStarred: showStarred, showApplied: showApplied)
    }
    
    private func applyStatusFilters(_ jobs: [Job], showStarred: Bool, showApplied: Bool) -> [Job] {
        var result = jobs
        
        if showStarred {
            result = result.filter { isJobStarred($0) }
        }
        
        if showApplied {
            result = result.filter { isJobApplied($0) }
        }
        
        return result
    }
    
    // MARK: - Batch Processing for Better Performance
    
    func processJobsBatched(_ newJobs: [Job]) async {
        let batchSize = 50
        let batches = stride(from: 0, to: newJobs.count, by: batchSize).map {
            Array(newJobs[$0..<min($0 + batchSize, newJobs.count)])
        }
        
        for (index, batch) in batches.enumerated() {
            await MainActor.run {
                loadingProgress = "Processing batch \(index + 1)/\(batches.count)"
            }
            
            for job in batch {
                storedJobIds.insert(job.id)
            }
            
            try? await Task.sleep(nanoseconds: FetchDelayConfig.batchProcessingDelay)
        }
    }
    
    // MARK: - Settings (Persisted in UserDefaults)
    @Published var jobTitleFilter: String = UserDefaults.standard.string(forKey: "jobTitleFilter") ?? "" {
        didSet { UserDefaults.standard.set(jobTitleFilter, forKey: "jobTitleFilter") }
    }

    @Published var locationFilter: String = UserDefaults.standard.string(forKey: "locationFilter") ?? "" {
        didSet { UserDefaults.standard.set(locationFilter, forKey: "locationFilter") }
    }

    @Published var refreshInterval: Double = {
        let stored = UserDefaults.standard.double(forKey: "refreshInterval")
        return stored > 0 ? stored : 30.0
    }() {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval") }
    }

    @Published var maxPagesToFetch: Int = UserDefaults.standard.object(forKey: "maxPagesToFetch") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(maxPagesToFetch, forKey: "maxPagesToFetch") }
    }

    @Published var enableTikTok: Bool = UserDefaults.standard.bool(forKey: "enableTikTok") {
        didSet { UserDefaults.standard.set(enableTikTok, forKey: "enableTikTok") }
    }

    @Published var enableMicrosoft: Bool = UserDefaults.standard.bool(forKey: "enableMicrosoft") {
        didSet { UserDefaults.standard.set(enableMicrosoft, forKey: "enableMicrosoft") }
    }

    @Published var enableApple: Bool = UserDefaults.standard.bool(forKey: "enableApple") {
        didSet { UserDefaults.standard.set(enableApple, forKey: "enableApple") }
    }

    @Published var enableSnap: Bool = UserDefaults.standard.bool(forKey: "enableSnap") {
        didSet { UserDefaults.standard.set(enableSnap, forKey: "enableSnap") }
    }
    
    @Published var enableMeta: Bool = UserDefaults.standard.bool(forKey: "enableMeta") {
        didSet { UserDefaults.standard.set(enableMeta, forKey: "enableMeta") }
    }
    
    @Published var enableAMD: Bool = UserDefaults.standard.bool(forKey: "enableAMD") {
        didSet { UserDefaults.standard.set(enableAMD, forKey: "enableAMD") }
    }

    @Published var enableGoogle: Bool = UserDefaults.standard.bool(forKey: "enableGoogle") {
        didSet { UserDefaults.standard.set(enableGoogle, forKey: "enableGoogle") }
    }

    @Published var enableCustomBoards: Bool = UserDefaults.standard.object(forKey: "enableCustomBoards") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enableCustomBoards, forKey: "enableCustomBoards") }
    }
    
    @Published var includeRemoteJobs: Bool = UserDefaults.standard.object(forKey: "includeRemoteJobs") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeRemoteJobs, forKey: "includeRemoteJobs") }
    }

    @Published var autoCheckForUpdates: Bool = UserDefaults.standard.object(forKey: "autoCheckForUpdates") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoCheckForUpdates, forKey: "autoCheckForUpdates")
            NotificationCenter.default.post(name: NSNotification.Name("UpdateCheckPreferenceChanged"), object: nil)
        }
    }

    @Published var enableAIParser: Bool = UserDefaults.standard.object(forKey: "enableAIParser") as? Bool ?? false {
        didSet { UserDefaults.standard.set(enableAIParser, forKey: "enableAIParser") }
    }

    // MARK: - Private Properties
    private var fetchTimers: [JobSource: Timer] = [:]
    private var storedJobIds: Set<String> = []
    private var notifiedJobIds: Set<String> = [] // Track jobs we've already notified about
    private let persistenceService = PersistenceService.shared
    private let notificationService = NotificationService.shared
    private var cancellables = Set<AnyCancellable>()
    private var jobsBySource: [JobSource: [Job]] = [:]
    private var wakeObserver: NSObjectProtocol?
    
    // MARK: - Lifecycle
    
    deinit {
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        
        fetchTimers.values.forEach { $0.invalidate() }
        fetchTimers.removeAll()
    }
    
    // MARK: - Fetchers
    private let microsoftFetcher = MicrosoftJobFetcher()
    private let appleFetcher = AppleFetcher()
    private let googleFetcher = GoogleFetcher()
    private let tiktokFetcher = TikTokJobFetcher()
    private let snapFetcher = SnapFetcher()
    private let amdFetcher = AMDFetcher()
    private let metaFetcher = MetaFetcher()
    private let greenhouseFetcher = GreenhouseFetcher()
    
    private init() {
        setupInitialState()
        setupBindings()
        setupWakeNotification()
    }

    // MARK: - Setup
    private func setupInitialState() {
        Task {
            await loadStoredData()
        }
    }

    private func setupBindings() {
        $enableTikTok
            .sink { [weak self] enabled in
                if enabled {
                    self?.startMonitoringSource(.tiktok)
                } else {
                    self?.stopMonitoringSource(.tiktok)
                }
            }
            .store(in: &cancellables)
        
        $enableMicrosoft
            .sink { [weak self] enabled in
                if enabled {
                    self?.startMonitoringSource(.microsoft)
                } else {
                    self?.stopMonitoringSource(.microsoft)
                }
            }
            .store(in: &cancellables)
        
        $enableSnap
            .sink { [weak self] enabled in
                if enabled {
                    self?.startMonitoringSource(.snap)
                } else {
                    self?.stopMonitoringSource(.snap)
                }
            }
            .store(in: &cancellables)
        
        $enableAMD
            .sink { [weak self] enabled in
                if enabled {
                    self?.startMonitoringSource(.amd)
                } else {
                    self?.stopMonitoringSource(.amd)
                }
            }
            .store(in: &cancellables)
        
        $enableMeta
            .sink { [weak self] enabled in
                if enabled {
                    self?.startMonitoringSource(.meta)
                } else {
                    self?.stopMonitoringSource(.meta)
                }
            }
            .store(in: &cancellables)

        $enableApple
            .sink { [weak self] enabled in
                if enabled {
                    self?.startMonitoringSource(.apple)
                } else {
                    self?.stopMonitoringSource(.apple)
                }
            }
            .store(in: &cancellables)

        $enableGoogle
            .sink { [weak self] enabled in
                if enabled {
                    self?.startMonitoringSource(.google)
                } else {
                    self?.stopMonitoringSource(.google)
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    func startMonitoring() async {

        if allJobs.isEmpty {
            await loadStoredData()
        }

        await fetchAllJobs()

        if enableMicrosoft {
            startMonitoringSource(.microsoft)
        }
        if enableApple {
            startMonitoringSource(.apple)
        }
        if enableTikTok {
            startMonitoringSource(.tiktok)
        }
        if enableSnap {
            startMonitoringSource(.snap)
        }
        if enableAMD {
            startMonitoringSource(.amd)
        }

        if enableMeta {
            startMonitoringSource(.meta)
        }
        if enableGoogle {
            startMonitoringSource(.google)
        }
        if enableCustomBoards {
            await JobBoardMonitor.shared.startMonitoring()
        }
    }
    
    func stopMonitoring() {
        fetchTimers.values.forEach { $0.invalidate() }
        fetchTimers.removeAll()
    }
    
    func fetchAllJobs() async {
        isLoading = true
        lastError = nil
        newJobsCount = 0
        fetchStatistics = FetchStatistics()
        let tracker = FetchStatusTracker.shared
        
        var allNewJobs: [Job] = []
        var sourceJobsMap: [JobSource: [Job]] = [:]
        
        // MARK: - Fetch from all enabled sources
        
        if enableMicrosoft {
            tracker.startFetch(source: "Microsoft")
            do {
                let jobs = try await fetchFromSource(.microsoft)
                sourceJobsMap[.microsoft] = jobs
                let newJobs = filterNewJobs(jobs)
                allNewJobs.append(contentsOf: newJobs)
                fetchStatistics.microsoftJobs = jobs.count
                tracker.successFetch(source: "Microsoft", jobCount: jobs.count)
                
                Task {
                    try? await Task.sleep(nanoseconds: FetchDelayConfig.statusClearDelay)
                    tracker.clearStatus(source: "Microsoft")
                }
            } catch {
                print("[Microsoft] Error: \(error)")
                lastError = "Microsoft: \(error.localizedDescription)"
                tracker.failedFetch(source: "Microsoft", error: error)
                
                if let existingJobs = jobsBySource[.microsoft] {
                    sourceJobsMap[.microsoft] = existingJobs
                }
            }
        } else {
            sourceJobsMap[.microsoft] = jobsBySource[.microsoft] ?? []
        }
        
        if enableTikTok {
            tracker.startFetch(source: "TikTok")
            do {
                let jobs = try await fetchFromSource(.tiktok)
                sourceJobsMap[.tiktok] = jobs
                let newJobs = filterNewJobs(jobs)
                allNewJobs.append(contentsOf: newJobs)
                fetchStatistics.tiktokJobs = jobs.count
                tracker.successFetch(source: "TikTok", jobCount: jobs.count)
                
                Task {
                    try? await Task.sleep(nanoseconds: FetchDelayConfig.statusClearDelay)
                    tracker.clearStatus(source: "TikTok")
                }
            } catch {
                print("[TikTok] Error: \(error)")
                lastError = "TikTok: \(error.localizedDescription)"
                tracker.failedFetch(source: "TikTok", error: error)
                
                if let existingJobs = jobsBySource[.tiktok] {
                    sourceJobsMap[.tiktok] = existingJobs
                }
            }
        } else {
            sourceJobsMap[.tiktok] = jobsBySource[.tiktok] ?? []
        }
        
        if enableSnap {
            tracker.startFetch(source: "Snap")
            do {
                let jobs = try await fetchFromSource(.snap)
                sourceJobsMap[.snap] = jobs
                let newJobs = filterNewJobs(jobs)
                allNewJobs.append(contentsOf: newJobs)
                tracker.successFetch(source: "Snap", jobCount: jobs.count)
                
                Task {
                    try? await Task.sleep(nanoseconds: FetchDelayConfig.statusClearDelay)
                    tracker.clearStatus(source: "Snap")
                }
            } catch {
                print("[Snap] Error: \(error)")
                lastError = "Snap: \(error.localizedDescription)"
                tracker.failedFetch(source: "Snap", error: error)
                
                if let existingJobs = jobsBySource[.snap] {
                    sourceJobsMap[.snap] = existingJobs
                }
            }
        } else {
            sourceJobsMap[.snap] = jobsBySource[.snap] ?? []
        }
        
        if enableAMD {
            tracker.startFetch(source: "AMD")
            do {
                let jobs = try await fetchFromSource(.amd)
                sourceJobsMap[.amd] = jobs
                let newJobs = filterNewJobs(jobs)
                allNewJobs.append(contentsOf: newJobs)
                fetchStatistics.amdJobs = jobs.count
                tracker.successFetch(source: "AMD", jobCount: jobs.count)
                
                Task {
                    try? await Task.sleep(nanoseconds: FetchDelayConfig.statusClearDelay)
                    tracker.clearStatus(source: "AMD")
                }
            } catch {
                print("[AMD] Error: \(error)")
                lastError = "AMD: \(error.localizedDescription)"
                tracker.failedFetch(source: "AMD", error: error)
                
                if let existingJobs = jobsBySource[.amd] {
                    sourceJobsMap[.amd] = existingJobs
                }
            }
        } else {
            sourceJobsMap[.amd] = jobsBySource[.amd] ?? []
        }
        
        if enableMeta {
            tracker.startFetch(source: "Meta")
            do {
                let jobs = try await fetchFromSource(.meta)
                sourceJobsMap[.meta] = jobs
                let newJobs = filterNewJobs(jobs)
                allNewJobs.append(contentsOf: newJobs)
                tracker.successFetch(source: "Meta", jobCount: jobs.count)

                Task {
                    try? await Task.sleep(nanoseconds: FetchDelayConfig.statusClearDelay)
                    tracker.clearStatus(source: "Meta")
                }
            } catch {
                print("[Meta] Error: \(error)")
                lastError = "Meta: \(error.localizedDescription)"
                tracker.failedFetch(source: "Meta", error: error)

                if let existingJobs = jobsBySource[.meta] {
                    sourceJobsMap[.meta] = existingJobs
                }
            }
        } else {
            sourceJobsMap[.meta] = jobsBySource[.meta] ?? []
        }

        // Apple
        if enableApple {
            tracker.startFetch(source: "Apple")
            do {
                let jobs = try await fetchFromSource(.apple)
                sourceJobsMap[.apple] = jobs
                let newJobs = filterNewJobs(jobs)
                allNewJobs.append(contentsOf: newJobs)
                fetchStatistics.appleJobs = jobs.count
                tracker.successFetch(source: "Apple", jobCount: jobs.count)

                Task {
                    try? await Task.sleep(nanoseconds: FetchDelayConfig.statusClearDelay)
                    tracker.clearStatus(source: "Apple")
                }
            } catch {
                print("[Apple] Error: \(error)")
                lastError = "Apple: \(error.localizedDescription)"
                tracker.failedFetch(source: "Apple", error: error)

                if let existingJobs = jobsBySource[.apple] {
                    sourceJobsMap[.apple] = existingJobs
                }
            }
        } else {
            sourceJobsMap[.apple] = jobsBySource[.apple] ?? []
        }

        // Google
        if enableGoogle {
            tracker.startFetch(source: "Google")
            do {
                let jobs = try await fetchFromSource(.google)
                sourceJobsMap[.google] = jobs
                let newJobs = filterNewJobs(jobs)
                allNewJobs.append(contentsOf: newJobs)
                fetchStatistics.googleJobs = jobs.count
                tracker.successFetch(source: "Google", jobCount: jobs.count)

                Task {
                    try? await Task.sleep(nanoseconds: FetchDelayConfig.statusClearDelay)
                    tracker.clearStatus(source: "Google")
                }
            } catch {
                print("[Google] Error: \(error)")
                lastError = "Google: \(error.localizedDescription)"
                tracker.failedFetch(source: "Google", error: error)

                if let existingJobs = jobsBySource[.google] {
                    sourceJobsMap[.google] = existingJobs
                }
            }
        } else {
            sourceJobsMap[.google] = jobsBySource[.google] ?? []
        }

        // Custom Boards
        if enableCustomBoards {
            tracker.startFetch(source: "Custom Boards")
            let customJobs = await JobBoardMonitor.shared.fetchAllBoardJobs(
                titleFilter: jobTitleFilter,
                locationFilter: locationFilter
            )

            // Group custom jobs by their source and add to sourceJobsMap
            let customJobsBySource = Dictionary(grouping: customJobs) { $0.source }
            for (source, jobs) in customJobsBySource {
                if sourceJobsMap[source] != nil {
                    sourceJobsMap[source]?.append(contentsOf: jobs)
                } else {
                    sourceJobsMap[source] = jobs
                }
            }

            let newJobs = filterNewJobs(customJobs)
            allNewJobs.append(contentsOf: newJobs)
            fetchStatistics.customBoardJobs = customJobs.count
            tracker.successFetch(source: "Custom Boards", jobCount: customJobs.count)

            // Propagate job board errors to main error display (including nil to clear)
            let boardError = await JobBoardMonitor.shared.lastError
            if let boardError = boardError {
                lastError = boardError
            } else if lastError?.contains("Custom Boards") == true || lastError?.contains(":") == true {
                // Clear error if it was from a job board and boards are now successful
                lastError = nil
            }

            Task {
                try? await Task.sleep(nanoseconds: FetchDelayConfig.statusClearDelay)
                tracker.clearStatus(source: "Custom Boards")
            }
        }
        
        await processNewJobs(allNewJobs, sourceJobsMap: sourceJobsMap)
        isLoading = false
    }
    
    func selectJob(withId id: String) {
        if let job = allJobs.first(where: { $0.id == id }) {
            selectedJob = job
            selectedTab = "jobs"
        }
    }
    
    func openJob(_ job: Job) {
        if let url = URL(string: job.url) {
            appliedJobIds.insert(job.id)
            Task {
                try await persistenceService.saveAppliedJobIds(appliedJobIds)
            }
            NSWorkspace.shared.open(url)
        }
    }
    
    func toggleAppliedStatus(for job: Job) {
        if appliedJobIds.contains(job.id) {
            appliedJobIds.remove(job.id)
        } else {
            appliedJobIds.insert(job.id)
        }
        Task {
            try await persistenceService.saveAppliedJobIds(appliedJobIds)
        }
    }
    
    func toggleStarred(for job: Job) {
        if starredJobIds.contains(job.id) {
            starredJobIds.remove(job.id)
        } else {
            starredJobIds.insert(job.id)
        }
        Task {
            try await persistenceService.saveStarredJobIds(starredJobIds)
        }
    }

    func isJobStarred(_ job: Job) -> Bool {
        return starredJobIds.contains(job.id)
    }
    
    func isJobApplied(_ job: Job) -> Bool {
        return appliedJobIds.contains(job.id)
    }
    
    // MARK: - Private Methods
    private func startMonitoringSource(_ source: JobSource) {
        fetchTimers[source]?.invalidate()
        
        let interval = refreshInterval * 60
        
        fetchTimers[source] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { [weak self] in
                await self?.fetchJobsFromSource(source)
            }
        }
        
    }
    
    private func stopMonitoringSource(_ source: JobSource) {
        fetchTimers[source]?.invalidate()
        fetchTimers.removeValue(forKey: source)
    }
    
    private func setupWakeNotification() {
        // Listen for Mac wake events
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            print("Mac woke up - triggering job refresh")
            Task {
                await self.fetchAllJobs()
            }
        }
    }
    
    private func fetchFromSource(_ source: JobSource) async throws -> [Job] {
        let titleKeywords = parseTitleKeywords()
        
        loadingProgress = "Fetching from \(source.rawValue)..."
        
        switch source {
        case .microsoft:
            return try await microsoftFetcher.fetchJobs(
                titleKeywords: titleKeywords,
                location: locationFilter,
                maxPages: max(1, Int(maxPagesToFetch))
            )
        case .tiktok:
            return try await tiktokFetcher.fetchJobs(
                titleKeywords: titleKeywords,
                location: locationFilter,
                maxPages: max(1, 350)  // Fetch more pages for TikTok since no dates
            )
        case .snap:
             return try await snapFetcher.fetchJobs(
                 titleKeywords: titleKeywords,
                 location: locationFilter,
                 maxPages: max(1, Int(maxPagesToFetch))
             )
        case .amd:
             return try await amdFetcher.fetchJobs(
                 titleKeywords: titleKeywords,
                 location: locationFilter,
                 maxPages: max(1, Int(maxPagesToFetch))
             )
        case .meta:
            return try await metaFetcher.fetchJobs(
                titleKeywords: titleKeywords,
                location: locationFilter,
                maxPages: max(1, Int(maxPagesToFetch))
            )
        case .google:
            let baseURL = URL(string: "https://www.google.com/about/careers/applications/jobs/results")!
            return try await googleFetcher.fetchJobs(
                from: baseURL,
                titleFilter: titleKeywords.joined(separator: " "),
                locationFilter: locationFilter
            )
        case .apple:
            return try await appleFetcher.fetchJobs(
                titleKeywords: titleKeywords,
                location: locationFilter,
                maxPages: max(1, Int(maxPagesToFetch))
            )
        case .greenhouse:
            return []
        default:
            throw FetchError.notImplemented(source.rawValue)
        }
    }
    
    private func fetchJobsFromSource(_ source: JobSource) async {
        do {
            let jobs = try await fetchFromSource(source)
            
            jobsBySource[source] = jobs
            var sourceJobsMap = jobsBySource
            let newJobs = filterNewJobs(jobs)
            
            if !newJobs.isEmpty {
                await processNewJobs(newJobs, sourceJobsMap: sourceJobsMap)
            }
        } catch {
        }
    }
    
    private func filterNewJobs(_ jobs: [Job]) -> [Job] {
        return jobs.filter { job in
            // Include if this is a truly new job ID
            if !storedJobIds.contains(job.id) {
                return true
            }
            
            // Also include if this is a recently bumped job (even if we've seen the ID before)
            if job.isBumpedRecently {
                return true
            }
            
            return false
        }
    }
    
    private func processNewJobs(_ newJobs: [Job], sourceJobsMap: [JobSource: [Job]]) async {
        newJobs.forEach { storedJobIds.insert($0.id) }
        
        var combinedJobs: [Job] = []
        for (_, sourceJobs) in sourceJobsMap {
            combinedJobs.append(contentsOf: sourceJobs)
        }
        
        var uniqueJobs: [Job] = []
        var seenIds = Set<String>()
        
        for job in combinedJobs {
            if !seenIds.contains(job.id) {
                uniqueJobs.append(job)
                seenIds.insert(job.id)
            }
        }

        // No need to sort here - allJobs didSet will handle sorting automatically
        allJobs = uniqueJobs
        newJobsCount = newJobs.count
        
        fetchStatistics.totalJobs = uniqueJobs.count
        fetchStatistics.newJobs = newJobsCount
        fetchStatistics.lastFetchTime = Date()
        
        if !newJobs.isEmpty {
            let recentNewJobs = newJobs.filter { job in
                // Only notify about jobs with valid posting dates within 2 hours
                // This prevents mass notifications when first adding a job board
                if let postingDate = job.postingDate {
                    return Date().timeIntervalSince(postingDate) <= 7200 // 2 hours
                } else {
                    // For jobs without posting dates, only notify if we've seen them before
                    // (i.e., firstSeenDate is not from this fetch cycle)
                    let timeSinceFirstSeen = Date().timeIntervalSince(job.firstSeenDate)
                    // If firstSeenDate is within the last minute, it's from this fetch - don't notify
                    return timeSinceFirstSeen > 60 && timeSinceFirstSeen <= 7200
                }
            }

            // Filter out jobs we've already sent notifications for
            let jobsToNotify = recentNewJobs.filter { !notifiedJobIds.contains($0.id) }

            if !jobsToNotify.isEmpty {
                await notificationService.sendGroupedNotification(for: jobsToNotify)
                // Mark these jobs as notified
                jobsToNotify.forEach { notifiedJobIds.insert($0.id) }
            }
        }
        
        try? await persistenceService.saveJobs(allJobs)
        try? await persistenceService.saveStoredJobIds(storedJobIds)
        
        loadingProgress = ""
        
        for (source, jobs) in sourceJobsMap {
            if !jobs.isEmpty {
            }
        }
    }
    
    private func loadStoredData() async {
        do {
            let loadedJobs = try await persistenceService.loadJobs()
            
            jobsBySource = Dictionary(grouping: loadedJobs) { $0.source }
                .mapValues { Array($0) }
            
            allJobs = loadedJobs
            
            storedJobIds = try await persistenceService.loadStoredJobIds()
            appliedJobIds = try await persistenceService.loadAppliedJobIds()
            starredJobIds = try await persistenceService.loadStarredJobIds()
            
            for (source, jobs) in jobsBySource {
            }
        } catch {
        }
    }
    
    private func parseTitleKeywords() -> [String] {
        guard !jobTitleFilter.isEmpty else { return [] }
        return jobTitleFilter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Fetch Statistics
struct FetchStatistics {
    var totalJobs: Int = 0
    var newJobs: Int = 0
    var microsoftJobs: Int = 0
    var appleJobs: Int = 0
    var googleJobs: Int = 0
    var tiktokJobs: Int = 0
    var snapJobs: Int = 0
    var metaJobs: Int = 0
    var amdJobs: Int = 0
    var customBoardJobs: Int = 0
    var lastFetchTime: Date?
    
    var summary: String {
        var parts: [String] = []
        
        if microsoftJobs > 0 {
            parts.append("Microsoft: \(microsoftJobs)")
        }
        if appleJobs > 0 {
            parts.append("Apple: \(appleJobs)")
        }
        if googleJobs > 0 {
            parts.append("Google: \(googleJobs)")
        }
        if tiktokJobs > 0 {
            parts.append("TikTok: \(tiktokJobs)")
        }
        if snapJobs > 0 {
            parts.append("Snap: \(snapJobs)")
        }
        if metaJobs > 0 {
            parts.append("Meta: \(metaJobs)")
        }
        if amdJobs > 0 {
            parts.append("AMD: \(amdJobs)")
        }
        if customBoardJobs > 0 {
            parts.append("Boards: \(customBoardJobs)")
        }
        
        if parts.isEmpty {
            return "No jobs found"
        }
        
        return parts.joined(separator: " • ")
    }
}

extension JobManager {
    
    func cleanupOldJobs() async {
        let cutoffDate = Date().addingTimeInterval(-7 * 24 * 3600) // 7 days
        
        await MainActor.run {
            // Remove jobs older than 7 days that aren't starred or applied
            allJobs = allJobs.filter { job in
                let jobDate = job.postingDate ?? job.firstSeenDate
                let isRecent = jobDate > cutoffDate
                let isImportant = isJobStarred(job) || isJobApplied(job)
                
                return isRecent || isImportant
            }
            
            let currentIds = Set(allJobs.map { $0.id })
            storedJobIds = storedJobIds.intersection(currentIds)
        }
        
        try? await persistenceService.saveJobs(allJobs)
        try? await persistenceService.saveStoredJobIds(storedJobIds)
    }
    
    func scheduleCleanup() {
        Task {
            while true {
                await cleanupOldJobs()
                try? await Task.sleep(nanoseconds: 24 * 3600 * 1_000_000_000) // Daily
            }
        }
    }
}

// MARK: - Incremental Loading for Large Result Sets

extension JobManager {
    
    func loadJobsIncremental() async {
        isLoading = true
        
        if let persistedJobs = try? await persistenceService.loadJobs() {
            await MainActor.run {
                allJobs = persistedJobs
                loadingProgress = "Loaded \(persistedJobs.count) cached jobs"
            }
        }
        
        await fetchAllJobs()
        
        isLoading = false
    }
}

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

// MARK: - Source Configuration
private struct SourceConfig {
    let source: JobSource
    let name: String
    let enabledKeyPath: KeyPath<JobManager, Bool>
    let statisticsKeyPath: WritableKeyPath<FetchStatistics, Int>?
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
            filterCacheValid = false
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

    // Simple cache invalidation flag instead of over-engineered FilterCache
    private var filterCacheValid = false
    private var cachedFilteredJobs: [Job] = []
    private var lastFilterParams: (title: String, location: String, sources: Set<JobSource>) = ("", "", [])

    func getFilteredJobs(
        titleFilter: String = "",
        locationFilter: String = "",
        sourcesFilter: Set<JobSource> = [],
        showStarred: Bool = false,
        showApplied: Bool = false
    ) -> [Job] {
        let paramsMatch = lastFilterParams == (titleFilter, locationFilter, sourcesFilter)
        if filterCacheValid && paramsMatch {
            return applyStatusFilters(cachedFilteredJobs, showStarred: showStarred, showApplied: showApplied)
        }

        var filtered = allJobsSorted

        // 48h date filter
        let cutoff: TimeInterval = 172800
        filtered = filtered.filter { job in
            if job.isBumpedRecently { return true }
            if Date().timeIntervalSince(job.firstSeenDate) <= cutoff { return true }
            if let postingDate = job.postingDate, Date().timeIntervalSince(postingDate) <= cutoff { return true }
            return false
        }

        // Title filter
        if !titleFilter.isEmpty {
            let keywords = titleFilter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            filtered = filtered.filter { job in
                let title = job.title.lowercased()
                return keywords.contains { title.contains($0) }
            }
        }

        // Location filter
        if !locationFilter.isEmpty {
            let keywords = locationFilter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            filtered = filtered.filter { job in
                let location = job.location.lowercased()
                return keywords.contains { location.contains($0) }
            }
        }

        // Source filter
        if !sourcesFilter.isEmpty {
            filtered = filtered.filter { sourcesFilter.contains($0.source) }
        }

        cachedFilteredJobs = filtered
        lastFilterParams = (titleFilter, locationFilter, sourcesFilter)
        filterCacheValid = true

        return applyStatusFilters(filtered, showStarred: showStarred, showApplied: showApplied)
    }

    private func applyStatusFilters(_ jobs: [Job], showStarred: Bool, showApplied: Bool) -> [Job] {
        var result = jobs
        if showStarred { result = result.filter { starredJobIds.contains($0.id) } }
        if showApplied { result = result.filter { appliedJobIds.contains($0.id) } }
        return result
    }

    // MARK: - Batch Processing
    func processJobsBatched(_ newJobs: [Job]) async {
        let batchSize = 50
        let batches = stride(from: 0, to: newJobs.count, by: batchSize).map {
            Array(newJobs[$0..<min($0 + batchSize, newJobs.count)])
        }

        for (index, batch) in batches.enumerated() {
            loadingProgress = "Processing batch \(index + 1)/\(batches.count)"
            batch.forEach { storedJobIds.insert($0.id) }
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
    private var notifiedJobIds: Set<String> = []
    private let persistenceService = PersistenceService.shared
    private let notificationService = NotificationService.shared
    private var cancellables = Set<AnyCancellable>()
    private var jobsBySource: [JobSource: [Job]] = [:]
    private var wakeObserver: NSObjectProtocol?

    // Source toggle bindings - maps source to its enable publisher
    private lazy var sourceBindings: [(source: JobSource, publisher: Published<Bool>.Publisher)] = [
        (.tiktok, $enableTikTok),
        (.microsoft, $enableMicrosoft),
        (.snap, $enableSnap),
        (.amd, $enableAMD),
        (.meta, $enableMeta),
        (.apple, $enableApple),
        (.google, $enableGoogle)
    ]

    // MARK: - Lifecycle
    deinit {
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        fetchTimers.values.forEach { $0.invalidate() }
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
        Task { await loadStoredData() }
    }

    private func setupBindings() {
        for binding in sourceBindings {
            binding.publisher
                .sink { [weak self] enabled in
                    if enabled {
                        self?.startMonitoringSource(binding.source)
                    } else {
                        self?.stopMonitoringSource(binding.source)
                    }
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Public Methods
    func startMonitoring() async {
        if allJobs.isEmpty {
            await loadStoredData()
        }

        await fetchAllJobs()

        let sources: [(enabled: Bool, source: JobSource)] = [
            (enableMicrosoft, .microsoft),
            (enableApple, .apple),
            (enableTikTok, .tiktok),
            (enableSnap, .snap),
            (enableAMD, .amd),
            (enableMeta, .meta),
            (enableGoogle, .google)
        ]

        for (enabled, source) in sources where enabled {
            startMonitoringSource(source)
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

        var allNewJobs: [Job] = []
        var sourceJobsMap: [JobSource: [Job]] = [:]

        // Define sources with their configurations
        let sources: [(source: JobSource, name: String, enabled: Bool, statsPath: WritableKeyPath<FetchStatistics, Int>?)] = [
            (.microsoft, "Microsoft", enableMicrosoft, \.microsoftJobs),
            (.tiktok, "TikTok", enableTikTok, \.tiktokJobs),
            (.snap, "Snap", enableSnap, nil),
            (.amd, "AMD", enableAMD, \.amdJobs),
            (.meta, "Meta", enableMeta, nil),
            (.apple, "Apple", enableApple, \.appleJobs),
            (.google, "Google", enableGoogle, \.googleJobs)
        ]

        for config in sources {
            let result = await fetchSourceJobs(
                source: config.source,
                name: config.name,
                enabled: config.enabled,
                statsPath: config.statsPath
            )
            sourceJobsMap[config.source] = result.jobs
            allNewJobs.append(contentsOf: result.newJobs)
        }

        // Custom Boards
        if enableCustomBoards {
            let tracker = FetchStatusTracker.shared
            tracker.startFetch(source: "Custom Boards")

            let customJobs = await JobBoardMonitor.shared.fetchAllBoardJobs(
                titleFilter: jobTitleFilter,
                locationFilter: locationFilter
            )

            let customJobsBySource = Dictionary(grouping: customJobs) { $0.source }
            for (source, jobs) in customJobsBySource {
                if sourceJobsMap[source] != nil {
                    sourceJobsMap[source]?.append(contentsOf: jobs)
                } else {
                    sourceJobsMap[source] = jobs
                }
            }

            allNewJobs.append(contentsOf: filterNewJobs(customJobs))
            fetchStatistics.customBoardJobs = customJobs.count
            tracker.successFetch(source: "Custom Boards", jobCount: customJobs.count)

            if let boardError = await JobBoardMonitor.shared.lastError {
                lastError = boardError
            } else if lastError?.contains("Custom Boards") == true || lastError?.contains(":") == true {
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

    /// Fetches jobs from a single source with tracking and error handling
    private func fetchSourceJobs(
        source: JobSource,
        name: String,
        enabled: Bool,
        statsPath: WritableKeyPath<FetchStatistics, Int>?
    ) async -> (jobs: [Job], newJobs: [Job]) {
        guard enabled else {
            return (jobsBySource[source] ?? [], [])
        }

        let tracker = FetchStatusTracker.shared
        tracker.startFetch(source: name)

        do {
            let jobs = try await fetchFromSource(source)
            let newJobs = filterNewJobs(jobs)

            if let path = statsPath {
                fetchStatistics[keyPath: path] = jobs.count
            }
            tracker.successFetch(source: name, jobCount: jobs.count)

            Task {
                try? await Task.sleep(nanoseconds: FetchDelayConfig.statusClearDelay)
                tracker.clearStatus(source: name)
            }

            return (jobs, newJobs)
        } catch {
            print("[\(name)] Error: \(error)")
            lastError = "\(name): \(error.localizedDescription)"
            tracker.failedFetch(source: name, error: error)
            return (jobsBySource[source] ?? [], [])
        }
    }

    func selectJob(withId id: String) {
        if let job = allJobs.first(where: { $0.id == id }) {
            selectedJob = job
            selectedTab = "jobs"
        }
    }

    func openJob(_ job: Job) {
        guard let url = URL(string: job.url) else { return }
        appliedJobIds.insert(job.id)
        Task { try? await persistenceService.saveAppliedJobIds(appliedJobIds) }
        NSWorkspace.shared.open(url)
    }

    func toggleAppliedStatus(for job: Job) {
        if appliedJobIds.contains(job.id) {
            appliedJobIds.remove(job.id)
        } else {
            appliedJobIds.insert(job.id)
        }
        Task { try? await persistenceService.saveAppliedJobIds(appliedJobIds) }
    }

    func toggleStarred(for job: Job) {
        if starredJobIds.contains(job.id) {
            starredJobIds.remove(job.id)
        } else {
            starredJobIds.insert(job.id)
        }
        Task { try? await persistenceService.saveStarredJobIds(starredJobIds) }
    }

    func isJobStarred(_ job: Job) -> Bool {
        starredJobIds.contains(job.id)
    }

    func isJobApplied(_ job: Job) -> Bool {
        appliedJobIds.contains(job.id)
    }

    // MARK: - Private Methods
    private func startMonitoringSource(_ source: JobSource) {
        fetchTimers[source]?.invalidate()
        let interval = refreshInterval * 60

        fetchTimers[source] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.fetchJobsFromSource(source) }
        }
    }

    private func stopMonitoringSource(_ source: JobSource) {
        fetchTimers[source]?.invalidate()
        fetchTimers.removeValue(forKey: source)
    }

    private func setupWakeNotification() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            print("Mac woke up - triggering job refresh")
            Task { await self.fetchAllJobs() }
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
                maxPages: max(1, maxPagesToFetch)
            )
        case .tiktok:
            return try await tiktokFetcher.fetchJobs(
                titleKeywords: titleKeywords,
                location: locationFilter,
                maxPages: 350
            )
        case .snap:
            return try await snapFetcher.fetchJobs(
                titleKeywords: titleKeywords,
                location: locationFilter,
                maxPages: max(1, maxPagesToFetch)
            )
        case .amd:
            return try await amdFetcher.fetchJobs(
                titleKeywords: titleKeywords,
                location: locationFilter,
                maxPages: max(1, maxPagesToFetch)
            )
        case .meta:
            return try await metaFetcher.fetchJobs(
                titleKeywords: titleKeywords,
                location: locationFilter,
                maxPages: max(1, maxPagesToFetch)
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
                maxPages: max(1, maxPagesToFetch)
            )
        case .greenhouse:
            return []
        default:
            throw FetchError.notImplemented(source.rawValue)
        }
    }

    private func fetchJobsFromSource(_ source: JobSource) async {
        guard let jobs = try? await fetchFromSource(source) else { return }

        jobsBySource[source] = jobs
        let newJobs = filterNewJobs(jobs)

        if !newJobs.isEmpty {
            await processNewJobs(newJobs, sourceJobsMap: jobsBySource)
        }
    }

    private func filterNewJobs(_ jobs: [Job]) -> [Job] {
        jobs.filter { !storedJobIds.contains($0.id) || $0.isBumpedRecently }
    }

    private func processNewJobs(_ newJobs: [Job], sourceJobsMap: [JobSource: [Job]]) async {
        newJobs.forEach { storedJobIds.insert($0.id) }

        // Combine and deduplicate
        var seenIds = Set<String>()
        var uniqueJobs: [Job] = []
        for jobs in sourceJobsMap.values {
            for job in jobs where !seenIds.contains(job.id) {
                uniqueJobs.append(job)
                seenIds.insert(job.id)
            }
        }

        allJobs = uniqueJobs
        newJobsCount = newJobs.count

        fetchStatistics.totalJobs = uniqueJobs.count
        fetchStatistics.newJobs = newJobsCount
        fetchStatistics.lastFetchTime = Date()

        if !newJobs.isEmpty {
            await sendNotificationsForNewJobs(newJobs)
        }

        try? await persistenceService.saveJobs(allJobs)
        try? await persistenceService.saveStoredJobIds(storedJobIds)
        loadingProgress = ""
    }

    private func sendNotificationsForNewJobs(_ newJobs: [Job]) async {
        let jobsBySourceCompany = Dictionary(grouping: newJobs) { "\($0.source.rawValue)-\($0.companyName ?? "unknown")" }

        let recentNewJobs = newJobs.filter { job in
            if let postingDate = job.postingDate {
                return Date().timeIntervalSince(postingDate) <= 7200
            } else {
                let sourceKey = "\(job.source.rawValue)-\(job.companyName ?? "unknown")"
                let sourceJobCount = jobsBySourceCompany[sourceKey]?.count ?? 0
                if sourceJobCount > 10 { return false }

                let timeSinceFirstSeen = Date().timeIntervalSince(job.firstSeenDate)
                return timeSinceFirstSeen > 60 && timeSinceFirstSeen <= 7200
            }
        }

        let jobsToNotify = recentNewJobs.filter { !notifiedJobIds.contains($0.id) }

        if !jobsToNotify.isEmpty {
            await notificationService.sendGroupedNotification(for: jobsToNotify)
            jobsToNotify.forEach { notifiedJobIds.insert($0.id) }
        }
    }

    private func loadStoredData() async {
        do {
            let loadedJobs = try await persistenceService.loadJobs()
            jobsBySource = Dictionary(grouping: loadedJobs) { $0.source }
            allJobs = loadedJobs
            storedJobIds = try await persistenceService.loadStoredJobIds()
            appliedJobIds = try await persistenceService.loadAppliedJobIds()
            starredJobIds = try await persistenceService.loadStarredJobIds()
        } catch {
            print("Failed to load stored data: \(error)")
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
    var totalJobs = 0
    var newJobs = 0
    var microsoftJobs = 0
    var appleJobs = 0
    var googleJobs = 0
    var tiktokJobs = 0
    var snapJobs = 0
    var metaJobs = 0
    var amdJobs = 0
    var customBoardJobs = 0
    var lastFetchTime: Date?

    private static let sourceLabels: [(keyPath: KeyPath<FetchStatistics, Int>, label: String)] = [
        (\.microsoftJobs, "Microsoft"),
        (\.appleJobs, "Apple"),
        (\.googleJobs, "Google"),
        (\.tiktokJobs, "TikTok"),
        (\.snapJobs, "Snap"),
        (\.metaJobs, "Meta"),
        (\.amdJobs, "AMD"),
        (\.customBoardJobs, "Boards")
    ]

    var summary: String {
        let parts = Self.sourceLabels.compactMap { config -> String? in
            let count = self[keyPath: config.keyPath]
            return count > 0 ? "\(config.label): \(count)" : nil
        }
        return parts.isEmpty ? "No jobs found" : parts.joined(separator: " • ")
    }
}

// MARK: - Cleanup
extension JobManager {
    func cleanupOldJobs() async {
        let cutoffDate = Date().addingTimeInterval(-7 * 24 * 3600)

        allJobs = allJobs.filter { job in
            let jobDate = job.postingDate ?? job.firstSeenDate
            let isRecent = jobDate > cutoffDate
            let isImportant = starredJobIds.contains(job.id) || appliedJobIds.contains(job.id)
            return isRecent || isImportant
        }

        storedJobIds = storedJobIds.intersection(Set(allJobs.map { $0.id }))

        try? await persistenceService.saveJobs(allJobs)
        try? await persistenceService.saveStoredJobIds(storedJobIds)
    }

    func scheduleCleanup() {
        Task {
            while true {
                await cleanupOldJobs()
                try? await Task.sleep(nanoseconds: 24 * 3600 * 1_000_000_000)
            }
        }
    }
}

// MARK: - Incremental Loading
extension JobManager {
    func loadJobsIncremental() async {
        isLoading = true

        if let persistedJobs = try? await persistenceService.loadJobs() {
            allJobs = persistedJobs
            loadingProgress = "Loaded \(persistedJobs.count) cached jobs"
        }

        await fetchAllJobs()
        isLoading = false
    }
}

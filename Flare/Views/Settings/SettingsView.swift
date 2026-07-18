//
//  SettingsView.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var jobManager: JobManager
    @EnvironmentObject var appDelegate: AppDelegate
    @State private var titleFilter = ""
    @State private var locationFilter = ""
    @State var refreshInterval = 30.0
    @State private var maxPagesToFetch = 5.0
    @State private var enableMicrosoft = true
    @State private var enableApple = false
    @State private var enableGoogle = false
    @State private var enableTikTok = false
    @State private var enableSnap = true
    @State private var enableAMD = true
    @State private var enableMeta = true
    @State private var enableCustomBoards = true
    @State private var includeRemoteJobs = true
    @State private var enableAIParser = false
    @State private var autoCheckForUpdates = true
    @State private var showSuccessMessage = false
    @State private var isDownloadingModel = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadStatus: String = ""
    @State private var modelSize: Double? = nil
    @State private var showCacheCleanupConfirmation = false
    @State private var cacheCleanupMessage: String?
    @State private var isClearingCache = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(isRefreshing: jobManager.isLoading)
                .padding(.horizontal)
                .padding(.vertical, 18)

            Divider()
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    SettingsSection(
                        title: "Data Sources",
                        icon: "dot.radiowaves.left.and.right",
                        subtitle: "Choose the career sites included in each refresh."
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            SourceToggle(source: .microsoft, title: "Microsoft Careers", isOn: $enableMicrosoft)
                            SourceToggle(source: .apple, title: "Apple Careers", isOn: $enableApple)
                            SourceToggle(source: .tiktok, title: "TikTok Jobs", isOn: $enableTikTok)
                            SourceToggle(source: .snap, title: "Snap Inc. Careers", isOn: $enableSnap)
                            SourceToggle(source: .amd, title: "AMD Careers", isOn: $enableAMD)
                            SourceToggle(source: .meta, title: "Meta Careers", isOn: $enableMeta)
                            SourceToggle(source: .google, title: "Google Careers", isOn: $enableGoogle)
                            SourceToggle(icon: "globe", color: .blue, title: "Custom Job Boards", isOn: $enableCustomBoards)
                            
                            Label("Some sources use their own refresh intervals.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 2)
                        }
                    }

                    SettingsSection(
                        title: "AI-Powered Parsing",
                        icon: "sparkles",
                        subtitle: "Use an on-device model when a job board cannot be recognized."
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $enableAIParser) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Enable AI job parsing")
                                    Text("Uses local AI to extract jobs from unknown websites")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .onChange(of: enableAIParser) { _, newValue in
                                if newValue {
                                    checkAndDownloadModel()
                                }
                            }

                            if enableAIParser {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 8) {
                                        Image(systemName: modelSize != nil ? "checkmark.circle.fill" : "arrow.down.circle")
                                            .foregroundColor(modelSize != nil ? .green : .blue)

                                        if let size = modelSize {
                                            Text("Model downloaded (\(String(format: "%.2f", size)) GB)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        } else if isDownloadingModel {
                                            Text("Downloading model...")
                                                .font(.caption)
                                                .foregroundColor(.blue)
                                        } else {
                                            Text("Model not downloaded")
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                        }

                                        Spacer()
                                    }

                                    if isDownloadingModel {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ProgressView(value: downloadProgress, total: 1.0)
                                                .progressViewStyle(.linear)

                                            Text(downloadStatus)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    HStack {
                                        if modelSize == nil && !isDownloadingModel {
                                            Button(action: { downloadModel() }) {
                                                Label("Download AI Model (~2 GB)", systemImage: "arrow.down.circle.fill")
                                            }
                                            .buttonStyle(.borderedProminent)
                                        } else if modelSize != nil {
                                            Button(action: { deleteModel() }) {
                                                Label("Delete Model", systemImage: "trash")
                                            }
                                            .buttonStyle(.bordered)
                                            .foregroundColor(.red)
                                        }
                                    }

                                    Divider()

                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "info.circle")
                                                .foregroundColor(.orange)
                                                .font(.caption)
                                            Text("Performance note")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                                .foregroundColor(.orange)
                                        }
                                        Text("AI parsing may be slower on Intel Macs (2016-2019). M1/M2 Macs will see excellent performance.")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text("Only used as fallback when API/ATS detection fails.")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.leading, 8)
                                }
                            }
                        }
                    }

                    SettingsSection(title: "Job Filters", icon: "line.3.horizontal.decrease.circle", subtitle: "Narrow results before they reach your job list.") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Job Titles", systemImage: "briefcase")
                                TextField("e.g., product manager, software engineer, designer", text: $titleFilter)
                                    .textFieldStyle(.roundedBorder)
                                Text("Separate multiple titles with commas")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Locations", systemImage: "location")
                                TextField("e.g., seattle, new york, remote", text: $locationFilter)
                                    .textFieldStyle(.roundedBorder)
                                Text("Separate multiple locations with commas")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Toggle(isOn: $includeRemoteJobs) {
                                HStack {
                                    Image(systemName: "house")
                                        .foregroundColor(.blue)
                                    Text("Include Remote Jobs")
                                    Text("(automatically adds 'remote' to location searches)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    
                    SettingsSection(title: "Refresh", icon: "arrow.triangle.2.circlepath", subtitle: "Control the default polling cadence and search depth.") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Check for new jobs every")
                                TextField("", value: $refreshInterval, format: .number)
                                    .frame(width: 60)
                                    .textFieldStyle(.roundedBorder)
                                Text("minutes")
                                Spacer()
                            }
                            Text("This is the default interval. Some sources have fixed intervals.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Text("Fetch up to")
                                TextField("", value: $maxPagesToFetch, format: .number)
                                    .frame(width: 60)
                                    .textFieldStyle(.roundedBorder)
                                Text("pages (\(Int(maxPagesToFetch) * 20) jobs)")
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .help("Each page contains 20 jobs. More pages = longer fetch time")
                        }
                    }

                    SettingsSection(title: "App Updates", icon: "arrow.down.app", subtitle: "Keep Flare current without interrupting your workflow.") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $autoCheckForUpdates) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Automatically check for updates")
                                    Text("Sparkle checks periodically while Flare is running")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            HStack {
                                Button(action: {
                                    checkForUpdatesManually()
                                }) {
                                    Label("Check for Updates Now", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)

                                Spacer()
                            }
                        }
                    }

                    SettingsSection(title: "Support", icon: "heart", subtitle: "Help keep Flare moving.") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Enjoying Flare?")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Support development with a coffee!")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button(action: {
                                    if let url = URL(string: "https://buymeacoffee.com/korhonen") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "cup.and.saucer.fill")
                                        Text("Buy Me a Coffee")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                            }
                        }
                    }
                    
                    if jobManager.fetchStatistics.lastFetchTime != nil {
                        SettingsSection(title: "Last Refresh", icon: "chart.bar", subtitle: "A snapshot of the most recent fetch.") {
                            VStack(alignment: .leading, spacing: 8) {
                                StatRow(label: "Total Jobs", value: "\(jobManager.fetchStatistics.totalJobs)")
                                StatRow(label: "New Jobs", value: "\(jobManager.fetchStatistics.newJobs)")
                                if jobManager.fetchStatistics.microsoftJobs > 0 {
                                    StatRow(label: "Microsoft", value: "\(jobManager.fetchStatistics.microsoftJobs)")
                                }
                                if jobManager.fetchStatistics.appleJobs > 0 {
                                    StatRow(label: "Apple", value: "\(jobManager.fetchStatistics.appleJobs)")
                                }
                                if jobManager.fetchStatistics.googleJobs > 0 {
                                    StatRow(label: "Google", value: "\(jobManager.fetchStatistics.googleJobs)")
                                }
                                if jobManager.fetchStatistics.tiktokJobs > 0 {
                                    StatRow(label: "TikTok", value: "\(jobManager.fetchStatistics.tiktokJobs)")
                                }
                                if jobManager.fetchStatistics.snapJobs > 0 {
                                    StatRow(label: "Snap", value: "\(jobManager.fetchStatistics.snapJobs)")
                                }
                                if jobManager.fetchStatistics.amdJobs > 0 {
                                    StatRow(label: "AMD", value: "\(jobManager.fetchStatistics.amdJobs)")
                                }
                                if jobManager.fetchStatistics.metaJobs > 0 {
                                    StatRow(label: "Meta", value: "\(jobManager.fetchStatistics.metaJobs)")
                                }
                                if jobManager.fetchStatistics.customBoardJobs > 0 {
                                    StatRow(label: "Custom Boards", value: "\(jobManager.fetchStatistics.customBoardJobs)")
                                }
                                if let lastFetch = jobManager.fetchStatistics.lastFetchTime {
                                    StatRow(label: "Last Updated", value: lastFetch.formatted())
                                }
                            }
                        }
                    }

                    SettingsSection(
                        title: "Data Storage",
                        icon: "externaldrive",
                        subtitle: "Manage the local files Flare uses to start quickly."
                    ) {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("LOCAL DATA FOLDER")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.secondary)

                                Text(PersistenceService.shared.getDataDirectoryPath())
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(NSColor.windowBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel("Local data folder")
                            }

                            HStack(spacing: 12) {
                                Button {
                                    Task {
                                        await PersistenceService.shared.openDataDirectoryInFinder()
                                    }
                                } label: {
                                    Label("Open in Finder", systemImage: "folder")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.setString(PersistenceService.shared.getDataDirectoryPath(), forType: .string)
                                } label: {
                                    Label("Copy Path", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)

                                Spacer()
                            }

                            Divider()

                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "trash.slash")
                                    .foregroundColor(.secondary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Job cache")
                                        .font(.subheadline.weight(.medium))
                                    Text("Removes cached jobs and seen-job history. Your boards, settings, saved jobs, and AI model stay in place.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if isClearingCache {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel("Clearing job cache")
                                } else {
                                    Button(role: .destructive) {
                                        showCacheCleanupConfirmation = true
                                    } label: {
                                        Label("Clear Cache", systemImage: "trash")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(jobManager.isLoading)
                                    .help(jobManager.isLoading ? "Wait for the current refresh to finish before clearing the cache." : "Remove cached jobs and seen-job history.")
                                }
                            }

                            if let cacheCleanupMessage {
                                Label(cacheCleanupMessage, systemImage: cacheCleanupMessage.hasPrefix("Could not") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(cacheCleanupMessage.hasPrefix("Could not") ? .orange : .green)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background((cacheCleanupMessage.hasPrefix("Could not") ? Color.orange : Color.green).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    
                    HStack(spacing: 12) {
                        Button {
                            saveSettings(refreshNow: false)
                            showSuccessMessage = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                showSuccessMessage = false
                            }
                        } label: {
                            Label("Save Settings", systemImage: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button {
                            saveSettings(refreshNow: true)
                        } label: {
                            Label(jobManager.isLoading ? "Refreshing…" : "Save and Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(jobManager.isLoading || isClearingCache)
                        Spacer()
                        
                        if showSuccessMessage {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Settings saved!")
                                    .foregroundColor(.green)
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .padding()
            }
        }
        .preferredColorScheme(.light)
        .alert("Clear Job Cache?", isPresented: $showCacheCleanupConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Cache", role: .destructive) {
                guard !jobManager.isLoading else {
                    cacheCleanupMessage = "Could not clear the cache while a refresh is running."
                    return
                }

                isClearingCache = true
                cacheCleanupMessage = nil
                Task { @MainActor in
                    defer { isClearingCache = false }
                    do {
                        let result = try await jobManager.clearJobCache()
                        let size = ByteCountFormatter.string(fromByteCount: result.bytesFreed, countStyle: .file)
                        cacheCleanupMessage = "Removed \(result.filesRemoved) cache files and freed \(size)."
                    } catch {
                        cacheCleanupMessage = "Could not clear the job cache: \(error.localizedDescription)"
                    }
                }
            }
        } message: {
            Text("This removes cached jobs and seen-job history. Starred and applied job IDs, boards, settings, API routes, and the AI model are preserved.")
        }
        .padding()
        .onAppear {
            loadSettings()
        }
    }
    
    private func loadSettings() {
        titleFilter = jobManager.jobTitleFilter
        locationFilter = jobManager.locationFilter
        refreshInterval = jobManager.refreshInterval
        maxPagesToFetch = Double(jobManager.maxPagesToFetch)
        enableMicrosoft = jobManager.enableMicrosoft
        enableApple = jobManager.enableApple
        enableGoogle = jobManager.enableGoogle
        enableTikTok = jobManager.enableTikTok
        enableSnap = jobManager.enableSnap
        enableAMD = jobManager.enableAMD
        enableMeta = jobManager.enableMeta
        enableCustomBoards = jobManager.enableCustomBoards
        includeRemoteJobs = jobManager.includeRemoteJobs
        autoCheckForUpdates = jobManager.autoCheckForUpdates
        enableAIParser = jobManager.enableAIParser

        Task {
            modelSize = await ModelDownloader.shared.getModelSize()
        }
    }

    private func saveSettings(refreshNow: Bool) {
        jobManager.jobTitleFilter = titleFilter
        jobManager.locationFilter = locationFilter
        jobManager.refreshInterval = refreshInterval
        jobManager.maxPagesToFetch = Int(maxPagesToFetch)
        jobManager.enableMicrosoft = enableMicrosoft
        jobManager.enableApple = enableApple
        jobManager.enableGoogle = enableGoogle
        jobManager.enableTikTok = enableTikTok
        jobManager.enableSnap = enableSnap
        jobManager.enableAMD = enableAMD
        jobManager.enableMeta = enableMeta
        jobManager.enableCustomBoards = enableCustomBoards
        jobManager.includeRemoteJobs = includeRemoteJobs
        jobManager.autoCheckForUpdates = autoCheckForUpdates
        jobManager.enableAIParser = enableAIParser

        Task {
            if refreshNow {
                await jobManager.startMonitoring()
            } else {
                jobManager.applyMonitoringSettings()
            }
        }
    }

    private func checkForUpdatesManually() {
        print("[Settings] Check for updates button pressed")
        print("[Settings] Calling appDelegate.checkForUpdatesNow()")
        appDelegate.checkForUpdatesNow()
    }

    // MARK: - AI Model Management

    private func checkAndDownloadModel() {
        Task {
            modelSize = await ModelDownloader.shared.getModelSize()

            let isDownloaded = await ModelDownloader.shared.isModelDownloaded()
            if !isDownloaded {
                downloadModel()
            }
        }
    }

    private func downloadModel() {
        Task {
            isDownloadingModel = true
            downloadProgress = 0.0
            downloadStatus = "Starting download..."

            do {
                _ = try await ModelDownloader.shared.downloadModel { progress, status in
                    Task { @MainActor in
                        self.downloadProgress = progress
                        self.downloadStatus = status
                    }
                }

                modelSize = await ModelDownloader.shared.getModelSize()
                isDownloadingModel = false
            } catch {
                print("[Settings] Model download failed: \(error)")
                isDownloadingModel = false
                downloadStatus = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    private func deleteModel() {
        Task {
            do {
                try await ModelDownloader.shared.deleteModel()
                modelSize = nil
            } catch {
                print("[Settings] Failed to delete model: \(error)")
            }
        }
    }
}

private struct SettingsHeader: View {
    let isRefreshing: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(FlareVisual.ink)

                Text("Tune the sources, filters, and local tools behind your job search.")
                    .font(.callout)
                    .foregroundColor(FlareVisual.fadedInk)
            }

            Spacer(minLength: 16)

            if isRefreshing {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing")
                }
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("A job refresh is in progress")
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    let subtitle: String?
    let content: () -> Content

    init(
        title: String,
        icon: String = "gearshape",
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(FlareVisual.ember)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.headline)
                    .foregroundColor(FlareVisual.ink)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(FlareVisual.fadedInk)
                    .padding(.leading, 26)
            }

            content()
                .padding(16)
                .background(FlareVisual.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(FlareVisual.soot)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(FlareVisual.ink.opacity(0.16), lineWidth: 1))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct SourceToggle: View {
    let icon: String
    let color: Color
    let title: String
    @Binding var isOn: Bool

    init(source: JobSource, title: String, isOn: Binding<Bool>) {
        self.icon = source.icon
        self.color = source.color
        self.title = title
        self._isOn = isOn
    }

    init(icon: String, color: Color, title: String, isOn: Binding<Bool>) {
        self.icon = icon
        self.color = color
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Label {
                Text(title)
                    .font(.callout)
            } icon: {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .frame(width: 16)
            }
        }
        .accessibilityHint("Includes \(title) when Flare refreshes jobs.")
    }
}

struct StatRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.callout)
    }
}

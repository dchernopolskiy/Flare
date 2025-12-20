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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Data Sources
                    SettingsSection(title: "Data Sources") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $enableMicrosoft) {
                                HStack {
                                    Image(systemName: JobSource.microsoft.icon)
                                        .foregroundColor(JobSource.microsoft.color)
                                    Text("Microsoft Careers")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Toggle(isOn: $enableApple) {
                                HStack {
                                    Image(systemName: JobSource.apple.icon)
                                        .foregroundColor(JobSource.apple.color)
                                    Text("Apple Careers")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Toggle(isOn: $enableTikTok) {
                                HStack {
                                    Image(systemName: JobSource.tiktok.icon)
                                        .foregroundColor(JobSource.tiktok.color)
                                    Text("TikTok Jobs")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Toggle(isOn: $enableSnap) {
                                HStack {
                                    Image(systemName: JobSource.snap.icon)
                                        .foregroundColor(JobSource.snap.color)
                                    Text("Snap Inc. Careers")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Toggle(isOn: $enableAMD) {
                                HStack {
                                    Image(systemName: JobSource.amd.icon)
                                        .foregroundColor(JobSource.amd.color)
                                    Text("AMD Careers")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Toggle(isOn: $enableMeta) {
                                HStack {
                                    Image(systemName: JobSource.meta.icon)
                                        .foregroundColor(JobSource.meta.color)
                                    Text("Meta Careers")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Toggle(isOn: $enableGoogle) {
                                HStack {
                                    Image(systemName: JobSource.google.icon)
                                        .foregroundColor(JobSource.google.color)
                                    Text("Google Careers")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Toggle(isOn: $enableCustomBoards) {
                                HStack {
                                    Image(systemName: "globe")
                                        .foregroundColor(.blue)
                                    Text("Custom Job Boards")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Text("Note: Some sources may have fixed refresh intervals")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // AI Parsing Section
                    SettingsSection(title: "AI-Powered Parsing") {
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
                                    // Model Status
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

                                    // Download Progress
                                    if isDownloadingModel {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ProgressView(value: downloadProgress, total: 1.0)
                                                .progressViewStyle(.linear)

                                            Text(downloadStatus)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    // Download/Delete Button
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

                                    // Performance Note
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

                    // Job Filters Section
                    SettingsSection(title: "Job Filters") {
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
                    
                    // Fetch Settings Section
                    SettingsSection(title: "Fetch Settings") {
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

                    // App Updates Section
                    SettingsSection(title: "App Updates") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $autoCheckForUpdates) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Automatically check for updates")
                                    Text("Check for app updates daily at 10 AM")
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

                    // Support Section
                    SettingsSection(title: "Support") {
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
                        SettingsSection(title: "Statistics") {
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
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Data Storage")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Data Location:")
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    
                                    Text(PersistenceService.shared.getDataDirectoryPath())
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(4)
                                    
                                    HStack(spacing: 12) {
                                        Button("Open in Finder") {
                                            Task {
                                                await PersistenceService.shared.openDataDirectoryInFinder()
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        
                                        Button("Copy Path") {
                                            let pasteboard = NSPasteboard.general
                                            pasteboard.clearContents()
                                            pasteboard.setString(PersistenceService.shared.getDataDirectoryPath(), forType: .string)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                                .padding()
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(8)
                            }

                        }
                    }
                    
                    // Action Buttons
                    HStack {
                        Button("Save Settings") {
                            saveSettings()
                            showSuccessMessage = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                showSuccessMessage = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("Save and Refresh Now") {
                            saveSettings()
                            Task {
                                await jobManager.fetchAllJobs()
                            }
                        }
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

        // Check model status
        Task {
            modelSize = await ModelDownloader.shared.getModelSize()
        }
    }

    private func saveSettings() {
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
            await jobManager.startMonitoring()
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
            // Always check model size when toggling AI on
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
                    self.downloadProgress = progress
                    self.downloadStatus = status
                }

                // Update model size BEFORE setting isDownloadingModel = false
                // This prevents UI from jumping back to download button
                modelSize = await ModelDownloader.shared.getModelSize()

                // Small delay to ensure UI shows final state
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

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

struct SettingsSection<Content: View>: View {
    let title: String
    let content: () -> Content
    
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            
            content()
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
        }
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

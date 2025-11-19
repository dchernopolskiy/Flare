//
//  SettingsView.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var jobManager: JobManager
    @State private var titleFilter = ""
    @State private var locationFilter = ""
    @State var refreshInterval = 30.0
    @State private var maxPagesToFetch = 5.0
    @State private var enableMicrosoft = true
    @State private var enableTikTok = false
    @State private var enableSnap = true
    @State private var enableAMD = true
    @State private var enableMeta = true
    @State private var enableCustomBoards = true
    @State private var includeRemoteJobs = true
    @State private var autoCheckForUpdates = true
    @State private var showSuccessMessage = false
    
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
                                    Image(systemName: JobSource.amd.icon)
                                        .foregroundColor(JobSource.amd.color)
                                    Text("Meta Careers")
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
                    
                    if jobManager.fetchStatistics.lastFetchTime != nil {
                        SettingsSection(title: "Statistics") {
                            VStack(alignment: .leading, spacing: 8) {
                                StatRow(label: "Total Jobs", value: "\(jobManager.fetchStatistics.totalJobs)")
                                StatRow(label: "New Jobs", value: "\(jobManager.fetchStatistics.newJobs)")
                                if jobManager.fetchStatistics.microsoftJobs > 0 {
                                    StatRow(label: "Microsoft", value: "\(jobManager.fetchStatistics.microsoftJobs)")
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
                                if jobManager.fetchStatistics.amdJobs > 0 {
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
        enableTikTok = jobManager.enableTikTok
        enableSnap = jobManager.enableSnap
        enableAMD = jobManager.enableAMD
        enableMeta = jobManager.enableMeta
        enableCustomBoards = jobManager.enableCustomBoards
        includeRemoteJobs = jobManager.includeRemoteJobs
        autoCheckForUpdates = jobManager.autoCheckForUpdates
    }
    
    private func saveSettings() {
        jobManager.jobTitleFilter = titleFilter
        jobManager.locationFilter = locationFilter
        jobManager.refreshInterval = refreshInterval
        jobManager.maxPagesToFetch = Int(maxPagesToFetch)
        jobManager.enableMicrosoft = enableMicrosoft
        jobManager.enableTikTok = enableTikTok
        jobManager.enableSnap = enableSnap
        jobManager.enableAMD = enableAMD
        jobManager.enableMeta = enableMeta
        jobManager.enableCustomBoards = enableCustomBoards
        jobManager.includeRemoteJobs = includeRemoteJobs
        jobManager.autoCheckForUpdates = autoCheckForUpdates

        Task {
            await jobManager.startMonitoring()
        }
    }

    private func checkForUpdatesManually() {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.checkForUpdatesNow()
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

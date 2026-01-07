//
//  JobListView.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import SwiftUI
import WebKit
import Combine

struct JobListView: View {
    @EnvironmentObject var jobManager: JobManager
    @Binding var sidebarVisible: Bool
    let isWindowMinimized: Bool
    
    @State private var searchText = ""
    @State private var selectedSources: Set<JobSource> = Set([.microsoft, .apple, .google, .tiktok, .snap, .amd, .meta, .greenhouse, .lever, .ashby, .workday, .unknown].filter { $0.isSupported })
    @State private var showOnlyStarred = false
    @State private var showOnlyApplied = false
    @State private var cachedJobs: [Job] = []
    @State private var lastFilterUpdate = Date()
    
    private let filterPublisher = PassthroughSubject<Void, Never>()
    @State private var filterCancellable: AnyCancellable?
    
    var body: some View {
        VStack(spacing: 0) {
            JobListHeader(
                searchText: $searchText,
                selectedSources: $selectedSources,
                showOnlyStarred: $showOnlyStarred,
                showOnlyApplied: $showOnlyApplied
            )

            Divider()

            if jobManager.isLoading && cachedJobs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cachedJobs.isEmpty {
                EmptyJobsView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: []) {
                            ForEach(cachedJobs) { job in
                                JobRow(
                                    job: job,
                                    sidebarVisible: $sidebarVisible,
                                    isWindowMinimized: isWindowMinimized
                                )
                                .id(job.id)
                                .transition(.opacity)

                                Divider()
                            }

                            if jobManager.isLoading {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text(jobManager.loadingProgress.isEmpty ? "Refreshing..." : jobManager.loadingProgress)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                            }
                        }
                    }
                }
            }

            // Error banner as permanent bottom pane
            if let error = jobManager.lastError {
                Divider()
                ErrorBanner(message: error)
            }
        }
        .onAppear {
            setupFilterDebouncing()
            updateFilteredJobs()
        }
        .onChange(of: searchText) { oldValue, newValue in
            print("[JobListView] searchText changed: '\(oldValue)' -> '\(newValue)'")
            filterPublisher.send()
        }
        .onChange(of: selectedSources) { _, _ in filterPublisher.send() }
        .onChange(of: showOnlyStarred) { _, _ in filterPublisher.send() }
        .onChange(of: showOnlyApplied) { _, _ in filterPublisher.send() }
        .onChange(of: jobManager.allJobs) { _, _ in
            updateFilteredJobs()
        }
    }
    
    private func setupFilterDebouncing() {
        print("[JobListView] Setting up filter debouncing")
        filterCancellable = filterPublisher
            .debounce(for: .seconds(0.3), scheduler: RunLoop.main)
            .sink { _ in
                print("[JobListView] Debounce triggered, calling updateFilteredJobs()")
                self.updateFilteredJobs()
            }
    }

    private func updateFilteredJobs() {
        print("[JobListView] updateFilteredJobs called with searchText: '\(searchText)'")
        withAnimation(.easeInOut(duration: 0.2)) {
            cachedJobs = jobManager.getFilteredJobs(
                titleFilter: searchText,
                locationFilter: jobManager.locationFilter,
                sourcesFilter: selectedSources,
                showStarred: showOnlyStarred,
                showApplied: showOnlyApplied
            )
            print("[JobListView] Updated filtered jobs: \(cachedJobs.count) jobs from \(jobManager.allJobs.count) total (searchText: '\(searchText)')")
        }
    }
}

struct JobListHeader: View {
    @EnvironmentObject var jobManager: JobManager
    @EnvironmentObject var boardMonitor: JobBoardMonitor
    @Binding var searchText: String
    @Binding var selectedSources: Set<JobSource>
    @Binding var showOnlyStarred: Bool
    @Binding var showOnlyApplied: Bool
    
    private var supportedSources: [JobSource] {
        return [.microsoft, .apple, .google, .tiktok, .snap, .amd, .meta, .greenhouse, .lever, .ashby, .workday]
            .filter { $0.isSupported }
            .sorted { $0.rawValue < $1.rawValue }
    }
    
    private var allSourcesSelected: Bool {
        !supportedSources.isEmpty && supportedSources.allSatisfy { selectedSources.contains($0) }
    }
    
    private var someSourcesSelected: Bool {
        !selectedSources.isEmpty && selectedSources.contains { source in
            supportedSources.contains(source)
        }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Title and Actions
            HStack {
                Text("Recent Jobs")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if !supportedSources.isEmpty {
                    Menu {
                        Button(action: toggleAllSources) {
                            HStack {
                                Image(systemName: allSourcesSelected ? "checkmark.square.fill" :
                                                    someSourcesSelected ? "minus.square.fill" : "square")
                                Text("All Sources")
                                Spacer()
                            }
                        }
                        
                        Divider()
                        
                        ForEach(supportedSources.indices, id: \.self) { index in
                            let source = supportedSources[index]
                            Button(action: {
                                toggleSource(source)
                            }) {
                                HStack {
                                    Image(systemName: selectedSources.contains(source) ? "checkmark.square.fill" : "square")
                                    Image(systemName: source.icon)
                                        .foregroundColor(source.color)
                                    Text(source.rawValue)
                                    
                                    let count = jobManager.allJobs.filter { $0.source == source }.count
                                    if count > 0 {
                                        Text("(\(count))")
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text("(0)")
                                            .foregroundColor(.secondary.opacity(0.5))
                                    }
                                    
                                    Spacer()
                                }
                            }
                        }
                    } label: {
                        Label(sourceFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
        
                
                Button(action: {
                    Task { await jobManager.fetchAllJobs() }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(jobManager.isLoading)
            }
            .padding(.horizontal)
            .padding(.top)
            
            // Search and Filter Bar
            HStack(spacing: 12) {
                // Search Field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search jobs...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                // Filter Toggles
                Toggle(isOn: $showOnlyStarred) {
                    Label("Starred", systemImage: "star.fill")
                        .foregroundColor(showOnlyStarred ? .yellow : .secondary)
                }
                .toggleStyle(.button)
                
                Toggle(isOn: $showOnlyApplied) {
                    Label("Applied", systemImage: "checkmark.circle")
                        .foregroundColor(showOnlyApplied ? .green : .secondary)
                }
                .toggleStyle(.button)
                
                // Show filter status
                if !selectedSources.isEmpty && selectedSources.count < supportedSources.count {
                    Text("Filtered")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
    
    private var sourceFilterLabel: String {
        if supportedSources.isEmpty {
            return "No Sources"
        } else if allSourcesSelected {
            return "All Sources"
        } else if selectedSources.isEmpty {
            return "No Sources Selected"
        } else if selectedSources.count == 1 {
            return selectedSources.first?.rawValue ?? "Unknown"
        } else {
            let activeCount = selectedSources.filter { source in
                supportedSources.contains(source)
            }.count
            return "\(activeCount) Sources"
        }
    }
    
    private func toggleAllSources() {
        if allSourcesSelected {
            selectedSources.removeAll()
        } else {
            selectedSources = Set(supportedSources)
        }
    }
    
    private func toggleSource(_ source: JobSource) {
        if selectedSources.contains(source) {
            selectedSources.remove(source)
        } else {
            selectedSources.insert(source)
        }
    }
}

struct EmptyJobsView: View {
    @EnvironmentObject var jobManager: JobManager
    
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            Text("No jobs found")
                .font(.title3)
                .foregroundColor(.secondary)
            
            if jobManager.fetchStatistics.totalJobs > 0 {
                Text("Try adjusting your filters")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Check your filters in Settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String
    
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
    }
}

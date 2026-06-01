//
//  JobListView.swift
//  Flare
//

import SwiftUI
import WebKit
import Combine

struct JobListView: View {
    @EnvironmentObject var jobManager: JobManager
    @Binding var sidebarVisible: Bool
    let isWindowMinimized: Bool

    @State private var searchText = ""
    @State private var selectedSources: Set<JobSource> = Set([.microsoft, .apple, .google, .tiktok, .snap, .amd, .meta, .greenhouse, .lever, .ashby, .workday, .icims, .taleo, .unknown].filter { $0.isSupported })
    @State private var showOnlyStarred = false
    @State private var showOnlyApplied = false
    @State private var allFilteredJobs: [Job] = []

    private let pageSize = 50
    @State private var displayedCount = 50
    @State private var isLoadingMore = false

    private let filterPublisher = PassthroughSubject<Void, Never>()
    @State private var filterCancellable: AnyCancellable?

    private var displayedJobs: [Job] { Array(allFilteredJobs.prefix(displayedCount)) }
    private var hasMoreJobs: Bool { displayedCount < allFilteredJobs.count }

    var body: some View {
        VStack(spacing: 0) {
            JobListHeader(
                searchText: $searchText,
                selectedSources: $selectedSources,
                showOnlyStarred: $showOnlyStarred,
                showOnlyApplied: $showOnlyApplied
            )

            Divider()

            if jobManager.isLoading && allFilteredJobs.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allFilteredJobs.isEmpty {
                EmptyJobsView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: []) {
                            ForEach(displayedJobs) { job in
                                JobRow(job: job, sidebarVisible: $sidebarVisible, isWindowMinimized: isWindowMinimized)
                                    .id(job.id)
                                    .transition(.opacity)
                                    .onAppear {
                                        if job.id == displayedJobs.last?.id && hasMoreJobs { loadMoreJobs() }
                                    }
                                Divider()
                            }

                            if hasMoreJobs {
                                LoadMoreView(isLoading: isLoadingMore, remainingCount: allFilteredJobs.count - displayedCount, onLoadMore: loadMoreJobs)
                            }

                            if jobManager.isLoading {
                                HStack {
                                    ProgressView().scaleEffect(0.8)
                                    Text(jobManager.loadingProgress.isEmpty ? "Refreshing..." : jobManager.loadingProgress)
                                        .font(.caption).foregroundColor(.secondary)
                                }.padding()
                            }
                        }
                    }
                }
            }

            VStack(spacing: 0) {
                if allFilteredJobs.count > displayedCount {
                    HStack {
                        Text("Showing \(displayedCount) of \(allFilteredJobs.count) jobs")
                            .font(.caption2).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal).padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                }

                if let error = jobManager.lastError {
                    Divider()
                    ErrorBanner(message: error)
                }
            }
        }
        .onAppear {
            setupFilterDebouncing()
            updateFilteredJobs()
        }
        .onChange(of: searchText) { _, _ in resetPagination(); filterPublisher.send() }
        .onChange(of: selectedSources) { _, _ in resetPagination(); filterPublisher.send() }
        .onChange(of: showOnlyStarred) { _, _ in resetPagination(); filterPublisher.send() }
        .onChange(of: showOnlyApplied) { _, _ in resetPagination(); filterPublisher.send() }
        .onChange(of: jobManager.allJobs) { _, _ in updateFilteredJobs() }
        .onChange(of: jobManager.starredJobIds) { _, _ in updateFilteredJobs() }
        .onChange(of: jobManager.appliedJobIds) { _, _ in updateFilteredJobs() }
    }

    private func setupFilterDebouncing() {
        filterCancellable = filterPublisher
            .debounce(for: .seconds(0.3), scheduler: RunLoop.main)
            .sink { _ in updateFilteredJobs() }
    }

    private func updateFilteredJobs() {
        withAnimation(.easeInOut(duration: 0.2)) {
            allFilteredJobs = jobManager.getFilteredJobs(
                titleFilter: searchText,
                locationFilter: jobManager.locationFilter,
                sourcesFilter: selectedSources,
                showStarred: showOnlyStarred,
                showApplied: showOnlyApplied
            )
        }
    }

    private func resetPagination() { displayedCount = pageSize }

    private func loadMoreJobs() {
        guard !isLoadingMore && hasMoreJobs else { return }
        isLoadingMore = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.2)) {
                displayedCount = min(displayedCount + pageSize, allFilteredJobs.count)
            }
            isLoadingMore = false
        }
    }
}

struct LoadMoreView: View {
    let isLoading: Bool
    let remainingCount: Int
    let onLoadMore: () -> Void

    var body: some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView().scaleEffect(0.7)
                Text("Loading more...").font(.caption).foregroundColor(.secondary)
            } else {
                Button(action: onLoadMore) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                        Text("Load \(min(remainingCount, 50)) more")
                    }.font(.caption)
                }
                .buttonStyle(.plain).foregroundColor(.accentColor)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
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
        [.microsoft, .apple, .google, .tiktok, .snap, .amd, .meta, .greenhouse, .lever, .ashby, .workday, .icims, .taleo, .unknown]
            .filter { $0.isSupported }.sorted { $0.rawValue < $1.rawValue }
    }

    private var allSourcesSelected: Bool {
        !supportedSources.isEmpty && supportedSources.allSatisfy { selectedSources.contains($0) }
    }

    private var someSourcesSelected: Bool {
        !selectedSources.isEmpty && selectedSources.contains { supportedSources.contains($0) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Recent Jobs").font(.title2).fontWeight(.semibold)
                Spacer()

                if !supportedSources.isEmpty {
                    Menu {
                        Button(action: toggleAllSources) {
                            HStack {
                                Image(systemName: allSourcesSelected ? "checkmark.square.fill" : someSourcesSelected ? "minus.square.fill" : "square")
                                Text("All Sources")
                                Spacer()
                            }
                        }

                        Divider()

                        ForEach(supportedSources.indices, id: \.self) { index in
                            let source = supportedSources[index]
                            Button(action: { toggleSource(source) }) {
                                HStack {
                                    Image(systemName: selectedSources.contains(source) ? "checkmark.square.fill" : "square")
                                    Image(systemName: source.icon).foregroundColor(source.color)
                                    Text(source.rawValue)
                                    let count = jobManager.allJobs.filter { $0.source == source }.count
                                    Text("(\(count))").foregroundColor(count > 0 ? .secondary : .secondary.opacity(0.5))
                                    Spacer()
                                }
                            }
                        }
                    } label: {
                        Label(sourceFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
                    }
                }

                Button(action: { Task { await jobManager.fetchAllJobs() } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }.disabled(jobManager.isLoading)
            }
            .padding(.horizontal).padding(.top)

            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search jobs...", text: $searchText).textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)

                Toggle(isOn: $showOnlyStarred) {
                    Label("Starred", systemImage: "star.fill").foregroundColor(showOnlyStarred ? .yellow : .secondary)
                }.toggleStyle(.button)

                Toggle(isOn: $showOnlyApplied) {
                    Label("Applied", systemImage: "checkmark.circle").foregroundColor(showOnlyApplied ? .green : .secondary)
                }.toggleStyle(.button)

                if !selectedSources.isEmpty && selectedSources.count < supportedSources.count {
                    Text("Filtered").font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2)).cornerRadius(4)
                }
            }
            .padding(.horizontal).padding(.bottom)
        }
    }

    private var sourceFilterLabel: String {
        if supportedSources.isEmpty { return "No Sources" }
        if allSourcesSelected { return "All Sources" }
        if selectedSources.isEmpty { return "No Sources Selected" }
        if selectedSources.count == 1 { return selectedSources.first?.rawValue ?? "Unknown" }
        return "\(selectedSources.filter { supportedSources.contains($0) }.count) Sources"
    }

    private func toggleAllSources() {
        if allSourcesSelected { selectedSources.removeAll() }
        else { selectedSources = Set(supportedSources) }
    }

    private func toggleSource(_ source: JobSource) {
        if selectedSources.contains(source) { selectedSources.remove(source) }
        else { selectedSources.insert(source) }
    }
}

struct EmptyJobsView: View {
    @EnvironmentObject var jobManager: JobManager

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 50)).foregroundColor(.secondary)
            Text("No jobs found").font(.title3).foregroundColor(.secondary)
            Text(jobManager.fetchStatistics.totalJobs > 0 ? "Try adjusting your filters" : "Check your filters in Settings")
                .font(.caption).foregroundColor(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
            Text(message).font(.caption).foregroundColor(.secondary)
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
    }
}

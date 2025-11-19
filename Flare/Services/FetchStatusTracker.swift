//
//  FetchStatusTracker.swift
//  MSJobMonitor
//
//  Created by Dan on 11/10/25.
//

import SwiftUI
import Foundation

@MainActor
class FetchStatusTracker: ObservableObject {
    static let shared = FetchStatusTracker()
    
    @Published var statuses: [String: FetchStatus] = [:]
    
    struct FetchStatus: Identifiable {
        let id = UUID()
        let source: String
        let state: State
        let timestamp: Date
        let message: String?
        
        enum State {
            case idle
            case fetching
            case success(jobCount: Int)
            case failed(error: String)
            
            var icon: String {
                switch self {
                case .idle: return "circle"
                case .fetching: return "arrow.circlepath"
                case .success: return "checkmark.circle.fill"
                case .failed: return "exclamationmark.triangle.fill"
                }
            }
            
            var color: Color {
                switch self {
                case .idle: return .gray
                case .fetching: return .blue
                case .success: return .green
                case .failed: return .red
                }
            }
            
            var isRotating: Bool {
                if case .fetching = self { return true }
                return false
            }
            
            var sortPriority: Int {
                switch self {
                case .failed: return 0
                case .fetching: return 1
                case .success: return 2
                case .idle: return 3
                }
            }
        }
    }
    
    func updateStatus(source: String, state: FetchStatus.State, message: String? = nil) {
        let status = FetchStatus(
            source: source,
            state: state,
            timestamp: Date(),
            message: message
        )
        statuses[source] = status
    }
    
    func startFetch(source: String) {
        updateStatus(source: source, state: .fetching, message: "Fetching jobs...")
    }
    
    func successFetch(source: String, jobCount: Int) {
        updateStatus(source: source, state: .success(jobCount: jobCount), message: "Fetched \(jobCount) jobs")
    }
    
    func failedFetch(source: String, error: Error) {
        let errorMessage = error.localizedDescription
        updateStatus(source: source, state: .failed(error: errorMessage), message: errorMessage)
    }
    
    func clearStatus(source: String) {
        statuses.removeValue(forKey: source)
    }
    
    func clearAll() {
        statuses.removeAll()
    }
    
    var hasErrors: Bool {
        statuses.values.contains { status in
            if case .failed = status.state { return true }
            return false
        }
    }
    
    var errorCount: Int {
        statuses.values.filter { status in
            if case .failed = status.state { return true }
            return false
        }.count
    }
}

// MARK: - UI Components

struct FetchStatusView: View {
    @ObservedObject var tracker = FetchStatusTracker.shared
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !tracker.statuses.isEmpty {
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        Text("Fetch Status")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if tracker.hasErrors {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                Text("\(tracker.errorCount) failed")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(.red)
                        }
                        
                        Button(action: {
                            tracker.clearAll()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor))
                }
                .buttonStyle(.plain)
                
                if isExpanded {
                    Divider()
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(sortedStatuses) { status in
                                FetchStatusRow(status: status)
                                
                                if status.id != sortedStatuses.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
        .onAppear {
            if tracker.hasErrors {
                isExpanded = true
            }
        }
        .onChange(of: tracker.hasErrors) { _, newValue in
            if newValue && !isExpanded {
                withAnimation(.spring(response: 0.3)) {
                    isExpanded = true
                }
            }
        }
    }
    
    private var sortedStatuses: [FetchStatusTracker.FetchStatus] {
        tracker.statuses.values.sorted { status1, status2 in
            let priority1 = status1.state.sortPriority
            let priority2 = status2.state.sortPriority
            
            if priority1 != priority2 {
                return priority1 < priority2
            }
            
            return status1.timestamp > status2.timestamp
        }
    }
}

struct FetchStatusRow: View {
    let status: FetchStatusTracker.FetchStatus
    
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: status.state.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(status.state.color)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(status.state.isRotating ? 360 : 0))
                .animation(
                    status.state.isRotating ?
                        Animation.linear(duration: 1).repeatForever(autoreverses: false) :
                        .default,
                    value: status.state.isRotating
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(status.source)
                    .font(.system(size: 11, weight: .medium))
                
                if let message = status.message {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            Text(timeAgo(from: status.timestamp))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    private func timeAgo(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        
        if seconds < 60 {
            return "\(seconds)s ago"
        } else if seconds < 3600 {
            return "\(seconds / 60)m ago"
        } else {
            return "\(seconds / 3600)h ago"
        }
    }
}

// MARK: - Job Fetcher Protocol
protocol JobFetcherProtocol {
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job]
}

// MARK: - URL-based Job Fetcher Protocol
protocol URLBasedJobFetcherProtocol {
    func fetchJobs(from url: URL, titleFilter: String, locationFilter: String) async throws -> [Job]
}

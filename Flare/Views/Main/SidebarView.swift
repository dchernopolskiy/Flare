//
//  SidebarView.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var jobManager: JobManager
    @Binding var sidebarVisible: Bool
    let isWindowMinimized: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            // Header with toggle
            HStack {
                Image(systemName: "briefcase.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
                
                Spacer()
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        sidebarVisible = false
                    }
                }) {
                    Image(systemName: "sidebar.left")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide Sidebar")
            }
            
            // Navigation Buttons
            VStack(spacing: 10) {
                SidebarButton(
                    title: "Jobs",
                    icon: "list.bullet",
                    badge: jobManager.allJobs.isEmpty ? nil : "\(jobManager.allJobs.count)",
                    isSelected: jobManager.selectedTab == "jobs"
                ) {
                    jobManager.selectedTab = "jobs"
                    if isWindowMinimized {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            sidebarVisible = false
                        }
                    }
                }
                
                SidebarButton(
                    title: "Job Boards",
                    icon: "globe",
                    isSelected: jobManager.selectedTab == "boards"
                ) {
                    jobManager.selectedTab = "boards"
                    jobManager.selectedJob = nil
                    if isWindowMinimized {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            sidebarVisible = false
                        }
                    }
                }
                
                SidebarButton(
                    title: "Settings",
                    icon: "gear",
                    isSelected: jobManager.selectedTab == "settings"
                ) {
                    jobManager.selectedTab = "settings"
                    jobManager.selectedJob = nil
                    if isWindowMinimized {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            sidebarVisible = false
                        }
                    }
                }
            }
            
            Spacer()
            
            // Loading Indicator
            if jobManager.isLoading {
                VStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.8)
                    if !jobManager.loadingProgress.isEmpty {
                        Text(jobManager.loadingProgress)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
                .padding(.horizontal, 4)
            }
            
            // Statistics
            VStack(spacing: 8) {
                if jobManager.newJobsCount > 0 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("\(jobManager.newJobsCount) new")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                    }
                }
                
                Text("\(jobManager.allJobs.count) recent jobs")
                    .font(.caption)
                    .fontWeight(.medium)
                
                if !jobManager.fetchStatistics.summary.isEmpty {
                    Text(jobManager.fetchStatistics.summary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                if let lastFetch = jobManager.fetchStatistics.lastFetchTime {
                    Text("Updated \(lastFetch, style: .relative)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(Color(NSColor.separatorColor)),
            alignment: .trailing
        )
    }
}

struct SidebarButton: View {
    let title: String
    let icon: String
    var badge: String? = nil
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(title)
                Spacer()
                if let badge = badge {
                    Text(badge)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

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
            HStack {
                HStack(spacing: 8) {
                    Image("FlareMascot")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("FLARE")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(FlareVisual.paper)
                        Text("JOB DESK")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(FlareVisual.fadedInk)
                    }
                }
                
                Spacer()
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        sidebarVisible = false
                    }
                }) {
                    Image(systemName: "sidebar.left")
                        .font(.title3)
                        .foregroundColor(FlareVisual.paper.opacity(0.64))
                }
                .buttonStyle(.plain)
                .help("Hide Sidebar")
            }
            
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
            
            if jobManager.isLoading {
                VStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.8)
                    if !jobManager.loadingProgress.isEmpty {
                        Text(jobManager.loadingProgress)
                            .font(.caption2)
                            .foregroundColor(FlareVisual.paper.opacity(0.64))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
                .padding(.horizontal, 4)
            }
            
            VStack(spacing: 8) {
                if jobManager.newJobsCount > 0 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(FlareVisual.moss)
                            .frame(width: 8, height: 8)
                        Text("\(jobManager.newJobsCount) new")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(FlareVisual.moss)
                    }
                }
                
                Text("\(jobManager.allJobs.count) recent jobs")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(FlareVisual.paper)
                
                if !jobManager.fetchStatistics.summary.isEmpty {
                    Text(jobManager.fetchStatistics.summary)
                        .font(.caption2)
                        .foregroundColor(FlareVisual.paper.opacity(0.64))
                        .multilineTextAlignment(.center)
                }
                
                if let lastFetch = jobManager.fetchStatistics.lastFetchTime {
                    Text("Updated \(lastFetch, style: .relative)")
                        .font(.caption2)
                        .foregroundColor(FlareVisual.paper.opacity(0.64))
                }
            }
            .padding(.horizontal, 4)
        }
        .padding()
        .background(FlareVisual.ink)
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(FlareVisual.brass.opacity(0.45)),
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
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
                if let badge = badge {
                    Text(badge)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(FlareVisual.brass.opacity(0.25), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundStyle(isSelected ? FlareVisual.paper : FlareVisual.paper.opacity(0.72))
            .background(isSelected ? FlareVisual.ember.opacity(0.78) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

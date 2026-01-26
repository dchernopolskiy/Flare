//
//  JobRow.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import SwiftUI
import AppKit

struct JobRow: View {
    let job: Job
    @EnvironmentObject var jobManager: JobManager
    @Binding var sidebarVisible: Bool
    let isWindowMinimized: Bool
    
    @State private var isHovered = false
    @State private var dragOffset = CGSize.zero
    @State private var showingActionMenu = false
    
    private var isStarred: Bool {
        jobManager.starredJobIds.contains(job.id)
    }
    
    private var isApplied: Bool {
        jobManager.appliedJobIds.contains(job.id)
    }
    
    private var isSelected: Bool {
        jobManager.selectedJob?.id == job.id
    }
    
    var body: some View {
        ZStack {
            // Background with swipe indicators - only show during swipe
            if dragOffset.width != 0 {
                HStack(spacing: 0) {
                    // Left swipe indicator (Apply)
                    Rectangle()
                        .fill(Color.green.opacity(0.3))
                        .overlay(
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.horizontal)
                        )
                    
                    // Right swipe indicator (Dismiss)
                    Rectangle()
                        .fill(Color.red.opacity(0.3))
                        .overlay(
                            HStack {
                                Spacer()
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal)
                        )
                }
            }
            
            // Main content
            Button(action: { toggleSelection() }) {
                HStack(alignment: .top, spacing: 12) {
                    // Source Icon with Animation
                    ZStack {
                        Circle()
                            .fill(job.source.color.opacity(0.1))
                            .frame(width: 36, height: 36)
                        
                        Image(systemName: job.source.icon)
                            .font(.title3)
                            .foregroundColor(job.source.color)
                            .scaleEffect(isHovered ? 1.1 : 1.0)
                            .animation(.spring(response: 0.3), value: isHovered)
                    }
                    
                    // Job Info
                    VStack(alignment: .leading, spacing: 6) {
                        // Title with badges
                        HStack(alignment: .center, spacing: 6) {
                            Text(job.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            if job.isBumpedRecently {
                                RefreshedBadge()
                            } else if job.isRecent {
                                Badge()
                            }
                            
                            if isStarred {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.yellow)
                                    .font(.caption)
                                    .transition(.scale.combined(with: .opacity))
                            }
                            
                            if isApplied {
                                AppliedBadge()
                            }
                            
                            Spacer()
                        }
                        
                        // Location and Time
                        HStack(spacing: 12) {
                            Label(job.location, systemImage: "location")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            // Source badge
                            Text(job.source.rawValue)
                                .font(.caption2)
                                .foregroundColor(job.source.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(job.source.color.opacity(0.15))
                                .cornerRadius(4)
                            
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                Text(relativeTime(from: job.postingDate ?? job.firstSeenDate))
                                    .font(.caption)
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                }
                .padding()
                .background(backgroundView)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(dragOffset)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragOffset)
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = CGSize(
                        width: min(max(value.translation.width, -100), 100),
                        height: 0
                    )
                }
                .onEnded { value in
                    withAnimation(.spring()) {
                        if value.translation.width > 50 {
                            // Swipe right - Apply
                            jobManager.toggleAppliedStatus(for: job)
                            HapticFeedback.success()
                        } else if value.translation.width < -50 {
                            // Swipe left - Dismiss (could hide or mark as not interested)
                            HapticFeedback.warning()
                        }
                        dragOffset = .zero
                    }
                }
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            JobContextMenu(job: job)
        }
    }
    
    private var backgroundView: some View {
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.1))
            } else if isApplied {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(0.05))
            } else if isStarred {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.yellow.opacity(0.05))
            } else if job.isRecent {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.03))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.05))
            } else {
                Color.clear
            }
        }
    }
    
    private func toggleSelection() {
        withAnimation(.spring(response: 0.3)) {
            if isSelected {
                jobManager.selectedJob = nil
            } else {
                jobManager.selectedJob = job
                if isWindowMinimized && sidebarVisible {
                    sidebarVisible = false
                }
            }
        }
    }
    
    private func shareJob() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(job.url, forType: .string)
        
        // Show notification (optional - this will need implementation if toast system exists)
        // showToast("Link copied!")
    }
    
    private func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h ago"
        } else {
            return "\(Int(interval / 86400))d ago"
        }
    }
}

// MARK: - Haptic Feedback Helper

struct HapticFeedback {
    static func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
    
    static func warning() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    
    static func impact() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

// MARK: - Toast Notification

func showToast(_ message: String) {
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: Notification.Name("ShowToast"),
            object: message
        )
    }
}

struct Badge: View {
    var body: some View {
        Text("NEW")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.orange)
            .cornerRadius(4)
    }
}

struct AppliedBadge: View {
    var body: some View {
        Text("APPLIED")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.green)
            .cornerRadius(4)
    }
}

struct RefreshedBadge: View {
    var body: some View {
        Text("REPOSTED")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.blue)
            .cornerRadius(4)
    }
}


struct JobContextMenu: View {
    let job: Job
    @EnvironmentObject var jobManager: JobManager
    
    var body: some View {
        Group {
            Section("Quick Actions") {
                Button(action: { jobManager.openJob(job) }) {
                    Label("Apply Now", systemImage: "arrow.up.right.square")
                }
                
                Button(action: { jobManager.toggleStarred(for: job) }) {
                    Label(
                        jobManager.isJobStarred(job) ? "Remove Star" : "Add Star",
                        systemImage: jobManager.isJobStarred(job) ? "star.slash" : "star"
                    )
                }
                
                Button(action: { jobManager.toggleAppliedStatus(for: job) }) {
                    Label(
                        jobManager.isJobApplied(job) ? "Mark as Not Applied" : "Mark as Applied",
                        systemImage: jobManager.isJobApplied(job) ? "xmark.circle" : "checkmark.circle"
                    )
                }
            }
            
            Divider()
            
            Section("Share") {
                Button(action: { copyJobLink() }) {
                    Label("Copy Link", systemImage: "doc.on.doc")
                }
                
                Button(action: { shareViaEmail() }) {
                    Label("Share via Email", systemImage: "envelope")
                }
            }
            
            Divider()
            
            Section("Info") {
                Text("Posted: \(job.postingDate?.formatted() ?? "Unknown")")
                    .font(.caption)
                Text("Source: \(job.source.rawValue)")
                    .font(.caption)
                if let company = job.companyName {
                    Text("Company: \(company)")
                        .font(.caption)
                }
            }
        }
    }
    
    private func copyJobLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(job.url, forType: .string)
        showToast("Link copied!")
    }
    
    private func shareViaEmail() {
        let emailBody = "Check out this job: \(job.title) at \(job.companyName ?? job.source.rawValue)\n\n\(job.url)"
        let urlString = "mailto:?subject=Job Opportunity&body=\(emailBody.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ToastView: View {
    let message: String
    
    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text(message)
                .font(.callout)
                .fontWeight(.medium)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .shadow(radius: 4)
    }
}

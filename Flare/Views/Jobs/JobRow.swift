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
            if dragOffset.width != 0 {
                HStack(spacing: 0) {
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
            
            Button(action: { toggleSelection() }) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(job.source.color)
                            .frame(width: 36, height: 36)
                        
                        Image(systemName: job.source.icon)
                            .font(.title3)
                            .foregroundColor(job.source.flareMarkForeground)
                            .scaleEffect(isHovered ? 1.1 : 1.0)
                            .animation(.spring(response: 0.3), value: isHovered)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 6) {
                            Text(job.title)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundColor(FlareVisual.ink)
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
                        
                        HStack(spacing: 12) {
                            Label(job.location, systemImage: "location")
                                .font(.caption)
                                .foregroundColor(FlareVisual.fadedInk)
                            
                            Spacer()
                            
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(job.source.color)
                                    .frame(width: 6, height: 6)
                                Text(job.source.rawValue)
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .tracking(0.4)
                            }
                                .foregroundColor(FlareVisual.soot)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(FlareVisual.paper.opacity(0.78))
                                .overlay(Capsule().stroke(job.source.color.opacity(0.48), lineWidth: 1))
                                .clipShape(Capsule())
                            
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                Text(relativeTime(from: job.postingDate ?? job.firstSeenDate))
                                    .font(.caption)
                            }
                            .foregroundColor(FlareVisual.fadedInk)
                        }
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
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
                            jobManager.toggleAppliedStatus(for: job)
                            HapticFeedback.success()
                        } else if value.translation.width < -50 {
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
                RoundedRectangle(cornerRadius: FlareVisual.corner, style: .continuous)
                    .fill(FlareVisual.ember.opacity(0.26))
            } else if isApplied {
                RoundedRectangle(cornerRadius: FlareVisual.corner, style: .continuous)
                    .fill(FlareVisual.moss.opacity(0.14))
            } else if isStarred {
                RoundedRectangle(cornerRadius: FlareVisual.corner, style: .continuous)
                    .fill(FlareVisual.brass.opacity(0.16))
            } else if job.isRecent {
                RoundedRectangle(cornerRadius: FlareVisual.corner, style: .continuous)
                    .fill(FlareVisual.paper.opacity(0.72))
            } else if isHovered {
                RoundedRectangle(cornerRadius: FlareVisual.corner, style: .continuous)
                    .fill(FlareVisual.paper.opacity(0.86))
            } else {
                FlareVisual.paper.opacity(0.58)
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
            .foregroundColor(FlareVisual.paper)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(FlareVisual.ember, in: Capsule())
    }
}

struct AppliedBadge: View {
    var body: some View {
        Text("APPLIED")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(FlareVisual.paper)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(FlareVisual.moss, in: Capsule())
    }
}

struct RefreshedBadge: View {
    var body: some View {
        Text("REPOSTED")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(FlareVisual.paper)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(FlareVisual.soot, in: Capsule())
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

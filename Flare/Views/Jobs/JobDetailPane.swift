//
//  JobDetailPane.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import SwiftUI

struct JobDetailPane: View {
    let job: Job
    @EnvironmentObject var jobManager: JobManager
    @State private var selectedSection = "overview"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            JobDetailHeader(job: job)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    JobInfoSection(job: job)
                    
                    Divider()
                    
                    if job.requiredQualifications != nil || job.preferredQualifications != nil {
                        JobDetailSectionPicker(
                            selectedSection: $selectedSection,
                            hasRequired: job.requiredQualifications != nil,
                            hasPreferred: job.preferredQualifications != nil
                        )
                    }
                    
                    JobDetailContent(job: job, selectedSection: selectedSection)
                    
                    Spacer(minLength: 20)
                    
                    JobDetailActions(job: job)
                }
                .padding()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(Color(NSColor.separatorColor)),
            alignment: .leading
        )
    }
}

struct JobDetailHeader: View {
    let job: Job
    @EnvironmentObject var jobManager: JobManager
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Job Details")
                    .font(.title3)
                    .fontWeight(.semibold)
                
                HStack(spacing: 6) {
                    Image(systemName: job.source.icon)
                        .foregroundColor(job.source.color)
                        .font(.caption)
                    Text(job.companyName ?? job.source.rawValue)
                        .font(.caption)
                        .foregroundColor(job.source.color)
                }
            }
            
            Spacer()
            
            Button(action: {
                jobManager.selectedJob = nil
            }) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
}

struct JobInfoSection: View {
    let job: Job
    @EnvironmentObject var jobManager: JobManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title
            HStack {
                Text(job.title)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                if jobManager.isJobStarred(job) {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .font(.title3)
                }
                
                if jobManager.isJobApplied(job) {
                    AppliedBadge()
                }
            }
            
            // Metadata
            VStack(alignment: .leading, spacing: 8) {
                Label(job.location, systemImage: "location")
                    .font(.callout)
                
                if job.wasBumped, let postingDate = job.postingDate {
                    Label {
                        HStack(spacing: 4) {
                            Text("Refreshed")
                            Text(postingDate, style: .relative) + Text(" ago")
                            if let originalDate = job.originalPostingDate {
                                Text("•")
                                Text("Originally posted")
                                Text(originalDate, style: .relative) + Text(" ago")
                            }
                        }
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .font(.callout)
                    .foregroundColor(.blue)
                } else if let postingDate = job.postingDate {
                    Label {
                        Text(postingDate, style: .relative) + Text(" ago")
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.callout)
                } else {
                    Label {
                        Text("First seen: ") + Text(job.firstSeenDate, style: .relative) + Text(" ago")
                    } icon: {
                        Image(systemName: "eye")
                    }
                    .font(.callout)
                }
                
                if let department = job.department {
                    Label(department, systemImage: "folder")
                        .font(.callout)
                }
                
                if let category = job.category {
                    Label(category, systemImage: "tag")
                        .font(.callout)
                }
            }
            .foregroundColor(.secondary)
            
            // Work Flexibility Badge
            if let flexibility = job.workSiteFlexibility, !flexibility.isEmpty {
                Label(flexibility, systemImage: "house")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
            }
        }
    }
}

struct JobDetailSectionPicker: View {
    @Binding var selectedSection: String
    let hasRequired: Bool
    let hasPreferred: Bool
    
    var body: some View {
        Picker("Section", selection: $selectedSection) {
            Text("Overview").tag("overview")
            if hasRequired {
                Text("Required").tag("required")
            }
            if hasPreferred {
                Text("Preferred").tag("preferred")
            }
        }
        .pickerStyle(.segmented)
    }
}

struct JobDetailContent: View {
    let job: Job
    let selectedSection: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch selectedSection {
            case "overview":
                if !job.overview.isEmpty {
                    Text(job.overview)
                        .font(.body)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text("No description available.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .italic()
                }
                
            case "required":
                if let required = job.requiredQualifications {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Required Qualifications")
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        Text(required)
                            .font(.body)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                
            case "preferred":
                if let preferred = job.preferredQualifications {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Preferred Qualifications")
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        Text(preferred)
                            .font(.body)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                
            default:
                EmptyView()
            }
        }
    }
}

struct JobDetailActions: View {
    let job: Job
    @EnvironmentObject var jobManager: JobManager
    
    var body: some View {
        VStack(spacing: 8) {
            Button(action: {
                jobManager.openJob(job)
            }) {
                HStack {
                    Image(systemName: "arrow.up.right.square")
                    Text(job.applyButtonText)
                }
                .font(.callout)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            HStack(spacing: 8) {
                
                Button(action: {
                    jobManager.toggleStarred(for: job)
                }) {
                    HStack {
                        Image(systemName: jobManager.isJobStarred(job) ? "star.fill" : "star")
                        Text(jobManager.isJobStarred(job) ? "Starred" : "Star")
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(jobManager.isJobStarred(job) ? .yellow : .gray)
                
                Button(action: {
                    jobManager.toggleAppliedStatus(for: job)
                }) {
                    HStack {
                        Image(systemName: jobManager.isJobApplied(job) ? "xmark.circle" : "checkmark.circle")
                        Text(jobManager.isJobApplied(job) ? "Not Applied" : "Mark Applied")
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                
                Button(action: {
                    copyJobLink()
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.callout)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.bordered)
                .help("Copy job link")
            }
        }
    }
    
    private func copyJobLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(job.url, forType: .string)
    }
}

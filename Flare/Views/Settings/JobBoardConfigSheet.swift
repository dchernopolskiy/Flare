//
//  JobBoardConfigSheet.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import SwiftUI

struct JobBoardConfigSheet: View {
    @ObservedObject private var monitor = JobBoardMonitor.shared
    @EnvironmentObject var jobManager: JobManager
    @State private var newBoardName = ""
    @State private var newBoardURL = ""
    @State private var testingBoardId: UUID?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Configure Job Boards") {
                dismiss()
            }
            
            Divider()
            
            ScrollView {
                VStack(spacing: 20) {
                    AddBoardSection(
                        newBoardName: $newBoardName,
                        newBoardURL: $newBoardURL,
                        testingBoardId: $testingBoardId
                    )
                    
                    if !monitor.boardConfigs.isEmpty {
                        ConfiguredBoardsList(testingBoardId: $testingBoardId)
                    }
                    
                    SupportedPlatformsInfo()
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            SheetFooter(dismiss: { dismiss() })
        }
        .frame(width: 650, height: 550)
    }
}

// MARK: - Header

struct SheetHeader: View {
    let title: String
    let onClose: () -> Void
    
    var body: some View {
        HStack {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            
            Spacer()
            
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
}

// MARK: - Configured Boards List

struct ConfiguredBoardsList: View {
    @Binding var testingBoardId: UUID?
    @ObservedObject private var monitor = JobBoardMonitor.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Configured Boards", systemImage: "list.bullet")
                .font(.headline)
            
            ForEach(monitor.boardConfigs) { config in
                BoardConfigRow(config: config, testingBoardId: $testingBoardId)
            }
        }
    }
}

// MARK: - Board Config Row

struct BoardConfigRow: View {
    let config: JobBoardConfig
    @Binding var testingBoardId: UUID?
    @ObservedObject private var monitor = JobBoardMonitor.shared
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Platform Icon
            Image(systemName: config.source.icon)
                .foregroundColor(config.source.color)
                .font(.title3)
                .frame(width: 30)
            
            // Board Info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(config.displayName)
                        .font(.headline)
                    
                    if !config.isSupported {
                        Text("Coming Soon")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                
                Text(config.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(config.source.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(config.source.color.opacity(0.2))
                        .cornerRadius(4)
                    
                    if let lastFetched = config.lastFetched {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption2)
                            Text("Last: \(lastFetched, style: .relative) ago")
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)
                    }
                    
                    if let testResult = monitor.testResults[config.id] {
                        HStack(spacing: 4) {
                            if testResult == "Testing..." {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else if testResult.hasPrefix("✅") {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                            }
                            
                            Text(testResult.replacingOccurrences(of: "✅ ", with: "").replacingOccurrences(of: "❌ ", with: ""))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(testResult.hasPrefix("✅") ? .green : testResult == "Testing..." ? .blue : .red)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(testResult.hasPrefix("✅") ? Color.green.opacity(0.1) :
                                      testResult == "Testing..." ? Color.blue.opacity(0.1) :
                                      Color.red.opacity(0.1))
                        )
                    }
                }
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 8) {
                // Test Button
                Button(action: {
                    testBoard()
                }) {
                    if testingBoardId == config.id {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!config.isSupported || testingBoardId != nil)
                .help("Test board connection")
                
                // Enable/Disable Toggle
                Toggle("", isOn: Binding(
                    get: { config.isEnabled },
                    set: { newValue in
                        var updated = config
                        updated.isEnabled = newValue
                        monitor.updateBoardConfig(updated)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!config.isSupported)
                .help(config.isEnabled ? "Enabled" : "Disabled")
                
                // Delete Button
                Button(action: {
                    deleteBoard()
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete board")
            }
        }
        .padding()
        .background(config.isEnabled ? Color(NSColor.controlBackgroundColor) : Color.gray.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(config.isEnabled ? Color.clear : Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func testBoard() {
        testingBoardId = config.id
        Task {
            await monitor.testSingleBoard(config)
            await MainActor.run {
                testingBoardId = nil
            }
        }
    }
    
    private func deleteBoard() {
        if let index = monitor.boardConfigs.firstIndex(where: { $0.id == config.id }) {
            monitor.removeBoardConfig(at: index)
        }
    }
}

// MARK: - Source Detection Badge

struct SourceDetectionBadge: View {
    let source: JobSource?
    
    var body: some View {
        HStack(spacing: 6) {
            if let source = source {
                Image(systemName: source.icon)
                    .foregroundColor(source.color)
                    .font(.caption)
                
                if source.isSupported {
                    Text("Detected: \(source.rawValue)")
                        .foregroundColor(.green)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Text("Detected: \(source.rawValue) (Not yet supported)")
                        .foregroundColor(.orange)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text("Platform not recognized")
                    .foregroundColor(.red)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (source?.isSupported ?? false) ? Color.green.opacity(0.1) :
            source != nil ? Color.orange.opacity(0.1) : Color.red.opacity(0.1)
        )
        .cornerRadius(6)
    }
}

// MARK: - Supported Platforms Info

struct SupportedPlatformsInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Platform Support", systemImage: "info.circle")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                ForEach(JobSource.allCases, id: \.self) { source in
                    if source != .microsoft && source != .apple && source != .google && source != .tiktok && source != .snap && source != .amd && source != .meta {
                        HStack {
                            Image(systemName: source.icon)
                                .foregroundColor(source.color)
                                .frame(width: 20)
                            Text(source.rawValue)
                            Spacer()
                            if source.isSupported {
                                Label("Supported", systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            } else {
                                Label("Coming Soon", systemImage: "clock.circle")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(6)
        }
    }
}

// MARK: - Footer

struct SheetFooter: View {
    let dismiss: () -> Void
    @ObservedObject private var monitor = JobBoardMonitor.shared
    
    var body: some View {
        HStack {
            if let error = monitor.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
            }
            
            Spacer()
            
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
        }
        .padding()
    }
}

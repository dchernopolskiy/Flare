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
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: config.source.icon)
                    .foregroundColor(config.source.color)
                    .font(.title3)
                    .frame(width: 30)

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

                    HStack(spacing: 8) {
                        if let method = config.parsingMethod {
                            Label(method.rawValue, systemImage: method.icon)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15))
                                .cornerRadius(4)
                        } else {
                            Text(config.source.rawValue)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(config.source.color.opacity(0.2))
                                .cornerRadius(4)
                        }

                        if let jobCount = config.lastJobCount {
                            Text("\(jobCount) jobs")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if let lastFetched = config.lastFetched {
                            Text("\(lastFetched, style: .relative) ago")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let testResult = monitor.testResults[config.id] {
                        let isSuccess = testResult.hasPrefix("Found")
                        let isLoading = testResult == "Testing..."
                        HStack(spacing: 4) {
                            if isLoading {
                                ProgressView()
                                    .scaleEffect(0.6)
                            } else if !isSuccess {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                    .font(.caption2)
                            }
                            Text(testResult)
                                .font(.caption2)
                                .foregroundColor(isSuccess ? .green : isLoading ? .blue : .red)
                        }
                    }

                    if let parsingStatus = monitor.parsingStatus[config.id] {
                        Text(parsingStatus)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Show details")

                    Button(action: testBoard) {
                        if testingBoardId == config.id {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!config.isSupported || testingBoardId != nil)
                    .help("Test board")

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

                    Button(action: deleteBoard) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete")
                }
            }
            .padding()

            if isExpanded {
                Divider()
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        Text("Original:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(config.url)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }

                    if let queryURL = config.detectedATSURL, queryURL != config.url {
                        HStack(spacing: 6) {
                            Image(systemName: config.parsingMethod?.icon ?? "antenna.radiowaves.left.and.right")
                                .foregroundColor(.blue)
                                .frame(width: 16)
                            Text("Query:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(queryURL)
                                .font(.caption)
                                .foregroundColor(.blue)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        Text("Method:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(config.parsingMethodDisplay)
                            .font(.caption)
                            .foregroundColor(.primary)
                        if let atsType = config.detectedATSType {
                            Text("(\(atsType.capitalized))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
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

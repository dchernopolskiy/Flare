//
//  JobBoardsView.swift
//  MSJobMonitor
//
//  Created by mediaserver on 10/9/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct JobBoardsView: View {
    @ObservedObject private var monitor = JobBoardMonitor.shared
    @EnvironmentObject var jobManager: JobManager
    @State private var newBoardName = ""
    @State private var newBoardURL = ""
    @State private var testingBoardId: UUID?
    @State private var showImportDialog = false
    @State private var showExportDialog = false
    @State private var importResult: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            Text("Job Boards")
                .font(.title2)
                .fontWeight(.semibold)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Import/Export Section
                    ImportExportSection(
                        showImportDialog: $showImportDialog,
                        showExportDialog: $showExportDialog,
                        importResult: $importResult
                    )
                    
                    // Add Board Section
                    AddBoardSection(
                        newBoardName: $newBoardName,
                        newBoardURL: $newBoardURL,
                        testingBoardId: $testingBoardId
                    )
                    
                    // Configured Boards List
                    if !monitor.boardConfigs.isEmpty {
                        ConfiguredBoardsSection(testingBoardId: $testingBoardId)
                    } else {
                        EmptyBoardsView()
                    }
                    
                    // Supported Platforms Info
                    SupportedPlatformsSection()
                }
                .padding()
            }
        }
        .padding()
        .fileImporter(
            isPresented: $showImportDialog,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result: result)
        }
        .fileExporter(
            isPresented: $showExportDialog,
            document: JobBoardsDocument(content: monitor.exportBoards()),
            contentType: .plainText,
            defaultFilename: "job-boards-export.txt"
        ) { result in
            switch result {
            case .success:
                importResult = "Exported successfully!"
            case .failure(let error):
                importResult = "Export failed: \(error.localizedDescription)"
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                importResult = nil
            }
        }
    }
    
    private func handleImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let result = monitor.importBoards(from: content)
                
                if result.failed.isEmpty {
                    importResult = "Imported \(result.added) boards successfully!"
                } else {
                    importResult = "Imported \(result.added) boards, \(result.failed.count) failed"
                }
            } catch {
                importResult = "Import failed: \(error.localizedDescription)"
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                importResult = nil
            }
            
        case .failure(let error):
            importResult = "Import failed: \(error.localizedDescription)"
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                importResult = nil
            }
        }
    }
}

// MARK: - Import/Export Section

struct ImportExportSection: View {
    @ObservedObject private var monitor = JobBoardMonitor.shared
    @Binding var showImportDialog: Bool
    @Binding var showExportDialog: Bool
    @Binding var importResult: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Import / Export", systemImage: "arrow.up.arrow.down.circle")
                .font(.headline)
            
            HStack(spacing: 12) {
                Button(action: { showImportDialog = true }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import from File")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                
                Button(action: { showExportDialog = true }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export to File")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(monitor.boardConfigs.isEmpty)
            }
            
            if let result = importResult {
                HStack {
                    Text(result)
                        .font(.callout)
                        .foregroundColor(result.contains("successfully") ? .green : .red)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(result.contains("successfully") ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                )
            }
            
            Text("Export format: URL | Name | Enabled")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Add Board Section

struct AddBoardSection: View {
    @Binding var newBoardName: String
    @Binding var newBoardURL: String
    @Binding var testingBoardId: UUID?
    @State private var detectionPreview: JobBoardMonitor.DetectionPreview?
    @ObservedObject private var monitor = JobBoardMonitor.shared
    @EnvironmentObject var jobManager: JobManager

    private var isValidURL: Bool {
        guard !newBoardURL.isEmpty else { return false }
        return URL(string: newBoardURL) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add Job Board", systemImage: "plus.circle.fill")
                .font(.headline)

            TextField("Board Name (e.g., GitLab, Stripe)", text: $newBoardName)
                .textFieldStyle(.roundedBorder)

            TextField("Board URL (job listing page)", text: $newBoardURL)
                .textFieldStyle(.roundedBorder)
                .onChange(of: newBoardURL) { _, _ in
                    detectionPreview = nil
                }

            if monitor.detectionInProgress {
                DetectionProgressView(status: monitor.detectionStatus)
            }

            Text("Supported: Greenhouse, Ashbyhq, Lever, Workday, and custom sites with AI parsing")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: startDetection) {
                HStack {
                    if monitor.detectionInProgress {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Detecting...")
                    } else {
                        Image(systemName: "magnifyingglass.circle.fill")
                        Text("Detect & Preview")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isValidURL || monitor.detectionInProgress)

            if !monitor.testResults.isEmpty {
                TestResultsView()
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .sheet(item: $detectionPreview) { preview in
            DetectionConfirmationSheet(
                boardName: $newBoardName,
                boardURL: newBoardURL,
                preview: preview,
                onConfirm: { addBoard(with: preview) },
                onCancel: { detectionPreview = nil }
            )
        }
    }

    private func startDetection() {
        guard let url = URL(string: newBoardURL) else { return }

        Task {
            if let preview = await monitor.detectAndPreview(url: url) {
                await MainActor.run {
                    if newBoardName.isEmpty {
                        newBoardName = extractCompanyName(from: newBoardURL)
                    }
                    detectionPreview = preview
                }
            }
        }
    }

    private func addBoard(with preview: JobBoardMonitor.DetectionPreview) {
        let finalUrl = preview.queryURL

        guard var config = JobBoardConfig(
            name: newBoardName.isEmpty ? extractCompanyName(from: finalUrl) : newBoardName,
            url: newBoardURL,
            detectedATSURL: preview.queryURL != newBoardURL ? preview.queryURL : nil,
            detectedATSType: preview.atsType,
            parsingMethod: preview.parsingMethod
        ) else { return }

        config.lastJobCount = preview.jobCount
        monitor.addBoardConfig(config)

        newBoardName = ""
        newBoardURL = ""
        detectionPreview = nil
    }

    private func extractCompanyName(from urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "" }

        if let host = url.host {
            let parts = host.components(separatedBy: ".")
            if !parts.isEmpty && !["www", "careers", "jobs"].contains(parts[0]) {
                return parts[0].capitalized
            }
        }

        return ""
    }
}

// MARK: - Detection Progress View

struct DetectionProgressView: View {
    let status: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text(status)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Detection Confirmation Sheet

struct DetectionConfirmationSheet: View {
    @Binding var boardName: String
    let boardURL: String
    let preview: JobBoardMonitor.DetectionPreview
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Job Board?")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Found \(preview.jobCount) jobs")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("via \(preview.parsingMethod.rawValue)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 12) {
                    TextField("Board Name", text: $boardName)
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Original URL", systemImage: "link")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(boardURL)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .lineLimit(2)
                    }

                    if preview.queryURL != boardURL {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Query URL", systemImage: preview.parsingMethod.icon)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(preview.queryURL)
                                .font(.caption)
                                .foregroundColor(.blue)
                                .lineLimit(2)
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: preview.parsingMethod.icon)
                            .foregroundColor(.blue)
                        Text("Parsing: \(preview.parsingMethod.rawValue)")
                            .font(.callout)
                        if let atsType = preview.atsType {
                            Text("(\(atsType.capitalized))")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            .padding()

            Divider()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)

                Spacer()

                Button("Add Job Board") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
            .padding()
        }
        .frame(width: 450)
    }
}

struct TestResultsView: View {
    @ObservedObject private var monitor = JobBoardMonitor.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recent Test Results", systemImage: "checkmark.circle")
                .font(.headline)
            
            ForEach(Array(monitor.testResults.keys), id: \.self) { boardId in
                if let result = monitor.testResults[boardId],
                   let boardName = monitor.boardConfigs.first(where: { $0.id == boardId })?.displayName {
                    HStack {
                        Text(boardName)
                            .font(.callout)
                            .fontWeight(.medium)
                        Spacer()
                        Text(result)
                            .font(.callout)
                            .foregroundColor(result.hasPrefix("Found") ? .green : .red)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(4)
                }
            }
        }
        .padding()
        .background(Color.blue.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Configured Boards Section

struct ConfiguredBoardsSection: View {
    @Binding var testingBoardId: UUID?
    @ObservedObject private var monitor = JobBoardMonitor.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Configured Boards (\(monitor.boardConfigs.count))", systemImage: "list.bullet")
                    .font(.headline)
                
                Spacer()
                
                Text("\(monitor.boardConfigs.filter { $0.isEnabled }.count) enabled")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ForEach(monitor.boardConfigs) { config in
                BoardConfigRow(config: config, testingBoardId: $testingBoardId)
            }
        }
    }
}

// MARK: - Empty State

struct EmptyBoardsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No Job Boards Configured")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Add job boards above to monitor additional companies")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Supported Platforms Section

struct SupportedPlatformsSection: View {
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

// MARK: - File Document for Export

struct JobBoardsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    
    var content: String
    
    init(content: String) {
        self.content = content
    }
    
    init(configuration: ReadConfiguration) throws {
        content = ""
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = content.data(using: .utf8)!
        return FileWrapper(regularFileWithContents: data)
    }
}


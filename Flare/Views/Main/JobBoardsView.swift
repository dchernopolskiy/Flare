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
                importResult = "✅ Exported successfully!"
            case .failure(let error):
                importResult = "❌ Export failed: \(error.localizedDescription)"
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
                    importResult = "✅ Imported \(result.added) boards successfully!"
                } else {
                    importResult = "Imported \(result.added) boards, \(result.failed.count) failed"
                }
            } catch {
                importResult = "❌ Import failed: \(error.localizedDescription)"
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                importResult = nil
            }
            
        case .failure(let error):
            importResult = "❌ Import failed: \(error.localizedDescription)"
            
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
                        .foregroundColor(result.hasPrefix("✅") ? .green : result.hasPrefix("❌") ? .orange : .red)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(result.hasPrefix("✅") ? Color.green.opacity(0.1) :
                              result.hasPrefix("❌") ? Color.orange.opacity(0.1) :
                              Color.red.opacity(0.1))
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

// MARK: - Add Board Section (reused from JobBoardConfigSheet)

struct AddBoardSection: View {
    @Binding var newBoardName: String
    @Binding var newBoardURL: String
    @Binding var testingBoardId: UUID?
    @State private var isDetecting = false
    @State private var detectionResult: ATSDetectorService.DetectionResult?
    @State private var urlToUse: String = ""
    @ObservedObject private var monitor = JobBoardMonitor.shared
    @EnvironmentObject var jobManager: JobManager
    
    private var detectedSource: JobSource? {
        JobSource.detectFromURL(urlToUse.isEmpty ? newBoardURL : urlToUse)
    }
    
    private var isDirectATSLink: Bool {
        guard !newBoardURL.isEmpty else { return false }
        return JobSource.detectFromURL(newBoardURL) != nil
    }
    
    private var canAddBoard: Bool {
        if isDirectATSLink {
            // Direct ATS link - can add immediately
            return detectedSource?.isSupported ?? false
        } else {
            // Not a direct link - need to detect first and have a valid detected URL
            return !urlToUse.isEmpty && (detectedSource?.isSupported ?? false)
        }
    }
    
    private var needsDetection: Bool {
        if isDirectATSLink {
            return false
        }
        
        if let result = detectionResult,
           (result.confidence == .likely || result.confidence == .certain),
           result.source?.isSupported ?? false {
            return false
        }
        
        if !urlToUse.isEmpty {
            return false
        }
        
        return true
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add Job Board", systemImage: "plus.circle.fill")
                .font(.headline)
            
            TextField("Board Name (e.g., GitLab, Stripe)", text: $newBoardName)
                .textFieldStyle(.roundedBorder)
            
            TextField("Board URL (job listing page)", text: $newBoardURL)
                .textFieldStyle(.roundedBorder)
                .onChange(of: newBoardURL) { _ in
                    detectionResult = nil
                    urlToUse = ""
                }
            
            if let result = detectionResult {
                DetectionResultView(result: result)
                
                if let atsUrl = result.actualATSUrl, atsUrl != newBoardURL {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Detected ATS URL", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                            .fontWeight(.semibold)
                        
                        Text(atsUrl)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(4)
                        
                        Text("✓ This URL will be used for the job board")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .fontWeight(.semibold)
                    }
                    .padding()
                    .background(Color.green.opacity(0.05))
                    .cornerRadius(8)
                }
            }
            
            // Status message for direct ATS links
            if isDirectATSLink, let source = detectedSource {
                HStack(spacing: 6) {
                    Image(systemName: source == .unknown ? "globe" : "checkmark.circle.fill")
                        .foregroundColor(source == .unknown ? .orange : .green)
                    if source == .unknown {
                        Text("Custom career site - will use AI parsing if enabled in Settings")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fontWeight(.medium)
                    } else {
                        Text("Direct \(source.rawValue) link detected - ready to add")
                            .font(.caption)
                            .foregroundColor(.green)
                            .fontWeight(.medium)
                    }
                    if !source.isSupported {
                        Text("(Coming soon)")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background((source == .unknown ? Color.orange : Color.green).opacity(0.1))
                .cornerRadius(6)
            }
            
            Text("Supported: Greenhouse, Ashbyhq, Lever, Workday, and custom sites with AI parsing")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Action buttons
            HStack(spacing: 12) {
                // Detect ATS button
                if needsDetection {
                    Button(action: detectATS) {
                        HStack {
                            if isDetecting {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Detecting...")
                            } else {
                                Image(systemName: "magnifyingglass.circle.fill")
                                Text("Detect ATS")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newBoardURL.isEmpty || isDetecting)
                }
                
                // Add & Test button
                if needsDetection {
                    Button(action: addBoard) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add & Test Board")
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canAddBoard || testingBoardId != nil)
                } else {
                    Button(action: addBoard) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add & Test Board")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddBoard || testingBoardId != nil)
                }
                
                if testingBoardId != nil {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Testing...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if !monitor.testResults.isEmpty {
                TestResultsView()
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private func addBoard() {
        let finalUrl = urlToUse.isEmpty ? newBoardURL : urlToUse
            
        guard let config = JobBoardConfig(
            name: newBoardName.isEmpty ? extractCompanyName(from: finalUrl) : newBoardName,
            url: finalUrl
        ) else { return }
        
        monitor.addBoardConfig(config)
        
        testingBoardId = config.id
        Task {
            await monitor.testSingleBoard(config)
            await MainActor.run {
                testingBoardId = nil
            }
        }
        
        newBoardName = ""
        newBoardURL = ""
        urlToUse = ""
        detectionResult = nil
    }
    
    private func detectATS() {
        guard let url = URL(string: newBoardURL) else {
            detectionResult = ATSDetectorService.DetectionResult(
                source: nil,
                confidence: .notDetected,
                apiEndpoint: nil,
                actualATSUrl: nil,
                message: "Invalid URL format"
            )
            return
        }
        
        isDetecting = true
        detectionResult = nil
        urlToUse = ""
        
        Task {
            do {
                // Use enhanced detection instead
                let result = try await ATSDetectorService.shared.detectATSEnhanced(from: url)
                
                await MainActor.run {
                    detectionResult = result
                    
                    if let atsUrl = result.actualATSUrl {
                        urlToUse = atsUrl
                        
                        if newBoardName.isEmpty, result.source != nil {
                            newBoardName = extractCompanyName(from: atsUrl)
                        }
                    }
                    
                    isDetecting = false
                }
            } catch {
                await MainActor.run {
                    detectionResult = ATSDetectorService.DetectionResult(
                        source: nil,
                        confidence: .notDetected,
                        apiEndpoint: nil,
                        actualATSUrl: nil,
                        message: "Error: \(error.localizedDescription)"
                    )
                    isDetecting = false
                }
            }
        }
    }
        
    private func extractCompanyName(from urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "" }
        
        if let host = url.host {
            let parts = host.components(separatedBy: ".")
            if parts.count > 0 && !["www", "careers", "jobs"].contains(parts[0]) {
                return parts[0].capitalized
            }
        }
        
        return ""
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
                            .foregroundColor(result.hasPrefix("✅") ? .green : .red)
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

struct DetectionResultView: View {
    let result: ATSDetectorService.DetectionResult
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
            
            Text(result.message)
                .font(.callout)
                .foregroundColor(textColor)
            
            Spacer()
            
            if let source = result.source {
                Label(source.rawValue, systemImage: source.icon)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(source.color.opacity(0.1))
                    .cornerRadius(6)
            }
        }
        .padding()
        .background(backgroundColor)
        .cornerRadius(8)
    }
    
    private var iconName: String {
        switch result.confidence {
        case .certain: return "checkmark.circle.fill"
        case .likely: return "questionmark.circle.fill"
        case .uncertain: return "exclamationmark.triangle.fill"
        case .notDetected: return "xmark.circle.fill"
        }
    }
    
    private var iconColor: Color {
        switch result.confidence {
        case .certain: return .green
        case .likely: return .blue
        case .uncertain: return .orange
        case .notDetected: return .red
        }
    }
    
    private var textColor: Color {
        switch result.confidence {
        case .certain, .likely: return .primary
        case .uncertain, .notDetected: return .secondary
        }
    }
    
    private var backgroundColor: Color {
        switch result.confidence {
        case .certain: return .green.opacity(0.1)
        case .likely: return .blue.opacity(0.1)
        case .uncertain: return .orange.opacity(0.1)
        case .notDetected: return .red.opacity(0.1)
        }
    }
}

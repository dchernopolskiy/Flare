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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Job Boards")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(FlareVisual.ink)
                    Text("Add company career pages, confirm the connection, then keep them in one place.")
                        .font(.callout)
                        .foregroundColor(FlareVisual.fadedInk)
                }

                Spacer()

                Text("\(monitor.boardConfigs.count) saved")
                    .font(.caption.weight(.medium))
                    .foregroundColor(FlareVisual.soot)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("\(monitor.boardConfigs.count) saved job boards")
            }
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ImportExportSection(
                        showImportDialog: $showImportDialog,
                        showExportDialog: $showExportDialog,
                        importResult: $importResult
                    )
                    
                    AddBoardSection(
                        newBoardName: $newBoardName,
                        newBoardURL: $newBoardURL,
                        testingBoardId: $testingBoardId
                    )
                    
                    if !monitor.boardConfigs.isEmpty {
                        ConfiguredBoardsSection(testingBoardId: $testingBoardId)
                    } else {
                        EmptyBoardsView()
                    }
                    
                    SupportedPlatformsSection()
                }
                .padding()
            }
        }
        .padding()
        .preferredColorScheme(.light)
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
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Move boards in or out", systemImage: "arrow.up.arrow.down.circle")
                    .font(.headline)
                Text("Use a text export to move your saved company sources between Macs.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
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
                .accessibilityHint("Choose a job board export file to add its boards")
                
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
                .accessibilityHint("Save your current job board list as a text file")
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
            
            Text("Format: URL | Name | Enabled")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(FlareVisual.paper)
        .foregroundStyle(FlareVisual.soot)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FlareVisual.ink.opacity(0.16), lineWidth: 1))
        .cornerRadius(8)
    }
}

// MARK: - Add Board Section

struct AddBoardSection: View {
    @Binding var newBoardName: String
    @Binding var newBoardURL: String
    @Binding var testingBoardId: UUID?
    @State private var detectionPreview: JobBoardMonitor.DetectionPreview?
    @State private var detectionFailed = false
    @State private var detectionError: String?
    @FocusState private var focusedField: Field?
    @ObservedObject private var monitor = JobBoardMonitor.shared
    @EnvironmentObject var jobManager: JobManager

    private var isValidURL: Bool {
        guard !newBoardURL.isEmpty else { return false }
        return JobBoardConfig.normalizedURLString(newBoardURL) != nil
    }

    private var isDuplicateURL: Bool {
        guard let normalizedURL = JobBoardConfig.normalizedURLString(newBoardURL) else { return false }
        return monitor.boardConfigs.contains { $0.url == normalizedURL }
    }

    private enum Field: Hashable {
        case name
        case url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Add a company board", systemImage: "plus.circle.fill")
                    .font(.headline)
                Text("Paste the public careers page. Flare will find the best source and show the jobs it can reach before saving anything.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("1. Identify the company")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                TextField("Company name (optional)", text: $newBoardName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .accessibilityLabel("Company name, optional")
                    .accessibilityHint("Flare can suggest a name from the board URL")

                TextField("Careers or job board URL", text: $newBoardURL)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .url)
                    .accessibilityLabel("Careers or job board URL")
                    .accessibilityHint("Enter the public job listing page for the company")
                    .onSubmit(startDetection)
                .onChange(of: newBoardURL) { _, _ in
                    detectionPreview = nil
                    detectionFailed = false
                    detectionError = nil
                }

                if !newBoardURL.isEmpty && !isValidURL {
                    Label("Enter a complete web address, such as https://company.com/careers.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if isDuplicateURL {
                    Label("This board is already saved.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if monitor.detectionInProgress {
                DetectionProgressView(status: monitor.detectionStatus)
            }

            if detectionFailed {
                DetectionFailedView(errorMessage: detectionError)
            }

            Button(action: startDetection) {
                HStack {
                    if monitor.detectionInProgress {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Detecting...")
                    } else {
                        Image(systemName: "magnifyingglass.circle.fill")
                        Text("2. Detect and preview jobs")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isValidURL || isDuplicateURL || monitor.detectionInProgress)
            .accessibilityHint("Tests the careers page before adding it to your saved boards")

            Text("Works with Greenhouse, Ashby, Lever, Workday, and custom sites when AI parsing is enabled.")
                .font(.caption)
                .foregroundColor(.secondary)

            if !monitor.testResults.isEmpty {
                TestResultsView()
            }
        }
        .padding()
        .background(FlareVisual.paper, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(FlareVisual.soot)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(FlareVisual.ink.opacity(0.16), lineWidth: 1))
        .sheet(item: $detectionPreview) { preview in
            DetectionConfirmationSheet(
                boardName: $newBoardName,
                boardURL: newBoardURL,
                preview: preview,
                onConfirm: { [boardURL = newBoardURL] in addBoard(with: preview, boardURL: boardURL) },
                onCancel: { detectionPreview = nil }
            )
        }
    }

    private func startDetection() {
        guard let normalizedURL = JobBoardConfig.normalizedURLString(newBoardURL),
              let url = URL(string: normalizedURL) else { return }

        detectionFailed = false
        detectionError = nil

        let requestedURL = normalizedURL
        Task {
            if let preview = await monitor.detectAndPreview(url: url) {
                await MainActor.run {
                    guard JobBoardConfig.normalizedURLString(newBoardURL) == requestedURL else { return }
                    if newBoardName.isEmpty {
                        newBoardName = extractCompanyName(from: newBoardURL)
                    }
                    detectionPreview = preview
                }
            } else {
                await MainActor.run {
                    guard JobBoardConfig.normalizedURLString(newBoardURL) == requestedURL else { return }
                    detectionFailed = true
                    let aiEnabled = UserDefaults.standard.bool(forKey: "enableAIParser")
                    if !aiEnabled {
                        detectionError = "No jobs found. Try enabling AI parsing in Settings for better detection."
                    } else {
                        detectionError = "Could not find jobs on this page. The site may use an unsupported format or require login."
                    }
                }
            }
        }
    }

    private func addBoard(with preview: JobBoardMonitor.DetectionPreview, boardURL: String) {
        let finalUrl = preview.queryURL
        guard let normalizedBoardURL = JobBoardConfig.normalizedURLString(boardURL) else { return }

        guard var config = JobBoardConfig(
            name: newBoardName.isEmpty ? extractCompanyName(from: finalUrl) : newBoardName,
            url: normalizedBoardURL,
            detectedATSURL: preview.queryURL != normalizedBoardURL ? preview.queryURL : nil,
            detectedATSType: preview.atsType,
            parsingMethod: preview.parsingMethod
        ) else { return }

        config.lastJobCount = preview.jobCount
        monitor.addBoardConfig(config)

        newBoardName = ""
        newBoardURL = ""
        detectionPreview = nil
        focusedField = .url
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Detecting job board. \(status)")
    }
}

// MARK: - Detection Failed View

struct DetectionFailedView: View {
    let errorMessage: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text("Unable to Add Job Board")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                Text(errorMessage ?? "No jobs were found on this page.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
        .accessibilityElement(children: .combine)
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
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ready to monitor")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Review the connection, then save this board.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close board preview")
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
                        Text("Flare can reach this board via \(preview.parsingMethod.rawValue).")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)

                if let evidence = preview.evidenceSummary {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("WHY THIS LOOKS RIGHT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(0.9)
                            .foregroundStyle(FlareVisual.fadedInk)
                        Text(evidence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FlareVisual.paper.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Board name")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    TextField("Board name", text: $boardName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Board name")

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Careers page", systemImage: "link")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(boardURL)
                            .font(.caption)
                            .foregroundColor(.primary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    }

                    if preview.queryURL != boardURL {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Connection Flare will use", systemImage: preview.parsingMethod.icon)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(preview.queryURL)
                                .font(.caption)
                                .foregroundColor(.blue)
                            .lineLimit(2)
                            .textSelection(.enabled)
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
                .accessibilityHint("Saves this verified board and begins monitoring it")
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
                    .background(FlareVisual.paperShadow.opacity(0.45))
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
                    .foregroundStyle(FlareVisual.ink)
                
                Spacer()
                
                Text("\(monitor.boardConfigs.filter { $0.isEnabled }.count) enabled")
                    .font(.caption)
                    .foregroundColor(FlareVisual.fadedInk)
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
                .foregroundStyle(FlareVisual.ink)
            
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
            .background(FlareVisual.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FlareVisual.ink.opacity(0.16), lineWidth: 1))
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

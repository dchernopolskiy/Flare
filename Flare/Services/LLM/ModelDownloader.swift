//
//  ModelDownloader 2.swift
//  Flare
//
//  Created by Dan on 12/9/25.
//

import Foundation

actor ModelDownloader {
    static let shared = ModelDownloader()

    private let modelURL = "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
    private let modelFileName = "llama32-3b-instruct-q4_k_m.gguf"

    private var isDownloading = false
    private var downloadTask: URLSessionDownloadTask?

    private init() {}

    func getModelPath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let containerURL = appSupport.deletingLastPathComponent().deletingLastPathComponent()
        let flareDir = containerURL.appendingPathComponent("Data/Library/Application Support/Flare")
        try? FileManager.default.createDirectory(at: flareDir, withIntermediateDirectories: true)
        return flareDir.appendingPathComponent(modelFileName)
    }

    func isModelDownloaded() -> Bool {
        let path = getModelPath()
        let exists = FileManager.default.fileExists(atPath: path.path)
        if exists {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
               let fileSize = attrs[.size] as? Int64 {
                let sizeInGB = Double(fileSize) / 1_000_000_000
                print("[ModelDownloader] Model exists, size: \(String(format: "%.2f", sizeInGB)) GB")
                return fileSize > 1_000_000_000 // At least 1GB
            }
        }
        return false
    }

    func downloadModel(progressHandler: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        let modelPath = getModelPath()

        if isModelDownloaded() {
            print("[ModelDownloader] Model already exists at: \(modelPath.path)")
            await MainActor.run {
                progressHandler(1.0, "Model ready")
            }
            return modelPath
        }

        guard !isDownloading else {
            throw ModelDownloadError.alreadyDownloading
        }

        isDownloading = true
        defer { isDownloading = false }

        print("[ModelDownloader] Starting download from: \(modelURL)")
        await MainActor.run {
            progressHandler(0.0, "Starting download...")
        }

        guard let url = URL(string: modelURL) else {
            throw ModelDownloadError.invalidURL
        }

        let delegate = DownloadDelegate { progress, status in
            Task { @MainActor in
                progressHandler(progress, status)
            }
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300 // 5 minutes
        configuration.timeoutIntervalForResource = 7200 // 2 hours
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        do {
            let (downloadedURL, response) = try await session.download(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ModelDownloadError.downloadFailed
            }

            if FileManager.default.fileExists(atPath: modelPath.path) {
                try FileManager.default.removeItem(at: modelPath)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: modelPath)

            print("[ModelDownloader] Download complete: \(modelPath.path)")
            await MainActor.run {
                progressHandler(1.0, "Download complete!")
            }

            return modelPath

        } catch {
            print("[ModelDownloader] Download failed: \(error)")
            await MainActor.run {
                progressHandler(0.0, "Download failed")
            }
            throw ModelDownloadError.downloadFailed
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        print("[ModelDownloader] Download cancelled")
    }

    func deleteModel() throws {
        let path = getModelPath()
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
            print("[ModelDownloader] Deleted model at: \(path.path)")
        }
    }

    func getModelSize() -> Double? {
        let path = getModelPath()
        guard FileManager.default.fileExists(atPath: path.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let fileSize = attrs[.size] as? Int64 else {
            return nil
        }
        return Double(fileSize) / 1_000_000_000
    }
}

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Double, String) -> Void

    init(progressHandler: @escaping (Double, String) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let downloadedMB = Double(totalBytesWritten) / 1_000_000
        let totalMB = Double(totalBytesExpectedToWrite) / 1_000_000
        let status = String(format: "Downloading: %.0f / %.0f MB", downloadedMB, totalMB)

        progressHandler(progress, status)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        progressHandler(1.0, "Processing...")
    }
}

enum ModelDownloadError: Error, LocalizedError {
    case invalidURL
    case downloadFailed
    case alreadyDownloading

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid model download URL"
        case .downloadFailed:
            return "Failed to download LLM model. Please check your internet connection."
        case .alreadyDownloading:
            return "Model is already being downloaded"
        }
    }
}

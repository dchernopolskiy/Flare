//
//  AppDelegate.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import SwiftUI
import Foundation
import Combine
import UserNotifications
import AppKit
import Sparkle


class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    private var updaterController: SPUStandardUpdaterController?
    private var updateCheckTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        setupSparkle()
        setupUpdateCheckTimer()

        // Listen for preference changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateCheckPreferenceChanged),
            name: NSNotification.Name("UpdateCheckPreferenceChanged"),
            object: nil
        )

        Task {
            await JobManager.shared.startMonitoring()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateCheckTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = NSImage(systemSymbolName: "briefcase.fill", accessibilityDescription: "Job Monitor")?
                .withSymbolConfiguration(config)
            button.action = #selector(togglePopover)
            button.toolTip = "Microsoft Job Monitor"
        }
    }
    
    @objc func togglePopover() {
        if let window = NSApplication.shared.windows.first {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Sparkle Setup
    private func setupSparkle() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    private func setupUpdateCheckTimer() {
        Task { @MainActor in
            guard JobManager.shared.autoCheckForUpdates else { return }
            let calendar = Calendar.current
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
            components.hour = 10
            components.minute = 0
            guard let nextCheckTime = calendar.date(from: components) else { return }

            let scheduledTime = nextCheckTime > Date() ? nextCheckTime : calendar.date(byAdding: .day, value: 1, to: nextCheckTime)!

            await MainActor.run {
                self.updateCheckTimer = Timer(fire: scheduledTime, interval: 24 * 60 * 60, repeats: true) { [weak self] _ in
                    self?.performDailyUpdateCheck()
                }

                if let timer = self.updateCheckTimer {
                    RunLoop.main.add(timer, forMode: .common)
                }
            }
        }
    }

    private func performDailyUpdateCheck() {
        Task { @MainActor in
            guard JobManager.shared.autoCheckForUpdates else { return }
            await MainActor.run {
                self.updaterController?.updater.checkForUpdatesInBackground()
            }
        }
    }

    func checkForUpdatesNow() {
        if let controller = updaterController {
            controller.updater.checkForUpdates()
        } else {
            print("[AppDelegate] ERROR: updaterController is nil")
        }
    }

    @objc private func updateCheckPreferenceChanged() {
        updateCheckTimer?.invalidate()
        setupUpdateCheckTimer()
    }
}

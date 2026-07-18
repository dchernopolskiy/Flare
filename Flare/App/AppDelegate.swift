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
    /// Set by SwiftUI on first window appear — the only reliable way to show/recreate
    /// a SwiftUI Window scene from outside the view hierarchy.
    var openMainWindow: (() -> Void)?
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        setupSparkle()

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
        NotificationCenter.default.removeObserver(self)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func showMainWindow() {
        if let window = NSApplication.shared.windows.first(where: { $0.title == "Flare" || $0.isMainWindow }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Window was fully closed by SwiftUI — recreate it via openWindow(id:)
            openMainWindow?()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = NSImage(systemSymbolName: "briefcase.fill", accessibilityDescription: "Job Monitor")?
                .withSymbolConfiguration(config)
            button.action = #selector(togglePopover)
            button.toolTip = "Flare"
        }
    }

    @objc func togglePopover() {
        showMainWindow()
    }

    private func setupSparkle() {
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        Task { @MainActor in
            self.syncAutomaticUpdateChecks()
            self.updaterController?.startUpdater()
        }
    }

    @MainActor
    private func syncAutomaticUpdateChecks() {
        updaterController?.updater.automaticallyChecksForUpdates = JobManager.shared.autoCheckForUpdates
    }

    func checkForUpdatesNow() {
        if let controller = updaterController {
            controller.updater.checkForUpdates()
        } else {
            print("[AppDelegate] ERROR: updaterController is nil")
        }
    }

    @objc private func updateCheckPreferenceChanged() {
        Task { @MainActor in
            self.syncAutomaticUpdateChecks()
        }
    }
}

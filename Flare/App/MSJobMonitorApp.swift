//
//  MSJobMonitorApp.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import SwiftUI
import UserNotifications
import AppKit

@main
struct MSJobMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var jobManager = JobManager.shared
    @StateObject private var boardMonitor = JobBoardMonitor.shared
    @AppStorage("isFirstLaunch") private var isFirstLaunch = true

    var body: some Scene {
        Window("Flare", id: "main") {
            ContentView()
                .environmentObject(jobManager)
                .environmentObject(boardMonitor)
                .environmentObject(appDelegate)
                .onAppear {
                    if isFirstLaunch {
                        jobManager.showSettings = true
                        isFirstLaunch = false
                    }
                }
                .handlesExternalEvents(preferring: ["job"], allowing: ["job"])
                .onOpenURL { url in
                    // Handle notification clicks
                    if let jobId = url.absoluteString.components(separatedBy: "://").last {
                        jobManager.selectJob(withId: jobId)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Flare") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "Flare",
                            .applicationVersion: "1.0.0"
                        ]
                    )
                }
            }
        }
    }
}

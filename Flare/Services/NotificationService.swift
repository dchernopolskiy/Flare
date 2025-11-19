//
//  NotificationService.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import Foundation
import UserNotifications
import AppKit

class NotificationService: NSObject {
    static let shared = NotificationService()
    
    override private init() {
        super.init()
        setupNotifications()
    }
    
    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
            } else if error != nil {
            }
        }
        
        UNUserNotificationCenter.current().delegate = self
    }
    
    func sendGroupedNotification(for newJobs: [Job]) async {
        guard !newJobs.isEmpty else { return }
        
        if newJobs.count == 1 {
            await sendSingleJobNotification(newJobs[0])
        } else {
            await sendMultipleJobsNotification(newJobs)
        }
    }
    
    private func sendSingleJobNotification(_ job: Job) async {
        let content = UNMutableNotificationContent()
        content.title = "New \(job.source.rawValue) Job Posted"
        content.subtitle = job.title
        content.body = job.location
        content.sound = .default
        content.userInfo = ["jobId": job.id]
        
        if let imageURL = createNotificationImage(for: job.source) {
            if let attachment = try? UNNotificationAttachment(identifier: "icon", url: imageURL, options: nil) {
                content.attachments = [attachment]
            }
        }
        
        let request = UNNotificationRequest(
            identifier: job.id,
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
        }
    }
    
    private func sendMultipleJobsNotification(_ jobs: [Job]) async {
        let content = UNMutableNotificationContent()
        content.title = "\(jobs.count) New Jobs Posted"
        
        let groupedBySource = Dictionary(grouping: jobs) { $0.source }
        let sourcesSummary = groupedBySource.map { source, sourceJobs in
            "\(source.rawValue): \(sourceJobs.count)"
        }.joined(separator: " • ")
        
        content.subtitle = sourcesSummary
        
        let jobTitles = jobs.prefix(3).map { "• \($0.title)" }.joined(separator: "\n")
        let moreText = jobs.count > 3 ? "\n...and \(jobs.count - 3) more" : ""
        content.body = jobTitles + moreText
        
        content.sound = .default
        content.userInfo = ["jobId": jobs[0].id]
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
        }
    }
    
    private func createNotificationImage(for source: JobSource) -> URL? {
        // TODO: -
        return nil
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        
        let userInfo = response.notification.request.content.userInfo
        if let jobId = userInfo["jobId"] as? String {
            NSApplication.shared.activate(ignoringOtherApps: true)
            
            if let window = NSApplication.shared.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
            
            Task { @MainActor in
                JobManager.shared.selectJob(withId: jobId)
            }
        }
        
        completionHandler()
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
}

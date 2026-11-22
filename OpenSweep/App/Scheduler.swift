// SPDX-License-Identifier: MIT
//
// Scheduled clean (P5). Off by default. While OpenSweep runs (open at login
// keeps it running in the menu bar) it rescans, then cleans Safe folders in
// dormant, unpinned projects under a size cap, as one engine run with no
// --include-caution or --include-active, and posts a notification with Undo.

import Foundation
import ServiceManagement
import UserNotifications
import AgentEngine

enum AutoClean: String, CaseIterable, Identifiable {
    case off, daily, weekly
    var id: String { rawValue }
    var interval: TimeInterval? {
        switch self {
        case .off: nil
        case .daily: 86_400
        case .weekly: 7 * 86_400
        }
    }
}

@MainActor
final class Scheduler: NSObject, UNUserNotificationCenterDelegate {
    private weak var model: AppModel?
    private var timer: Timer?

    init(model: AppModel) {
        self.model = model
        super.init()
        UNUserNotificationCenter.current().delegate = self
        let category = UNNotificationCategory(
            identifier: "autoClean",
            actions: [UNNotificationAction(identifier: "undo", title: "Undo")],
            intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
        // Check every 30 minutes; the first check a minute after launch.
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.model?.runScheduleIfDue() }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            await self?.model?.runScheduleIfDue()
        }
    }

    static func askToNotify() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(freed: UInt64, projects: Int, run: String, freesOn: Date?) {
        let content = UNMutableNotificationContent()
        content.title = "Cleaned \(bytes(freed)) from \(projects) dormant \(projects == 1 ? "project" : "projects")"
        content.body = freesOn.map { "Held in quarantine until \($0.formatted(date: .abbreviated, time: .omitted)). Undo puts everything back." }
            ?? "Held in quarantine until you purge it. Undo puts everything back."
        content.categoryIdentifier = "autoClean"
        content.userInfo = ["run": run]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: run, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == "undo",
              let run = response.notification.request.content.userInfo["run"] as? String else { return }
        await MainActor.run {
            Task { await self.model?.undoRun(run) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Open at login keeps OpenSweep in the menu bar, so the schedule runs.
    static var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                // ponytail: an unsigned build may be refused; the toggle then reads its real state.
            }
        }
    }
}

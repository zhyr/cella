import AppKit
import EventKit
import Foundation
import os.log

private let exportLog = OSLog(subsystem: "com.cella.tasknote", category: "EventExport")

/// Where a task should be handed off to.
enum EventExportTarget {
    /// A dated event in the user's default calendar.
    case calendar
    /// A dated to-do in the built-in Reminders app.
    case reminder

    var displayName: String {
        switch self {
        case .calendar: return "日历"
        case .reminder: return "「提醒事项」"
        }
    }
}

enum EventExportError: LocalizedError {
    /// Access was never granted, or was revoked in System Settings.
    case accessDenied(EventExportTarget)
    /// The target app has no default list to write into.
    case noDefaultList(EventExportTarget)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let target):
            return "没有访问\(target.displayName)的权限"
        case .noDefaultList(let target):
            return "\(target.displayName)里没有可用的默认列表"
        case .saveFailed(let reason):
            return "保存失败：\(reason)"
        }
    }

    /// Whether the fix is a toggle in System Settings rather than a retry.
    var requiresSystemSettings: Bool {
        if case .accessDenied = self { return true }
        return false
    }

    /// The app the missing permission belongs to, when that is the problem.
    var target: EventExportTarget? {
        switch self {
        case .accessDenied(let target), .noDefaultList(let target): return target
        case .saveFailed: return nil
        }
    }
}

/// Hands a task off to the Calendar or Reminders app through EventKit.
///
/// Both apps sit behind the same TCC gate. Access is requested on first use
/// rather than at launch: a task list has no business asking for calendar
/// access before the user has shown any interest in using it.
///
/// Cella is not sandboxed, but it is notarized with the hardened runtime, and
/// the hardened runtime treats Calendar as a protected resource: the
/// `com.apple.security.personal-information.calendars` entitlement is required,
/// otherwise EventKit reports "no access" without ever asking the user. With it
/// in place the `NS…UsageDescription` strings in Info.plist are what the system
/// shows in the permission alert. Reminders has no equivalent entitlement, so
/// it is gated by TCC and its usage string alone.
enum EventExportService {
    private static let store = EKEventStore()

    /// A to-do is not a meeting, so exported events get a deliberately short
    /// slot: long enough to be visible in a week view, short enough not to bury
    /// the real appointments around it.
    private static let eventDuration: TimeInterval = 30 * 60

    static func add(title: String,
                    notes: String?,
                    at date: Date,
                    to target: EventExportTarget,
                    completion: @escaping (Result<Void, EventExportError>) -> Void) {
        requestAccess(for: target) { granted in
            guard granted else {
                completion(.failure(.accessDenied(target)))
                return
            }
            switch target {
            case .calendar:
                completion(insertEvent(title: title, notes: notes, at: date))
            case .reminder:
                completion(insertReminder(title: title, notes: notes, at: date))
            }
        }
    }

    /// Opens the matching pane of System Settings › Privacy & Security, which is
    /// the only place a denied permission can be given back.
    static func openPrivacySettings(for target: EventExportTarget) {
        let anchor = target == .calendar ? "Privacy_Calendars" : "Privacy_Reminders"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Access

    private static func requestAccess(for target: EventExportTarget,
                                      completion: @escaping (Bool) -> Void) {
        let finish: (Bool) -> Void = { granted in
            DispatchQueue.main.async { completion(granted) }
        }

        // The permission alert is drawn by the system, but Cella is a menu bar
        // agent (`.accessory`, no Dock icon). Without activating, the alert can
        // appear behind other windows and the click looks like it did nothing.
        //
        // Only do this when an alert is actually imminent: once the user has
        // answered, this call returns without drawing anything, and yanking focus
        // on every subsequent click would be both pointless and rude.
        let status: EKAuthorizationStatus = target == .calendar
            ? EKEventStore.authorizationStatus(for: .event)
            : EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined {
            if Thread.isMainThread { NSApp.activate() }
            else { DispatchQueue.main.async { NSApp.activate() } }
        }

        switch target {
        case .calendar:
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    os_log(.error, log: exportLog, "Calendar access error: %{public}@", error.localizedDescription)
                }
                finish(granted)
            }
        case .reminder:
            store.requestFullAccessToReminders { granted, error in
                if let error {
                    os_log(.error, log: exportLog, "Reminders access error: %{public}@", error.localizedDescription)
                }
                finish(granted)
            }
        }
    }

    // MARK: - Insertion

    private static func insertEvent(title: String,
                                    notes: String?,
                                    at date: Date) -> Result<Void, EventExportError> {
        guard let calendar = store.defaultCalendarForNewEvents else {
            return .failure(.noDefaultList(.calendar))
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.notes = notes
        event.startDate = date
        event.endDate = date.addingTimeInterval(eventDuration)
        do {
            try store.save(event, span: .thisEvent, commit: true)
            os_log(.default, log: exportLog, "Added event to %{public}@", calendar.title)
            return .success(())
        } catch {
            os_log(.error, log: exportLog, "Event save failed: %{public}@", error.localizedDescription)
            return .failure(.saveFailed(error.localizedDescription))
        }
    }

    private static func insertReminder(title: String,
                                       notes: String?,
                                       at date: Date) -> Result<Void, EventExportError> {
        guard let calendar = store.defaultCalendarForNewReminders() else {
            return .failure(.noDefaultList(.reminder))
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes

        // `dueDateComponents` is what actually makes Reminders fire at a given
        // time — assigning a plain `Date` is ignored, and a reminder without a
        // time is only "due today". No explicit `EKAlarm` is added: with a time
        // in the due date the app already notifies, and an extra alarm would
        // fire the user twice.
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        reminder.dueDateComponents = components
        do {
            try store.save(reminder, commit: true)
            os_log(.default, log: exportLog, "Added reminder to %{public}@", calendar.title)
            return .success(())
        } catch {
            os_log(.error, log: exportLog, "Reminder save failed: %{public}@", error.localizedDescription)
            return .failure(.saveFailed(error.localizedDescription))
        }
    }
}

/*
 * Cella (层隅)
 * Copyright (C) 2024-2026 Cella Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import os.log

private let taskReminderLog = OSLog(subsystem: "com.cella.tasknote", category: "TaskReminder")

/// `~/Documents/cella/task-note/` — local storage directory for task files.
private let kCellaStorageSubpath = "cella/task-note"

/// A single sub-item nested under a task.
struct TaskSubItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var completed: Bool
    var completedAt: Date?

    init(title: String, id: UUID = UUID(), createdAt: Date = Date(), completed: Bool = false, completedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.completed = completed
        self.completedAt = completedAt
    }
}

/// A single task/reminder item.
///
/// A task may carry a list of `subitems` — smaller breakdown steps. Completing
/// a parent task automatically completes all of its sub-items; completing a
/// sub-item does not affect the parent.
struct TaskReminder: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var completed: Bool
    var completedAt: Date?
    var subitems: [TaskSubItem]

    init(title: String, id: UUID = UUID(), createdAt: Date = Date(), completed: Bool = false, completedAt: Date? = nil, subitems: [TaskSubItem] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.completed = completed
        self.completedAt = completedAt
        self.subitems = subitems
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, completed, completedAt, subitems
    }

    /// Custom decoder so JSON files written before the `subitems` field
    /// existed still load (defaulting to an empty array).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completed = try container.decode(Bool.self, forKey: .completed)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        subitems = try container.decodeIfPresent([TaskSubItem].self, forKey: .subitems) ?? []
    }
}

/// Singleton manager for task reminders.
///
/// Tasks are persisted as JSON files, one per calendar day (e.g. `2026-09-05.json`).
/// Each file contains the array of tasks created on that day. Marking a task
/// complete only flips the `completed` flag — it never deletes the record.
/// Data is only removed when the user explicitly deletes a single task.
///
/// Storage lives in `~/Documents/cella/task-note/`.
final class TaskReminderManager: ObservableObject {
    static let shared = TaskReminderManager()

    @Published private(set) var tasks: [TaskReminder] = []

    private let storageDirectory: URL
    private let ioQueue = DispatchQueue(label: "com.cella.tasknote.io")

    /// Date formatter for naming day-files (`YYYY-MM-DD.json`).
    /// **Must only be accessed from `ioQueue`.**
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageDirectory = docs.appendingPathComponent(kCellaStorageSubpath, isDirectory: true)
        ensureDirectoryExists(at: storageDirectory)
        ioQueue.async { [weak self] in
            self?.reconcileAtStartup()
        }
    }

    // MARK: - Public API

    func addTask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = TaskReminder(title: trimmed)
        tasks.insert(task, at: 0)
        ioQueue.async { [weak self] in self?.saveTask(task) }
    }

    /// When a task is marked complete, all sub-items are auto-completed.
    func toggleCompleted(_ task: TaskReminder) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].completed.toggle()
        tasks[index].completedAt = tasks[index].completed ? Date() : nil
        if tasks[index].completed {
            for subIndex in tasks[index].subitems.indices {
                tasks[index].subitems[subIndex].completed = true
                if tasks[index].subitems[subIndex].completedAt == nil {
                    tasks[index].subitems[subIndex].completedAt = Date()
                }
            }
        }
        let updated = tasks[index]
        ioQueue.async { [weak self] in self?.saveTask(updated) }
    }

    // MARK: - Sub-items

    func addSubItem(to task: TaskReminder, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let subItem = TaskSubItem(title: trimmed)
        tasks[index].subitems.append(subItem)
        let updated = tasks[index]
        ioQueue.async { [weak self] in self?.saveTask(updated) }
    }

    /// Completing a sub-item does NOT affect the parent task.
    func toggleSubItemCompleted(task: TaskReminder, subItem: TaskSubItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              let subIndex = tasks[index].subitems.firstIndex(where: { $0.id == subItem.id }) else { return }
        tasks[index].subitems[subIndex].completed.toggle()
        tasks[index].subitems[subIndex].completedAt =
            tasks[index].subitems[subIndex].completed ? Date() : nil
        let updated = tasks[index]
        ioQueue.async { [weak self] in self?.saveTask(updated) }
    }

    func deleteSubItem(task: TaskReminder, subItem: TaskSubItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].subitems.removeAll { $0.id == subItem.id }
        let updated = tasks[index]
        ioQueue.async { [weak self] in self?.saveTask(updated) }
    }

    func delete(_ task: TaskReminder) {
        tasks.removeAll { $0.id == task.id }
        ioQueue.async { [weak self] in self?.removeTaskFromFile(task) }
    }

    // MARK: - Sorting

    var sortedTasks: [TaskReminder] {
        tasks.sorted { lhs, rhs in
            if lhs.completed != rhs.completed { return !lhs.completed }
            return lhs.createdAt > rhs.createdAt
        }
    }

    var pendingCount: Int { tasks.filter { !$0.completed }.count }

    // MARK: - File helpers (all on ioQueue)

    private func ensureDirectoryExists(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                os_log(.error, log: taskReminderLog, "Failed to create storage directory: %{public}@", error.localizedDescription)
            }
        }
    }

    private func fileURL(for date: Date) -> URL {
        let filename = dateFormatter.string(from: date) + ".json"
        return storageDirectory.appendingPathComponent(filename)
    }

    private func saveTask(_ task: TaskReminder) {
        let url = fileURL(for: task.createdAt)
        var dayTasks = loadDayTasks(from: url)
        if let existingIndex = dayTasks.firstIndex(where: { $0.id == task.id }) {
            dayTasks[existingIndex] = task
        } else {
            dayTasks.insert(task, at: 0)
        }
        writeDayTasks(dayTasks, to: url)
    }

    private func removeTaskFromFile(_ task: TaskReminder) {
        let url = fileURL(for: task.createdAt)
        var dayTasks = loadDayTasks(from: url)
        dayTasks.removeAll { $0.id == task.id }
        if dayTasks.isEmpty {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                os_log(.error, log: taskReminderLog, "Failed to remove day file: %{public}@", error.localizedDescription)
            }
        } else {
            writeDayTasks(dayTasks, to: url)
        }
    }

    private func loadDayTasks(from url: URL) -> [TaskReminder] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let decoded = try? JSONDecoder().decode([TaskReminder].self, from: data) { return decoded }
        if let text = String(data: data, encoding: .utf8), text.isEmpty { return [] }
        return []
    }

    private func writeDayTasks(_ tasks: [TaskReminder], to url: URL) {
        do {
            let data = try JSONEncoder().encode(tasks)
            try data.write(to: url, options: .atomic)
        } catch {
            os_log(.error, log: taskReminderLog, "Failed to write day file: %{public}@", error.localizedDescription)
        }
    }

    private func reconcileAtStartup() {
        let dir = storageDirectory
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        var allTasks: [TaskReminder] = []
        for url in fileURLs where url.pathExtension == "json" {
            allTasks.append(contentsOf: loadDayTasks(from: url))
        }
        var dedupedById: [UUID: TaskReminder] = [:]
        for task in allTasks {
            if let existing = dedupedById[task.id] {
                if task.createdAt >= existing.createdAt { dedupedById[task.id] = task }
            } else {
                dedupedById[task.id] = task
            }
        }
        let sorted = Array(dedupedById.values).sorted { $0.createdAt > $1.createdAt }
        DispatchQueue.main.async { [weak self] in self?.tasks = sorted }
    }
}

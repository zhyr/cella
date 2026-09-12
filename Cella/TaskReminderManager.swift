import Foundation
import os.log

private let taskReminderLog = OSLog(subsystem: "com.cella.tasknote", category: "TaskReminder")

/// Synced storage for Cella: `~/Documents/cella/task-note/`.
///
/// Sync is delegated to the system rather than to an iCloud container. When the
/// user turns on iCloud Drive's "Desktop & Documents Folders", `~/Documents`
/// *is* iCloud Drive and macOS replicates this folder to every device signed in
/// with the same Apple ID. That needs no entitlement and no provisioning
/// profile, so a plain Developer ID build syncs just like a container-based app.
private let kCellaStorageSubpath = "cella/task-note"

/// Legacy local-only storage: `~/Library/Application Support/Cella/TaskNote/`.
///
/// An earlier build let the user "turn iCloud off", which silently relocated
/// every task here. That split the data across two folders and could strand it
/// outside iCloud altogether, so the switch is gone and files always live in the
/// synced folder. This path is now only *read*, once, to carry stranded tasks
/// back into `~/Documents`.
private let kLocalOnlyStorageSubpath = "Cella/TaskNote"

/// Legacy brew.app local path: `~/Documents/brew/task-note/`.
/// On first launch, Cella migrates any tasks found here into its own storage.
private let kBrewStorageSubpath = "brew/task-note"

/// Leftover flag from the removed sync switch, cleared on launch.
private let kUserOptedOutOfiCloudKey = "CellaTaskNoteOptedOutOfICloud"

/// Set once the legacy local-only folder has been folded back into the synced one.
private let kLocalOnlyMigrationDoneKey = "CellaTaskNoteLocalOnlyMigrationDone"

/// Set after brew→cella migration completes so we don't re-import.
private let kLegacyBrewMigrationDoneKey = "CellaTaskNoteLegacyBrewMigrationDone"

// MARK: - Models

/// A single sub-item nested under a task.
///
/// Sub-items can themselves carry one more level of children (third-level
/// items). Anything deeper is intentionally unsupported: the UI is a quick
/// checklist, not an outliner.
struct TaskSubItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var completed: Bool
    var completedAt: Date?
    var subSubItems: [TaskSubItem]

    init(title: String,
         id: UUID = UUID(),
         createdAt: Date = Date(),
         completed: Bool = false,
         completedAt: Date? = nil,
         subSubItems: [TaskSubItem] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.completed = completed
        self.completedAt = completedAt
        self.subSubItems = subSubItems
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, completed, completedAt, subSubItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completed = try container.decode(Bool.self, forKey: .completed)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        // Old task files written before the third-level feature simply omit this
        // key; defaulting to [] keeps them readable.
        subSubItems = try container.decodeIfPresent([TaskSubItem].self, forKey: .subSubItems) ?? []
    }

}

/// A deletion that is still recoverable, so the list can offer an undo.
///
/// Deliberately only ever holds one item — the most recent deletion — and only
/// for `TaskReminderManager.undoWindow` seconds. It is a way to walk back a
/// mis-click, not a deletion journal.
enum PendingDeletion {
    case task(TaskReminder, at: Int)
    case subItem(taskID: UUID, subItem: TaskSubItem, at: Int)
    case subSubItem(taskID: UUID, subItemID: UUID, subSubItem: TaskSubItem, at: Int)

    /// Identifies what is pending, so the banner can animate on a new deletion
    /// and ignore repeats of the same one.
    var id: UUID {
        switch self {
        case .task(let task, _):                 return task.id
        case .subItem(_, let subItem, _):        return subItem.id
        case .subSubItem(_, _, let child, _):    return child.id
        }
    }

    var title: String {
        switch self {
        case .task(let task, _):                 return task.title
        case .subItem(_, let subItem, _):        return subItem.title
        case .subSubItem(_, _, let child, _):    return child.title
        }
    }

    /// What got deleted, for the banner's wording.
    var noun: String {
        switch self {
        case .task:       return "任务"
        case .subItem:    return "子项"
        case .subSubItem: return "三级子项"
        }
    }
}

/// A single task/reminder item.
///
/// A task may carry a list of `subitems`. Completing a parent task
/// automatically completes all of its sub-items; completing a sub-item
/// does not affect the parent.
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

/// Observable view of how Cella's data folder is currently being synced.
///
/// Cella writes into an ordinary folder and lets macOS replicate it, so the app
/// can only *report* what the system is doing — it cannot turn sync on or off.
/// There is deliberately no "not provisioned" case any more: a plain Developer
/// ID build syncs exactly as well as a store build.
enum TaskReminderSyncState: Equatable {
    /// The data folder is an iCloud Drive item — macOS is replicating it.
    case syncing
    /// The folder is in use but macOS is not replicating it right now
    /// (iCloud Drive off, "Desktop & Documents" off, or signed out).
    case notSynced
    case unknown

    var description: String {
        switch self {
        case .syncing:   return "已通过 iCloud Drive 同步"
        case .notSynced: return "数据保存在本机；开启 iCloud Drive 的「桌面与文档文件夹」后即可跨设备同步"
        case .unknown:   return "正在检测 iCloud…"
        }
    }
}

// MARK: - Manager

/// Singleton manager for task reminders with iCloud sync.
///
/// Tasks are persisted as JSON files, one per calendar day (e.g. `2026-09-05.json`).
/// Marking a task complete only flips that item's own `completed` flag; it never
/// cascades to sub-items and never deletes the record. Data is only removed when
/// the user explicitly deletes a task.
///
/// **Storage.** `~/Documents/cella/task-note/`, which macOS replicates whenever
/// iCloud Drive's "Desktop & Documents Folders" is on. That is the only location
/// — whether it syncs is macOS's decision, not a switch inside this app.
///
/// **Migration.** On first launch, tasks are carried over from two older
/// locations: brew.app's folder (`~/Documents/brew/task-note/`) and the
/// local-only folder used by the since-removed sync switch
/// (`~/Library/Application Support/Cella/TaskNote/`).
final class TaskReminderManager: ObservableObject {
    static let shared = TaskReminderManager()

    @Published private(set) var tasks: [TaskReminder] = []
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var iCloudSyncState: TaskReminderSyncState = .unknown

    /// The most recent deletion, kept so the UI can offer an undo before it
    /// becomes permanent. Cleared automatically after `Self.undoWindow` seconds.
    @Published private(set) var undoableDeletion: PendingDeletion?

    /// `~/Documents`, kept for the migration's readability probe.
    private let documentsDirectory: URL
    private let cellaSyncedDirectory: URL
    /// Read-only, and only for the one-time migration described on `init`.
    private let cellaLocalOnlyDirectory: URL
    private let brewLegacyDirectory: URL
    private var resolvedStorageDirectory: URL

    /// Which day file each known task currently lives in.
    ///
    /// A day file is named after the task's `createdAt` *formatted in the
    /// current time zone*, so the name a task gets depends on where the user
    /// was standing. Recomputing it at write time therefore points at the wrong
    /// file after a time-zone change: a delete would rewrite a file that never
    /// held the task and leave the real one behind, and the task would reappear
    /// on the next launch. Reconciling records the actual location here, and
    /// writes and deletes follow that instead of guessing.
    ///
    /// ioQueue-confined, like the other file bookkeeping.
    private var fileByTaskID: [UUID: URL] = [:]

    /// Ids deleted during this session. Main-thread confined, like `tasks`.
    ///
    /// The ioQueue write that drops a task from its day file may not have
    /// landed yet, so `reconcileAtStartup` has to ignore these ids or the
    /// just-deleted task would pop straight back into the list.
    private var deletedTaskIDs: Set<UUID> = []

    /// Bumped whenever the undo window restarts, so a stale auto-dismiss timer
    /// can't clear a newer offer.
    private var undoGeneration = 0

    private let ioQueue = DispatchQueue(label: "com.cella.tasknote.io")

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    /// Polls the storage folder for changes written by another machine.
    private var pollTimer: DispatchSourceTimer?
    /// Number of polls since the watcher started; drives the low-frequency
    /// iCloud status re-check below.
    private var pollTick = 0
    /// Snapshot of the storage folder taken at the previous poll.
    private var lastFingerprint: DirectoryFingerprint?
    /// When this process last wrote to the storage folder. A change observed
    /// within `localWriteQuietPeriod` of this is attributed to us, not to iCloud.
    private var lastLocalWriteAt: Date?
    private var identityChangeObserver: NSObjectProtocol?

    private init() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        documentsDirectory = docs
        cellaSyncedDirectory = docs.appendingPathComponent(kCellaStorageSubpath, isDirectory: true)
        brewLegacyDirectory = docs.appendingPathComponent(kBrewStorageSubpath, isDirectory: true)
        cellaLocalOnlyDirectory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(kLocalOnlyStorageSubpath, isDirectory: true)
        resolvedStorageDirectory = cellaSyncedDirectory

        ioQueue.async { [weak self] in
            guard let self else { return }
            self.migrateFromBrewIfNeeded()
            self.migrateFromLocalOnlyIfNeeded()
            self.rebuildStorage()   // 已内含 startWatching()
            self.refreshSyncState()
            self.reconcileAtStartup()
        }

        identityChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.ioQueue.async {
                self.rebuildStorage()   // 已内含 startWatching()
                self.refreshSyncState()
                self.reconcileAtStartup(preferDisk: true)
            }
        }
    }

    deinit {
        if let identityChangeObserver { NotificationCenter.default.removeObserver(identityChangeObserver) }
        pollTimer?.cancel()
    }

    // MARK: - Migration from brew.app

    /// One-time migration: copy brew.app's local task files into Cella's
    /// active storage so existing tasks carry over.
    private func migrateFromBrewIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: kLegacyBrewMigrationDoneKey) else { return }
        guard FileManager.default.fileExists(atPath: brewLegacyDirectory.path) else {
            // "The folder is not there" and "I am not allowed to look" are
            // indistinguishable here, and only the first one means there is
            // nothing to migrate. On a first launch where the user denied
            // access to their Documents folder, `fileExists` answers `false`
            // for a folder that is very much full of tasks — recording "done"
            // then would throw that import away permanently. So the flag is
            // only set once a readable parent confirms the folder is really
            // absent; otherwise the next launch tries again.
            if isDirectoryReadable(documentsDirectory) {
                defaults.set(true, forKey: kLegacyBrewMigrationDoneKey)
            } else {
                os_log(.error, log: taskReminderLog,
                       "Cannot read %{public}@ — brew migration deferred to the next launch",
                       documentsDirectory.path)
            }
            return
        }
        ensureDirectoryExists(at: cellaSyncedDirectory)
        if copyContents(of: brewLegacyDirectory, into: cellaSyncedDirectory) {
            defaults.set(true, forKey: kLegacyBrewMigrationDoneKey)
            os_log(.info, log: taskReminderLog, "Migrated brew.app tasks to Cella storage")
        } else {
            os_log(.error, log: taskReminderLog, "brew→cella migration incomplete — will retry next launch")
        }
    }

    /// One-time migration for anyone who used the removed sync switch.
    ///
    /// Flipping that switch off moved every task into
    /// `~/Library/Application Support/Cella/TaskNote/`, where it sat outside
    /// iCloud. Fold those files back into the synced folder and drop the old
    /// directory, so there is exactly one copy of the data again — two live
    /// folders is precisely the divergence the switch was removed to prevent.
    private func migrateFromLocalOnlyIfNeeded() {
        let defaults = UserDefaults.standard
        // The switch that wrote this flag no longer exists; don't let a stale
        // value linger in defaults.
        defaults.removeObject(forKey: kUserOptedOutOfiCloudKey)

        guard !defaults.bool(forKey: kLocalOnlyMigrationDoneKey) else { return }
        guard FileManager.default.fileExists(atPath: cellaLocalOnlyDirectory.path) else {
            defaults.set(true, forKey: kLocalOnlyMigrationDoneKey)
            return
        }

        ensureDirectoryExists(at: cellaSyncedDirectory)
        // Never overwrite: a file already in the synced folder may be the newer
        // one, having arrived from another machine.
        _ = copyMissingFiles(from: cellaLocalOnlyDirectory, into: cellaSyncedDirectory)
        do {
            try FileManager.default.removeItem(at: cellaLocalOnlyDirectory)
            defaults.set(true, forKey: kLocalOnlyMigrationDoneKey)
            os_log(.default, log: taskReminderLog, "Folded legacy local-only storage into the synced folder")
        } catch {
            // Left in place deliberately: better to re-copy next launch than to
            // lose the only copy of someone's tasks.
            os_log(.error, log: taskReminderLog,
                   "Could not remove legacy local-only folder: %{public}@", error.localizedDescription)
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

    func toggleCompleted(_ task: TaskReminder) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].completed.toggle()
        tasks[index].completedAt = tasks[index].completed ? Date() : nil
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

    func toggleSubItemCompleted(task: TaskReminder, subItem: TaskSubItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              let subIndex = tasks[index].subitems.firstIndex(where: { $0.id == subItem.id }) else { return }
        tasks[index].subitems[subIndex].completed.toggle()
        tasks[index].subitems[subIndex].completedAt = tasks[index].subitems[subIndex].completed ? Date() : nil
        let updated = tasks[index]
        ioQueue.async { [weak self] in self?.saveTask(updated) }
    }

    func deleteSubItem(task: TaskReminder, subItem: TaskSubItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let position = tasks[index].subitems.firstIndex(where: { $0.id == subItem.id })
            ?? tasks[index].subitems.count
        tasks[index].subitems.removeAll { $0.id == subItem.id }
        let updated = tasks[index]
        ioQueue.async { [weak self] in self?.saveTask(updated) }
        offerUndo(.subItem(taskID: task.id, subItem: subItem, at: position))
    }

    // MARK: - Third-level items

    /// Longest title a third-level item may have.
    ///
    /// Enforced here rather than only in the text field because adding and
    /// renaming are two independent write paths, and both have to land on the
    /// same cap — otherwise the limit would only hold for items typed in, and an
    /// item edited afterwards could grow past it.
    static let subSubItemTitleLimit = 15

    func addSubSubItem(to task: TaskReminder, subItem: TaskSubItem, title: String) {
        guard let cleaned = Self.cleanedTitle(title, limit: Self.subSubItemTitleLimit) else { return }
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              let subIndex = tasks[index].subitems.firstIndex(where: { $0.id == subItem.id }) else { return }
        let child = TaskSubItem(title: cleaned)
        tasks[index].subitems[subIndex].subSubItems.append(child)
        let updated = tasks[index]
        ioQueue.async { [weak self] in self?.saveTask(updated) }
    }

    func toggleSubSubItemCompleted(task: TaskReminder, subItem: TaskSubItem, subSubItem: TaskSubItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              let subIndex = tasks[index].subitems.firstIndex(where: { $0.id == subItem.id }),
              let childIndex = tasks[index].subitems[subIndex].subSubItems.firstIndex(where: { $0.id == subSubItem.id }) else { return }
        tasks[index].subitems[subIndex].subSubItems[childIndex].completed.toggle()
        tasks[index].subitems[subIndex].subSubItems[childIndex].completedAt =
            tasks[index].subitems[subIndex].subSubItems[childIndex].completed ? Date() : nil
        let updated = tasks[index]
        ioQueue.async { [weak self] in self?.saveTask(updated) }
    }

    func deleteSubSubItem(task: TaskReminder, subItem: TaskSubItem, subSubItem: TaskSubItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              let subIndex = tasks[index].subitems.firstIndex(where: { $0.id == subItem.id }) else { return }
        let position = tasks[index].subitems[subIndex].subSubItems
            .firstIndex(where: { $0.id == subSubItem.id })
            ?? tasks[index].subitems[subIndex].subSubItems.count
        tasks[index].subitems[subIndex].subSubItems.removeAll { $0.id == subSubItem.id }
        let updated = tasks[index]
        ioQueue.async { [weak self] in self?.saveTask(updated) }
        offerUndo(.subSubItem(taskID: task.id, subItemID: subItem.id, subSubItem: subSubItem, at: position))
    }

    func delete(_ task: TaskReminder) {
        deletedTaskIDs.insert(task.id)
        let position = tasks.firstIndex(where: { $0.id == task.id }) ?? 0
        tasks.removeAll { $0.id == task.id }
        ioQueue.async { [weak self] in self?.removeTaskFromFile(task) }
        offerUndo(.task(task, at: position))
    }

    // MARK: - Renaming

    /// Applies an edited task title.
    ///
    /// An edit that trims down to nothing is a no-op rather than a deletion: the
    /// inline editor commits on both Enter and focus loss, so a stray keystroke
    /// must not be able to erase a task by accident.
    func rename(_ task: TaskReminder, to title: String) {
        guard let cleaned = Self.cleanedTitle(title, limit: nil) else { return }
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              tasks[index].title != cleaned else { return }
        tasks[index].title = cleaned
        let updated = tasks[index]
        ioQueue.async { [weak self] in self?.saveTask(updated) }
    }

    func renameSubItem(task: TaskReminder, subItem: TaskSubItem, to title: String) {
        guard let cleaned = Self.cleanedTitle(title, limit: nil) else { return }
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              let subIndex = tasks[index].subitems.firstIndex(where: { $0.id == subItem.id }),
              tasks[index].subitems[subIndex].title != cleaned else { return }
        tasks[index].subitems[subIndex].title = cleaned
        let updated = tasks[index]
        ioQueue.async { [weak self] in self?.saveTask(updated) }
    }

    func renameSubSubItem(task: TaskReminder, subItem: TaskSubItem, subSubItem: TaskSubItem, to title: String) {
        guard let cleaned = Self.cleanedTitle(title, limit: Self.subSubItemTitleLimit) else { return }
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              let subIndex = tasks[index].subitems.firstIndex(where: { $0.id == subItem.id }),
              let childIndex = tasks[index].subitems[subIndex].subSubItems
                  .firstIndex(where: { $0.id == subSubItem.id }),
              tasks[index].subitems[subIndex].subSubItems[childIndex].title != cleaned else { return }
        tasks[index].subitems[subIndex].subSubItems[childIndex].title = cleaned
        let updated = tasks[index]
        ioQueue.async { [weak self] in self?.saveTask(updated) }
    }

    /// Normalises a title coming from an editor; `nil` means "discard this edit".
    ///
    /// `limit` is only ever set for third-level items — the other levels have no
    /// length rule.
    private static func cleanedTitle(_ raw: String, limit: Int?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let limit else { return trimmed }
        return String(trimmed.prefix(limit))
    }

    // MARK: - Undo

    /// How long a deleted task stays recoverable.
    static let undoWindow: TimeInterval = 6

    /// Puts the most recently deleted item back where it was.
    ///
    /// A sub-item can only be restored if its parent is still around: deleting a
    /// task also disposes of everything under it, so a stale sub-item offer
    /// quietly does nothing rather than conjuring an orphan.
    func undoDelete() {
        undoGeneration &+= 1
        guard let pending = undoableDeletion else { return }
        undoableDeletion = nil

        switch pending {
        case .task(let task, let position):
            deletedTaskIDs.remove(task.id)
            tasks.insert(task, at: min(position, tasks.count))
            ioQueue.async { [weak self] in self?.saveTask(task) }

        case .subItem(let taskID, let subItem, let position):
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[index].subitems.insert(subItem, at: min(position, tasks[index].subitems.count))
            let updated = tasks[index]
            ioQueue.async { [weak self] in self?.saveTask(updated) }

        case .subSubItem(let taskID, let subItemID, let child, let position):
            guard let index = tasks.firstIndex(where: { $0.id == taskID }),
                  let subIndex = tasks[index].subitems.firstIndex(where: { $0.id == subItemID }) else { return }
            let children = tasks[index].subitems[subIndex].subSubItems
            tasks[index].subitems[subIndex].subSubItems.insert(child, at: min(position, children.count))
            let updated = tasks[index]
            ioQueue.async { [weak self] in self?.saveTask(updated) }
        }
    }

    private func offerUndo(_ deletion: PendingDeletion) {
        undoGeneration &+= 1
        let generation = undoGeneration
        undoableDeletion = deletion
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoWindow) { [weak self] in
            guard let self, self.undoGeneration == generation else { return }
            self.undoableDeletion = nil
        }
    }

    func forceReconcile() {
        ioQueue.async { [weak self] in self?.reconcileAtStartup() }
    }

    // MARK: - Sorting

    var sortedTasks: [TaskReminder] {
        tasks.sorted { lhs, rhs in
            if lhs.completed != rhs.completed { return !lhs.completed }
            return lhs.createdAt > rhs.createdAt
        }
    }

    var pendingCount: Int { tasks.filter { !$0.completed }.count }

    // MARK: - Storage resolution

    /// Points the manager at the synced folder and (re)starts the watcher.
    ///
    /// Sync belongs to macOS, not to this app, so there is no container to
    /// resolve and no location to choose between — `~/Documents` is an ordinary
    /// directory that iCloud Drive happens to replicate while "Desktop &
    /// Documents" is enabled.
    private func rebuildStorage() {
        ensureDirectoryExists(at: cellaSyncedDirectory)
        resolvedStorageDirectory = cellaSyncedDirectory
        // Locations from the previous directory must not survive the switch, or
        // a write could be routed at a folder we no longer use.
        fileByTaskID.removeAll()
        startWatching()
    }

    /// Whether macOS is currently replicating `url` through iCloud Drive.
    ///
    /// `isUbiquitousItem` reports `true` for a plain `~/Documents` path when the
    /// system's "Desktop & Documents" sync is on, and it needs no entitlement —
    /// which is precisely why Cella can sync without an iCloud container.
    private static func isICloudBacked(_ url: URL) -> Bool {
        guard FileManager.default.ubiquityIdentityToken != nil else { return false }
        return FileManager.default.isUbiquitousItem(at: url)
    }

    /// Makes sure an iCloud file is materialized locally before we read it.
    ///
    /// iCloud Drive may evict a file and leave a dataless placeholder behind.
    /// Reading one either blocks or fails, and a failed read used to look like
    /// "this day has no tasks" — which then got written back as an empty file,
    /// wiping the day. Returns `false` when the file is still a placeholder;
    /// the caller then skips the update and waits for the next poll.
    private func isMaterialized(at url: URL) -> Bool {
        guard FileManager.default.isUbiquitousItem(at: url) else { return true }
        guard let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus else { return true }
        if status == .current { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        os_log(.info, log: taskReminderLog, "Waiting for iCloud download of %{public}@", url.lastPathComponent)
        return false
    }

    /// Recomputes the badge state. Runs on `ioQueue`, publishes on the main queue.
    private func refreshSyncState() {
        // The folder must exist before the system can report it as an iCloud
        // Drive item.
        ensureDirectoryExists(at: cellaSyncedDirectory)
        let state: TaskReminderSyncState =
            Self.isICloudBacked(cellaSyncedDirectory) ? .syncing : .notSynced
        DispatchQueue.main.async { [weak self] in self?.iCloudSyncState = state }
    }

    // MARK: - File helpers (all on ioQueue)

    private func ensureDirectoryExists(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                os_log(.error, log: taskReminderLog, "Failed to create directory: %{public}@", error.localizedDescription)
            }
        }
    }

    /// Whether a directory can actually be listed right now.
    ///
    /// `fileExists` answers `false` both for "not there" and for "not allowed to
    /// look"; this tells the two apart, which is what the migration guards need.
    private func isDirectoryReadable(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    private func copyContents(of src: URL, into dst: URL) -> Bool {
        ensureDirectoryExists(at: dst)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: src, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        var ok = true
        for entry in entries where entry.pathExtension == "json" {
            let target = dst.appendingPathComponent(entry.lastPathComponent)
            do {
                // `replaceItemAt` swaps atomically — remove-then-copy leaves a
                // window where a crash loses the destination file entirely.
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: entry)
                } else {
                    try FileManager.default.copyItem(at: entry, to: target)
                }
            } catch {
                os_log(.error, log: taskReminderLog, "Copy failed: %{public}@", error.localizedDescription)
                ok = false
            }
        }
        return ok
    }

    /// Copies any of `src`'s task files that `dst` does not already have.
    ///
    /// Used when switching between the synced and the local-only folder: filling
    /// the gaps keeps tasks from disappearing on a toggle, while never
    /// overwriting means files already present in the destination — which may
    /// well be newer, having arrived from another machine — stay authoritative.
    private func copyMissingFiles(from src: URL, into dst: URL) -> Bool {
        ensureDirectoryExists(at: dst)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: src, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        var ok = true
        for entry in entries where entry.pathExtension == "json" {
            let target = dst.appendingPathComponent(entry.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                try FileManager.default.copyItem(at: entry, to: target)
            } catch {
                os_log(.error, log: taskReminderLog, "Copy failed: %{public}@", error.localizedDescription)
                ok = false
            }
        }
        return ok
    }

    private func fileURL(for date: Date) -> URL {
        let filename = dateFormatter.string(from: date) + ".json"
        return resolvedStorageDirectory.appendingPathComponent(filename)
    }

    /// The file a task should be read from and written to.
    ///
    /// The file a task was actually loaded from is authoritative. Naming the day
    /// after `createdAt` is only a fallback for a task we have never seen on
    /// disk, because that name depends on the current time zone: after a
    /// zone change it can point at a different day than the one the task was
    /// stored under, which used to leave the real file untouched.
    private func storageURL(for task: TaskReminder) -> URL {
        fileByTaskID[task.id] ?? fileURL(for: task.createdAt)
    }

    private func saveTask(_ task: TaskReminder) {
        let url = storageURL(for: task)
        // Never rewrite a day file we could not fully read — doing so would
        // silently drop every other task stored in it.
        guard var dayTasks = loadDayTasks(from: url) else {
            os_log(.error, log: taskReminderLog, "Skipped save for %{public}@ — source unreadable", url.lastPathComponent)
            return
        }
        if let existingIndex = dayTasks.firstIndex(where: { $0.id == task.id }) {
            dayTasks[existingIndex] = task
        } else {
            dayTasks.insert(task, at: 0)
        }
        writeDayTasks(dayTasks, to: url)
        fileByTaskID[task.id] = url
        noteSyncTimestamp()
    }

    private func removeTaskFromFile(_ task: TaskReminder) {
        let url = storageURL(for: task)
        guard var dayTasks = loadDayTasks(from: url) else {
            os_log(.error, log: taskReminderLog, "Skipped delete for %{public}@ — source unreadable", url.lastPathComponent)
            return
        }
        dayTasks.removeAll { $0.id == task.id }
        if dayTasks.isEmpty {
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            coordinator.coordinate(writingItemAt: url, options: [.forDeleting], error: &coordError) { coordinatedURL in
                do {
                    if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                        try FileManager.default.removeItem(at: coordinatedURL)
                    }
                } catch {
                    os_log(.error, log: taskReminderLog, "Remove failed: %{public}@", error.localizedDescription)
                }
            }
            if let coordError {
                os_log(.error, log: taskReminderLog, "Coordination failed: %{public}@", coordError.localizedDescription)
            }
        } else {
            writeDayTasks(dayTasks, to: url)
        }
        fileByTaskID.removeValue(forKey: task.id)
        noteSyncTimestamp()
    }

    private func loadDayTasks(from url: URL) -> [TaskReminder]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard isMaterialized(at: url) else { return nil }

        let coordinator = NSFileCoordinator()
        var result: [TaskReminder]?
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            if data.isEmpty {
                result = []
            } else if let decoded = try? JSONDecoder().decode([TaskReminder].self, from: data) {
                result = decoded
            } else {
                os_log(.error, log: taskReminderLog, "Corrupt task file %{public}@ — left untouched", url.lastPathComponent)
            }
        }
        if let coordError {
            os_log(.error, log: taskReminderLog, "Read coordination failed: %{public}@", coordError.localizedDescription)
        }
        return result
    }

    private func writeDayTasks(_ tasks: [TaskReminder], to url: URL) {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { writeURL in
            do {
                let data = try JSONEncoder().encode(tasks)
                try data.write(to: writeURL, options: .atomic)
            } catch {
                os_log(.error, log: taskReminderLog, "Write failed: %{public}@", error.localizedDescription)
            }
        }
        if let coordError {
            os_log(.error, log: taskReminderLog, "Write coordination failed: %{public}@", coordError.localizedDescription)
        }
    }

    /// Rebuilds the in-memory list from disk.
    ///
    /// Merges rather than replaces: a day file that is still downloading from
    /// iCloud (or failed to read) must never make tasks vanish from the UI, and
    /// in-session edits stay authoritative until the next launch.
    ///
    /// - Parameter preferDisk: set when the reload was triggered by a change
    ///   made on another machine. On a normal launch the in-memory list wins
    ///   ties, because a session edit may not have reached disk yet; after a
    ///   remote change it is the file that holds the newer data instead.
    private func reconcileAtStartup(preferDisk: Bool = false) {
        let dir = resolvedStorageDirectory
        let fileURLs: [URL]
        do {
            fileURLs = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        } catch {
            // 目录列举失败时如实记录。最常见的原因是 macOS 对「文稿文件夹」的 TCC
            // 授权被拒（非沙盒 App 也受此保护），而它的表现只是「任务莫名清空」，
            // 不打日志就完全无从排查。
            os_log(.error, log: taskReminderLog,
                   "Cannot list %{public}@: %{public}@", dir.path, error.localizedDescription)
            return
        }

        let snapshot = DispatchQueue.main.sync { (tasks: tasks, deleted: deletedTaskIDs) }
        var diskTasks: [TaskReminder] = []
        var deferred: [String] = []
        var locations: [UUID: URL] = [:]
        for url in fileURLs where url.pathExtension == "json" {
            guard let dayTasks = loadDayTasks(from: url) else {
                deferred.append(url.lastPathComponent)
                continue
            }
            // Record where every task really lives, so later writes and deletes
            // go back to the same file instead of re-deriving its name.
            for task in dayTasks where !snapshot.deleted.contains(task.id) {
                locations[task.id] = url
            }
            diskTasks.append(contentsOf: dayTasks.filter { !snapshot.deleted.contains($0.id) })
        }
        fileByTaskID = locations

        // Whichever group comes first wins, so the caller decides whether this
        // session's in-memory edits or the on-disk copies are authoritative.
        //
        // A duplicate id is the same task in two places, and `createdAt` is
        // immutable — so there is no such thing as the "newer" copy, and the
        // candidate order above is the only thing that decides.
        let candidates = preferDisk ? diskTasks + snapshot.tasks : snapshot.tasks + diskTasks
        var dedupedById: [UUID: TaskReminder] = [:]
        for task in candidates where dedupedById[task.id] == nil {
            dedupedById[task.id] = task
        }
        if !deferred.isEmpty {
            os_log(.info, log: taskReminderLog, "Reconcile deferred for: %{public}@", deferred.joined(separator: ", "))
        }
        os_log(.default, log: taskReminderLog, "Reconciled %d tasks from %d file(s)",
               dedupedById.count, fileURLs.count)
        let sorted = Array(dedupedById.values).sorted { $0.createdAt > $1.createdAt }
        DispatchQueue.main.async { [weak self] in
            self?.tasks = sorted
            self?.noteSyncTimestampNow()
        }
    }

    /// Called on `ioQueue` after every write to the storage folder.
    ///
    /// The timestamp records that the fingerprint change this very write is
    /// about to cause came from us, so the poll watcher does not mistake it for
    /// an edit made on another machine.
    private func noteSyncTimestamp() {
        lastLocalWriteAt = Date()
        // Re-baseline now that our own write is on disk. The next poll then
        // compares against the folder as it stands *including* this write, so
        // there is no difference left for it to mistake for an edit made on
        // another machine. The quiet period below is only a backstop for
        // follow-up changes macOS itself makes to the file.
        lastFingerprint = fingerprintOfStorageDirectory()
        DispatchQueue.main.async { [weak self] in self?.noteSyncTimestampNow() }
    }

    private func noteSyncTimestampNow() {
        lastSyncedAt = Date()
    }

    // MARK: - Remote change watching

    /// How often the storage folder is re-scanned.
    private static let pollInterval: TimeInterval = 2.0

    /// A write by this process within this window explains any fingerprint
    /// change, so changes observed inside it are not treated as remote edits.
    ///
    /// Must exceed `pollInterval`. Otherwise a poll that lands more than this
    /// long after one of our own writes still sees that write as a difference
    /// and reloads the folder — which is how a purely local edit used to get
    /// reported as an incoming iCloud change.
    private static let localWriteQuietPeriod: TimeInterval = 2.5

    /// How many polls between iCloud status re-checks — 30s at the interval
    /// above. Toggling iCloud Drive's "Desktop & Documents" does not reliably
    /// fire `NSUbiquityIdentityDidChange`, so without this the badge could sit on
    /// a stale state for the rest of the session.
    private static let syncStateCheckEveryPolls = 15

    /// Cheap snapshot of the storage folder, used to spot writes from elsewhere.
    private struct DirectoryFingerprint: Equatable {
        struct Entry: Equatable {
            var size: Int
            var modified: TimeInterval
        }
        var entries: [String: Entry]
    }

    /// Starts (or restarts) the watcher. Runs on `ioQueue`.
    ///
    /// `NSMetadataQuery` only ever sees ubiquity containers, so it cannot
    /// observe a plain `~/Documents` folder — not even while iCloud Drive is
    /// replicating it. Polling a fingerprint of the folder works for any synced
    /// location and for plain local storage alike, and mirrors how other
    /// file-sync based apps (e.g. Perch) detect remote writes.
    private func startWatching() {
        stopWatching()
        lastFingerprint = fingerprintOfStorageDirectory()
        os_log(.default, log: taskReminderLog,
               "Watcher on %{public}@ — %d task file(s), iCloud-backed=%{public}@",
               resolvedStorageDirectory.path,
               lastFingerprint?.entries.count ?? -1,
               Self.isICloudBacked(resolvedStorageDirectory) ? "yes" : "no")
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.pollForRemoteChanges() }
        pollTimer = timer
        timer.resume()
    }

    private func stopWatching() {
        pollTimer?.cancel()
        pollTimer = nil
        lastFingerprint = nil
    }

    private func pollForRemoteChanges() {
        pollTick += 1
        if pollTick % Self.syncStateCheckEveryPolls == 0 { refreshSyncState() }

        let current = fingerprintOfStorageDirectory()
        defer { lastFingerprint = current }
        guard let previous = lastFingerprint, previous != current else { return }
        // Our own save may well be what changed the folder; only a change that
        // outlives the quiet period can have come from another machine.
        if let lastWrite = lastLocalWriteAt,
           Date().timeIntervalSince(lastWrite) < Self.localWriteQuietPeriod { return }
        os_log(.default, log: taskReminderLog, "Storage folder changed on disk — reloading from iCloud")
        reconcileAtStartup(preferDisk: true)
    }

    private func fingerprintOfStorageDirectory() -> DirectoryFingerprint? {
        let keys = Set([URLResourceKey.fileSizeKey, .contentModificationDateKey])
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: resolvedStorageDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var map: [String: DirectoryFingerprint.Entry] = [:]
        for url in entries where url.pathExtension == "json" {
            let values = try? url.resourceValues(forKeys: keys)
            map[url.lastPathComponent] = DirectoryFingerprint.Entry(
                size: values?.fileSize ?? 0,
                modified: values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            )
        }
        return DirectoryFingerprint(entries: map)
    }
}

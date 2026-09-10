import Foundation
import os.log

private let taskReminderLog = OSLog(subsystem: "com.cella.tasknote", category: "TaskReminder")

/// iCloud container identifier — shared with brew.app so task data stays
/// consistent across both apps.
private let kICloudContainerID = "iCloud.com.brew.app"

/// Subpath inside the ubiquity container's Documents scope.
private let kICloudSubpath = "task-note"

/// Local storage for Cella: `~/Documents/cella/task-note/`.
private let kCellaStorageSubpath = "cella/task-note"

/// Legacy brew.app local path: `~/Documents/brew/task-note/`.
/// On first launch, Cella migrates any tasks found here into its own storage.
private let kBrewStorageSubpath = "brew/task-note"

/// UserDefaults flag — user may opt out of iCloud.
private let kUserOptedOutOfiCloudKey = "CellaTaskNoteOptedOutOfICloud"

/// Set after brew→cella migration completes so we don't re-import.
private let kLegacyBrewMigrationDoneKey = "CellaTaskNoteLegacyBrewMigrationDone"

// MARK: - Models

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

/// Observable view of the iCloud sync state.
enum TaskReminderSyncState: Equatable {
    case signedIn
    case signedOut
    case temporarilyLocal
    case downloadingFiles
    case unknown

    var description: String {
        switch self {
        case .signedIn:         return "Synced via iCloud"
        case .signedOut:        return "iCloud signed out — stored locally"
        case .temporarilyLocal: return "iCloud disabled — stored locally"
        case .downloadingFiles: return "Downloading from iCloud…"
        case .unknown:          return "Checking iCloud…"
        }
    }
}

// MARK: - Manager

/// Singleton manager for task reminders with iCloud sync.
///
/// Tasks are persisted as JSON files, one per calendar day (e.g. `2026-09-05.json`).
/// Marking a task complete only flips the `completed` flag — it never deletes
/// the record. Data is only removed when the user explicitly deletes a task.
///
/// **Storage.** iCloud (ubiquity container) when available and opted in,
/// otherwise `~/Documents/cella/task-note/`.
///
/// **Migration.** On first launch, any tasks in brew.app's local directory
/// (`~/Documents/brew/task-note/`) are copied into Cella's active storage.
final class TaskReminderManager: ObservableObject {
    static let shared = TaskReminderManager()

    @Published private(set) var tasks: [TaskReminder] = []
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var iCloudSyncState: TaskReminderSyncState = .unknown

    @Published var userOptedOutOfiCloud: Bool {
        didSet {
            UserDefaults.standard.set(userOptedOutOfiCloud, forKey: kUserOptedOutOfiCloudKey)
            let optedOut = userOptedOutOfiCloud
            ioQueue.async { [weak self] in
                self?.refreshSyncState(optedOut: optedOut)
                self?.rebuildStorageAfterToggle()
            }
        }
    }

    private let cellaLocalDirectory: URL
    private let brewLegacyDirectory: URL
    private var resolvedStorageDirectory: URL
    private let ioQueue = DispatchQueue(label: "com.cella.tasknote.io")

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    private var metadataQuery: NSMetadataQuery?
    private var metadataObservers: [NSObjectProtocol] = []
    private var identityChangeObserver: NSObjectProtocol?

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        cellaLocalDirectory = docs.appendingPathComponent(kCellaStorageSubpath, isDirectory: true)
        brewLegacyDirectory = docs.appendingPathComponent(kBrewStorageSubpath, isDirectory: true)
        resolvedStorageDirectory = cellaLocalDirectory
        userOptedOutOfiCloud = UserDefaults.standard.bool(forKey: kUserOptedOutOfiCloudKey)

        ensureDirectoryExists(at: cellaLocalDirectory)

        ioQueue.async { [weak self] in
            guard let self else { return }
            self.migrateFromBrewIfNeeded()
            self.refreshSyncState(optedOut: UserDefaults.standard.bool(forKey: kUserOptedOutOfiCloudKey))
            self.rebuildStorageAfterToggle()
            self.reconcileAtStartup()
            self.startWatchingIfNeeded()
        }

        identityChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let optedOut = self.userOptedOutOfiCloud
            self.ioQueue.async {
                self.refreshSyncState(optedOut: optedOut)
                self.rebuildStorageAfterToggle()
                self.reconcileAtStartup()
                self.startWatchingIfNeeded()
            }
        }
    }

    deinit {
        if let identityChangeObserver { NotificationCenter.default.removeObserver(identityChangeObserver) }
        stopWatching()
    }

    // MARK: - Migration from brew.app

    /// One-time migration: copy brew.app's local task files into Cella's
    /// active storage so existing tasks carry over.
    private func migrateFromBrewIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: kLegacyBrewMigrationDoneKey) else { return }
        guard FileManager.default.fileExists(atPath: brewLegacyDirectory.path) else {
            UserDefaults.standard.set(true, forKey: kLegacyBrewMigrationDoneKey)
            return
        }
        let target = resolveStorageDirectory(optedOut: UserDefaults.standard.bool(forKey: kUserOptedOutOfiCloudKey))
        ensureDirectoryExists(at: target)
        if copyContents(of: brewLegacyDirectory, into: target) {
            UserDefaults.standard.set(true, forKey: kLegacyBrewMigrationDoneKey)
            os_log(.info, log: taskReminderLog, "Migrated brew.app tasks to Cella storage")
        } else {
            os_log(.error, log: taskReminderLog, "brew→cella migration incomplete — will retry next launch")
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

    private func rebuildStorageAfterToggle() {
        let priorDirectory = resolvedStorageDirectory
        let newDir = resolveStorageDirectory(
            optedOut: UserDefaults.standard.bool(forKey: kUserOptedOutOfiCloudKey)
        )
        if newDir == priorDirectory { return }
        ensureDirectoryExists(at: newDir)
        if isUbiquityContainer(priorDirectory) && !isUbiquityContainer(newDir) {
            _ = copyContents(of: priorDirectory, into: newDir)
        }
        resolvedStorageDirectory = newDir
        reconcileAtStartup()
        startWatchingIfNeeded()
    }

    private func resolveStorageDirectory(optedOut: Bool) -> URL {
        if optedOut { return cellaLocalDirectory }
        if let ubiquityDir = ubiquityContainerTaskNoteDirectory() { return ubiquityDir }
        return cellaLocalDirectory
    }

    private func ubiquityContainerTaskNoteDirectory() -> URL? {
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        guard let containerRoot = FileManager.default.url(forUbiquityContainerIdentifier: kICloudContainerID) else {
            os_log(.info, log: taskReminderLog, "iCloud container unavailable — falling back to local")
            return nil
        }
        let docs = containerRoot.appendingPathComponent("Documents", isDirectory: true)
        return docs.appendingPathComponent(kICloudSubpath, isDirectory: true)
    }

    private func isUbiquityContainer(_ url: URL) -> Bool {
        url.path.contains("Mobile Documents") && url.path.contains("iCloud")
    }

    private func refreshSyncState(optedOut: Bool) {
        let token = FileManager.default.ubiquityIdentityToken
        let state: TaskReminderSyncState
        if optedOut {
            state = .temporarilyLocal
        } else if token == nil {
            state = .signedOut
        } else if ubiquityContainerTaskNoteDirectory() != nil {
            state = .signedIn
        } else {
            state = .signedOut
        }
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

    private func copyContents(of src: URL, into dst: URL) -> Bool {
        ensureDirectoryExists(at: dst)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: src, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        var ok = true
        for entry in entries where entry.pathExtension == "json" {
            let target = dst.appendingPathComponent(entry.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
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

    private func saveTask(_ task: TaskReminder) {
        let url = fileURL(for: task.createdAt)
        var dayTasks = loadDayTasks(from: url)
        if let existingIndex = dayTasks.firstIndex(where: { $0.id == task.id }) {
            dayTasks[existingIndex] = task
        } else {
            dayTasks.insert(task, at: 0)
        }
        writeDayTasks(dayTasks, to: url)
        noteSyncTimestamp()
    }

    private func removeTaskFromFile(_ task: TaskReminder) {
        let url = fileURL(for: task.createdAt)
        var dayTasks = loadDayTasks(from: url)
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
        noteSyncTimestamp()
    }

    private func loadDayTasks(from url: URL) -> [TaskReminder] {
        let coordinator = NSFileCoordinator()
        var result: [TaskReminder] = []
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [.resolvesSymbolicLink], error: &coordError) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            if let decoded = try? JSONDecoder().decode([TaskReminder].self, from: data) {
                result = decoded
            } else if let text = String(data: data, encoding: .utf8), text.isEmpty {
                result = []
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

    private func reconcileAtStartup() {
        let dir = resolvedStorageDirectory
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
        DispatchQueue.main.async { [weak self] in
            self?.tasks = sorted
            self?.noteSyncTimestampNow()
        }
    }

    private func noteSyncTimestamp() {
        DispatchQueue.main.async { [weak self] in self?.noteSyncTimestampNow() }
    }

    private func noteSyncTimestampNow() {
        lastSyncedAt = Date()
    }

    // MARK: - iCloud change watching

    private func startWatchingIfNeeded() {
        let dir = resolvedStorageDirectory
        guard isUbiquityContainer(dir) else { stopWatching(); return }
        if metadataQuery == nil {
            let q = NSMetadataQuery()
            q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            q.valueListAttributes = []
            q.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, resolvedStorageDirectory.path)
            metadataQuery = q
            installMetadataObserver(for: q)
            q.start()
            return
        }
        if let query = metadataQuery {
            query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, resolvedStorageDirectory.path)
            query.stop()
            query.start()
        }
    }

    private func stopWatching() {
        metadataQuery?.stop()
        metadataQuery = nil
        for observer in metadataObservers { NotificationCenter.default.removeObserver(observer) }
        metadataObservers.removeAll()
    }

    private func installMetadataObserver(for query: NSMetadataQuery) {
        let initial = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: nil
        ) { [weak self] _ in self?.ioQueue.async { self?.reconcileAtStartup() } }
        let update = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: query, queue: nil
        ) { [weak self] _ in self?.ioQueue.async { self?.reconcileAtStartup() } }
        metadataObservers = [initial, update]
    }
}

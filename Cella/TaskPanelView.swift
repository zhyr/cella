import SwiftUI
import AppKit

/// Whether an inline title edit is open somewhere in the panel.
///
/// Exists because the panel watches for Escape with a *local* key monitor,
/// which sees key events before they are dispatched to the responder chain.
/// While a title is being edited that monitor would otherwise swallow Escape and
/// dismiss the whole panel — draft and all.
///
/// Rather than passing the key through and hoping the focused text field
/// interprets it as "cancel" (SwiftUI's `onExitCommand` is not guaranteed to
/// see it once a monitor has intercepted the event), the open editor hands the
/// monitor a cancel action to run. `consumeEscape()` is therefore the single,
/// deterministic place that decides what Escape means.
///
/// Deliberately not observable: only AppKit input routing reads it, never a view
/// body, so there is nothing to re-render.
final class InlineEditState {
    static let shared = InlineEditState()
    private(set) var isEditing = false
    private var cancelAction: (() -> Void)?

    func begin(cancel: @escaping () -> Void) {
        isEditing = true
        cancelAction = cancel
    }

    func end() {
        isEditing = false
        cancelAction = nil
    }

    /// Cancels the open edit. Returns `false` when there is nothing to cancel,
    /// in which case the caller should dismiss the panel instead.
    func consumeEscape() -> Bool {
        guard isEditing, let cancelAction else { return false }
        cancelAction()
        return true
    }
}

/// Floating task reminder panel shown from the menu bar status item.
struct TaskPanelView: View {
    let onClose: () -> Void
    @ObservedObject private var manager = TaskReminderManager.shared
    @State private var inputText: String = ""
    @State private var hoveredTaskId: UUID?
    /// Tasks whose sub-item lists the user folded away. Absence means expanded,
    /// so a task opens by default and only an explicit collapse is remembered.
    ///
    /// Held here rather than inside `TaskRow` on purpose: the list is a
    /// `LazyVStack`, so a row that scrolls out of view is torn down and its own
    /// `@State` would go with it — the list would spring back open on the way
    /// back. The panel's hosting controller is created once, so this survives
    /// both scrolling and closing the panel.
    @State private var collapsedTaskIDs: Set<UUID> = []
    @State private var isHeaderHovered: Bool = false
    @State private var hoveringSync: Bool = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            header
            inputField
            taskList
        }
        .frame(width: PanelMetrics.panelSize.width, height: PanelMetrics.panelSize.height)
        .background {
            VisualEffectView(
                material: .hudWindow,
                blendingMode: .behindWindow,
                cornerRadius: PanelMetrics.cornerRadius,
                maskSize: PanelMetrics.panelSize
            )
                .overlay {
                    LinearGradient(
                        colors: [Color.white.opacity(0.07), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .overlay(alignment: .bottom) { undoBanner }
        .overlay {
            RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        // No SwiftUI `.shadow` here on purpose. The panel fills the window
        // exactly, so a SwiftUI shadow is clipped at the window edge everywhere
        // except the four transparent corner cut-outs — where it paints a grey
        // wedge with a hard edge. The drop shadow comes from the window itself
        // (`hasShadow`), which now traces the rounded mask instead.
        .animation(.easeOut(duration: 0.18), value: manager.tasks.count)
        .animation(.easeOut(duration: 0.2), value: manager.undoableDeletion?.id)
    }

    // MARK: - Undo Banner

    /// Floats over the list as a toast: deletion is one click away from the
    /// "add sub-item" button, so an accidental tap must stay recoverable.
    @ViewBuilder
    private var undoBanner: some View {
        if let pending = manager.undoableDeletion {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("已删除\(pending.noun)「\(pending.title)」")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Button("撤销") { manager.undoDelete() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .help("恢复\(pending.noun)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.thickMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
            }
            .padding(.horizontal, PanelMetrics.contentInset)
            .padding(.bottom, PanelMetrics.contentInset)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("已删除\(pending.noun)：\(pending.title)")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundStyle(.primary)
                .font(.system(size: 15, weight: .semibold))

            Text("层隅")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            if manager.pendingCount > 0 {
                Text("\(manager.pendingCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }

            iCloudSyncBadge

            Spacer()

            if isHeaderHovered {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("关闭面板 (Esc)")
                .accessibilityLabel("关闭面板")
                .transition(.opacity)
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.horizontal, PanelMetrics.contentInset)
        .padding(.top, PanelMetrics.contentInset)
        .onHover { isHeaderHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHeaderHovered)
    }

    // MARK: - iCloud Sync Badge

    /// Status only — deliberately not a button.
    ///
    /// Whether this folder syncs is macOS's decision, not something the app can
    /// switch. An earlier build offered a click-to-"turn iCloud off" switch that
    /// silently relocated every task into a hidden local folder, which split the
    /// data in two and could strand it outside iCloud altogether. So the badge
    /// now just reports what the system is doing and, when sync is off, points
    /// at the one setting that can turn it on.
    private var iCloudSyncBadge: some View {
        let state = manager.iCloudSyncState
        let (icon, color, label) = syncBadgeVisuals(for: state)

        let badge = HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            if hoveringSync {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(hoveringSync ? Color.white.opacity(0.08) : Color.clear)
        .clipShape(Capsule())

        let lastSync = manager.lastSyncedAt.map { "最近同步：" + Self.syncTimeFormatter.string(from: $0) } ?? ""
        let hint = state == .notSynced
            ? "开启方式：系统设置 › Apple 账户 › iCloud › iCloud 云盘 ›「桌面与文档文件夹」"
            : ""

        return badge
            .help([state.description, lastSync, hint].filter { !$0.isEmpty }.joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("iCloud 状态")
            .accessibilityValue(state.description)
            .onHover { hoveringSync = $0 }
            .animation(.easeOut(duration: 0.15), value: hoveringSync)
    }

    private static let syncTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private func syncBadgeVisuals(for state: TaskReminderSyncState) -> (icon: String, color: Color, label: String) {
        switch state {
        case .syncing:   return ("checkmark.icloud", Color.green, "云同步已开启")
        case .notSynced: return ("icloud.slash", Color.orange, "未同步到 iCloud")
        case .unknown:   return ("bolt.horizontal.icloud", Color.gray, "检测中…")
        }
    }

    // MARK: - Input Field

    private var inputField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 13))

            TextField("添加任务…（回车保存，⌘V 粘贴）", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isInputFocused)
                .onSubmit { commitInput() }

            Button("添加") { commitInput() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        }
        .padding(.horizontal, PanelMetrics.contentInset)
    }

    // MARK: - Task List

    @ViewBuilder
    private var taskList: some View {
        let sorted = manager.sortedTasks
        if sorted.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(sorted) { task in
                        TaskRow(
                            task: task,
                            isHovered: hoveredTaskId == task.id,
                            isExpanded: !collapsedTaskIDs.contains(task.id),
                            onToggle: { manager.toggleCompleted(task) },
                            onDelete: { manager.delete(task) },
                            onRename: { manager.rename(task, to: $0) },
                            onAddSubItem: { manager.addSubItem(to: task, title: $0) },
                            onToggleSubItem: { manager.toggleSubItemCompleted(task: task, subItem: $0) },
                            onDeleteSubItem: { manager.deleteSubItem(task: task, subItem: $0) },
                            onRenameSubItem: { manager.renameSubItem(task: task, subItem: $0, to: $1) },
                            onAddSubSubItem: { manager.addSubSubItem(to: task, subItem: $0, title: $1) },
                            onToggleSubSubItem: { manager.toggleSubSubItemCompleted(task: task, subItem: $0, subSubItem: $1) },
                            onDeleteSubSubItem: { manager.deleteSubSubItem(task: task, subItem: $0, subSubItem: $1) },
                            onRenameSubSubItem: { manager.renameSubSubItem(task: task, subItem: $0, subSubItem: $1, to: $2) },
                            onSetExpanded: { expanded in
                                if expanded { collapsedTaskIDs.remove(task.id) }
                                else { collapsedTaskIDs.insert(task.id) }
                            }
                        ) { hoveredTaskId = $0 }
                    }
                }
                .padding(.horizontal, PanelMetrics.contentInset)
                .padding(.bottom, PanelMetrics.contentInset)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("暂无任务")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("在上方输入提醒并按回车")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func commitInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        manager.addTask(text)
        inputText = ""
        isInputFocused = true
    }
}

// MARK: - Task Row

struct TaskRow: View {
    let task: TaskReminder
    let isHovered: Bool
    /// Whether the sub-item list is showing. Owned by the panel so it outlives
    /// the row being recycled by the `LazyVStack`.
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    let onAddSubItem: (String) -> Void
    let onToggleSubItem: (TaskSubItem) -> Void
    let onDeleteSubItem: (TaskSubItem) -> Void
    let onRenameSubItem: (TaskSubItem, String) -> Void
    let onAddSubSubItem: (TaskSubItem, String) -> Void
    let onToggleSubSubItem: (TaskSubItem, TaskSubItem) -> Void
    let onDeleteSubSubItem: (TaskSubItem, TaskSubItem) -> Void
    let onRenameSubSubItem: (TaskSubItem, TaskSubItem, String) -> Void
    let onSetExpanded: (Bool) -> Void
    let onHover: (UUID?) -> Void

    /// Horizontal padding of the whole task row.
    ///
    /// Set to 0 so the disclosure chevron's leading edge lines up with the
    /// leading edge of the search bar above the list.
    private static let rowPadding: CGFloat = 0
    /// Gap between disclosure, checkbox, and title column in `mainRow`.
    private static let rowSpacing: CGFloat = 6
    /// Width reserved for the expand/collapse arrow.
    private static let disclosureWidth: CGFloat = 9
    /// Visual size of the completion checkbox.
    private static let checkButtonSize: CGFloat = 14

    /// Left inset that puts the root task title — and root-level extras such as
    /// the export status row — in one column.
    ///
    /// Derived rather than hard-coded so widening the arrow can't silently knock
    /// the title out of line: row padding + arrow + gap + check-button + gap.
    private static let contentColumnInset: CGFloat = rowPadding + disclosureWidth + rowSpacing + checkButtonSize + rowSpacing

    /// The root completion checkbox's vertical center line, measured from the
    /// row's leading edge.
    ///
    /// This line doubles as the task-tree spine: sub-item checkboxes are
    /// centered on it, and the vertical guide line is drawn through it.
    private static let checkboxCenter: CGFloat = rowPadding + disclosureWidth + rowSpacing + checkButtonSize / 2

    /// Leading inset for sub-item rows so their checkboxes are centered on the
    /// same vertical line as the root task's checkbox.
    private static let subItemIndent: CGFloat = checkboxCenter - checkButtonSize / 2

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    @State private var isAddingSubItem: Bool = false
    @State private var subItemInputText: String = ""
    @State private var hoveredSubItemId: UUID?
    @FocusState private var isSubItemInputFocused: Bool

    @State private var isEditingTitle: Bool = false
    @State private var titleDraft: String = ""
    @FocusState private var isTitleFocused: Bool

    /// Which Calendar/Reminders hand-off editor is open, if any.
    @State private var scheduleTarget: EventExportTarget?
    @State private var scheduledAt: Date = TaskRow.nextWholeHour()
    @State private var exportStatus: ExportStatus?
    /// Bumped on every status change so a pending auto-dismiss can tell whether
    /// a newer message has replaced the one it was scheduled for.
    @State private var exportStatusGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            mainRow
            if let target = scheduleTarget { scheduleEditor(for: target) }
            if isAddingSubItem { subItemInputField }
            if let exportStatus { exportStatusRow(exportStatus) }
            if !task.subitems.isEmpty && isExpanded { subItemsList }
        }
        .padding(.horizontal, Self.rowPadding)
        .padding(.vertical, 8)
        .background(alignment: .topLeading) { treeGuideLine }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { onHover($0 ? task.id : nil) }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isAddingSubItem)
        .animation(.easeOut(duration: 0.15), value: scheduleTarget != nil)
        .animation(.easeOut(duration: 0.15), value: task.subitems.count)
        .animation(.easeOut(duration: 0.18), value: isExpanded)
    }

    private var mainRow: some View {
        HStack(spacing: Self.rowSpacing) {
            disclosureControl

            Button(action: onToggle) {
                Image(systemName: task.completed ? "checkmark.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(task.completed ? Color.green : Color.secondary.opacity(0.6))
                    .frame(width: Self.checkButtonSize, height: Self.checkButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.completed ? "标记为未完成" : "标记为已完成")

            VStack(alignment: .leading, spacing: 2) {
                titleField
                Text(timeString)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if isHovered {
                HStack(spacing: 8) {
                    Button(action: {
                        isAddingSubItem.toggle()
                        if isAddingSubItem {
                            isSubItemInputFocused = true
                            scheduleTarget = nil
                        }
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isAddingSubItem ? Color.accentColor : .secondary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(isAddingSubItem ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .help("添加子项")
                    .accessibilityLabel("添加子项")

                    Button(action: { presentSchedule(.calendar) }) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 11))
                            .foregroundStyle(scheduleTarget == .calendar ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("加入日历")
                    .accessibilityLabel("加入日历")

                    Button(action: { presentSchedule(.reminder) }) {
                        Image(systemName: "bell.badge")
                            .font(.system(size: 11))
                            .foregroundStyle(scheduleTarget == .reminder ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("加入「提醒事项」")
                    .accessibilityLabel("加入提醒事项")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("删除任务")
                    .accessibilityLabel("删除任务")
                    .transition(.opacity)
                }
                .transition(.opacity)
            }
        }
    }

    /// Expand/collapse affordance for the sub-item list.
    ///
    /// The slot is reserved on every task — childless ones draw an empty
    /// placeholder — so the check-buttons stay in one column as lists open and
    /// close, instead of every row shifting sideways.
    ///
    /// The arrow states the *action*, not the current state: pointing down means
    /// "clicking opens the list below", pointing up means "clicking folds it
    /// away". A state-indicator arrow would point down at a folded row, which
    /// reads as "already open".
    @ViewBuilder
    private var disclosureControl: some View {
        if task.subitems.isEmpty {
            Color.clear.frame(width: Self.disclosureWidth, height: Self.checkButtonSize)
        } else {
            Button(action: { onSetExpanded(!isExpanded) }) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.disclosureWidth, height: Self.checkButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收起子项" : "展开子项")
            .accessibilityLabel(isExpanded ? "收起子项" : "展开子项")
        }
    }

    /// The task title, or an inline editor while it is being renamed.
    ///
    /// Double-click rather than a click: a single click on the row is already
    /// how the eye lands on it, and making that open an editor would fight with
    /// the check-button and the hover actions.
    @ViewBuilder
    private var titleField: some View {
        if isEditingTitle {
            TextField("", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($isTitleFocused)
                .onSubmit { commitTitleEdit() }
                .onChange(of: isTitleFocused) { _, focused in
                    // Clicking anywhere else is a commit — the same way a rename
                    // in Finder behaves, and it keeps the edit from being lost
                    // when the user simply moves on.
                    if !focused { commitTitleEdit() }
                }
        } else {
            Text(task.title)
                .font(.system(size: 12.5))
                .foregroundStyle(task.completed ? .secondary : .primary)
                .strikethrough(task.completed, color: .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginTitleEdit() }
                .help("双击可编辑")
                .blocksWindowBackgroundDrag()
        }
    }

    private func beginTitleEdit() {
        guard !isEditingTitle else { return }
        titleDraft = task.title
        isEditingTitle = true
        InlineEditState.shared.begin { cancelTitleEdit() }
        // The row lives in a LazyVStack; focusing in the same tick can land
        // before the NSTextField exists, so defer to the next runloop pass —
        // same reason as the sub-item input field above.
        DispatchQueue.main.async { isTitleFocused = true }
    }

    private func commitTitleEdit() {
        guard isEditingTitle else { return }
        let draft = titleDraft
        isEditingTitle = false
        titleDraft = ""
        InlineEditState.shared.end()
        // A blank or unchanged title is dropped by the manager, which keeps the
        // original text rather than leaving an unlabelled row behind.
        onRename(draft)
    }

    private func cancelTitleEdit() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        titleDraft = ""
        InlineEditState.shared.end()
    }

    private var subItemInputField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 12))

            TextField("添加子项…", text: $subItemInputText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($isSubItemInputFocused)
                .onSubmit { commitSubItem() }
                .onAppear {
                    // The field is rendered inside a LazyVStack/ScrollView;
                    // requesting focus immediately from the toggle may happen
                    // before layout. Defer to the next runloop tick so the
                    // NSTextField actually exists and can become first responder.
                    DispatchQueue.main.async {
                        isSubItemInputFocused = true
                    }
                }

            Button("添加") { commitSubItem() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(subItemInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, Self.subItemIndent)
        .padding(.vertical, 4)
    }

    private func commitSubItem() {
        let text = subItemInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAddSubItem(text)
        subItemInputText = ""
        isAddingSubItem = false
        // A new sub-item must not land in a list the user has folded away.
        if !isExpanded { onSetExpanded(true) }
    }

    private var subItemsList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(task.subitems) { subItem in
                SubItemRow(
                    subItem: subItem,
                    isHovered: hoveredSubItemId == subItem.id,
                    onToggle: { onToggleSubItem(subItem) },
                    onDelete: { onDeleteSubItem(subItem) },
                    onRename: { onRenameSubItem(subItem, $0) },
                    onAddChild: { onAddSubSubItem(subItem, $0) },
                    onToggleChild: { onToggleSubSubItem(subItem, $0) },
                    onDeleteChild: { onDeleteSubSubItem(subItem, $0) },
                    onRenameChild: { onRenameSubSubItem(subItem, $0, $1) },
                    titleLimit: nil
                ) { hoveredSubItemId = $0 }
            }
        }
        .padding(.leading, Self.subItemIndent)
    }

    /// A subtle vertical guide line that runs through the root checkbox center
    /// for tasks whose sub-item list is currently expanded. Leaf tasks get no line.
    @ViewBuilder
    private var treeGuideLine: some View {
        if !task.subitems.isEmpty && isExpanded {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .padding(.leading, Self.checkboxCenter - 0.5)
        }
    }

    private var timeString: String {
        Self.relativeFormatter.localizedString(for: task.createdAt, relativeTo: Date())
    }

    // MARK: - Hand-off to Calendar / Reminders

    private enum ExportStatus {
        case success(String)
        case failure(EventExportError)

        var isError: Bool {
            if case .failure = self { return true }
            return false
        }

        var text: String {
            switch self {
            case .success(let message): return message
            case .failure(let error): return error.errorDescription ?? "操作失败"
            }
        }
    }

    /// The next whole hour — 14:37 → 15:00.
    ///
    /// An event or reminder in the past is useless, so the picker opens on a
    /// future slot that usually needs no adjusting.
    private static func nextWholeHour(from date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let startOfHour = calendar.date(
            bySettingHour: calendar.component(.hour, from: date),
            minute: 0, second: 0, of: date, matchingPolicy: .strict
        ) ?? date
        return calendar.date(byAdding: .hour, value: 1, to: startOfHour) ?? date
    }

    private func presentSchedule(_ target: EventExportTarget) {
        exportStatus = nil
        // Clicking the active button again closes the editor.
        if scheduleTarget == target {
            scheduleTarget = nil
            return
        }
        // Re-offer the default every time the editor opens, so a date left over
        // from an earlier task can't quietly carry over into this one.
        scheduledAt = Self.nextWholeHour()
        isAddingSubItem = false
        scheduleTarget = target
    }

    private func scheduleEditor(for target: EventExportTarget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: target == .calendar ? "calendar" : "bell")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(target == .calendar ? "加入日历" : "加入「提醒事项」")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Spacer(minLength: 4)

                // `.field` rather than `.compact`: the compact style opens a
                // calendar popover, and the panel dismisses itself on any click
                // it sees outside its own frame.
                DatePicker("", selection: $scheduledAt, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button("确认") { commitSchedule() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("取消") { scheduleTarget = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, Self.contentColumnInset)
    }

    private func commitSchedule() {
        guard let target = scheduleTarget else { return }
        EventExportService.add(
            title: task.title,
            notes: notesForExport,
            at: scheduledAt,
            to: target
        ) { result in
            switch result {
            case .success:
                scheduleTarget = nil
                showExportStatus(.success(target == .calendar ? "已加入日历" : "已加入「提醒事项」"))
            case .failure(let error):
                // Keep the editor open: after granting access in System Settings
                // the user can simply press 确认 again.
                showExportStatus(.failure(error))
            }
        }
    }

    /// Sub-items travel with the task, so a hand-off keeps the breakdown the
    /// user typed instead of only the headline.
    private var notesForExport: String? {
        guard !task.subitems.isEmpty else { return nil }
        return task.subitems
            .map { $0.completed ? "✓ \($0.title)" : "· \($0.title)" }
            .joined(separator: "\n")
    }

    private func showExportStatus(_ status: ExportStatus) {
        exportStatusGeneration &+= 1
        let generation = exportStatusGeneration
        exportStatus = status

        // Success is self-explanatory and shouldn't linger; a failure stays put
        // until the user does something about it.
        guard case .success = status else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard exportStatusGeneration == generation else { return }
            exportStatus = nil
        }
    }

    private func exportStatusRow(_ status: ExportStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(status.isError ? Color.orange : Color.green)

            Text(status.text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if case .failure(let error) = status, error.requiresSystemSettings, let target = error.target {
                Button("打开系统设置") { EventExportService.openPrivacySettings(for: target) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
            }
        }
        .padding(.leading, Self.contentColumnInset)
    }
}

// MARK: - Sub-item Row

struct SubItemRow: View {
    let subItem: TaskSubItem
    let isHovered: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    /// Non-nil means this row is allowed to add a third-level child.
    let onAddChild: ((String) -> Void)?
    let onToggleChild: ((TaskSubItem) -> Void)?
    let onDeleteChild: ((TaskSubItem) -> Void)?
    let onRenameChild: ((TaskSubItem, String) -> Void)?
    /// Longest this row's own title may be; `nil` at the second level, which has
    /// no length rule. Mirrors what the manager enforces when it saves.
    let titleLimit: Int?
    let onHover: (UUID?) -> Void

    @State private var hoveredChildId: UUID?
    @State private var isAddingChild: Bool = false
    @State private var childInputText: String = ""
    @FocusState private var isChildInputFocused: Bool

    @State private var isEditingTitle: Bool = false
    @State private var titleDraft: String = ""
    @FocusState private var isTitleFocused: Bool

    /// Visual size of the completion checkbox; kept in sync with TaskRow.
    private static let checkButtonSize: CGFloat = 14
    /// Horizontal gap inside the sub-item row HStack.
    private static let rowSpacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Self.rowSpacing) {
                Button(action: onToggle) {
                    Image(systemName: subItem.completed ? "checkmark.circle" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(subItem.completed ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: Self.checkButtonSize, height: Self.checkButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(subItem.completed ? "标记为未完成" : "标记为已完成")

                titleField

                Text(Self.createdAtString(for: subItem.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                if isHovered {
                    if onAddChild != nil {
                        Button(action: {
                            isAddingChild.toggle()
                            if isAddingChild { isChildInputFocused = true }
                        }) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isAddingChild ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("添加三级子项")
                        .accessibilityLabel("添加三级子项")
                        .transition(.opacity)
                    }

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("删除")
                    .accessibilityLabel("删除")
                    .transition(.opacity)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { onHover($0 ? subItem.id : nil) }
            .animation(.easeOut(duration: 0.15), value: isHovered)

            if isAddingChild, let onAddChild {
                childInputField(commit: onAddChild)
            }

            if !subItem.subSubItems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(subItem.subSubItems) { child in
                        SubItemRow(
                            subItem: child,
                            isHovered: hoveredChildId == child.id,
                            onToggle: { onToggleChild?(child) },
                            onDelete: { onDeleteChild?(child) },
                            onRename: { onRenameChild?(child, $0) },
                            onAddChild: nil,
                            onToggleChild: nil,
                            onDeleteChild: nil,
                            onRenameChild: nil,
                            titleLimit: TaskReminderManager.subSubItemTitleLimit
                        ) { hoveredChildId = $0 }
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    /// The sub-item's title, or an inline editor while it is being renamed.
    @ViewBuilder
    private var titleField: some View {
        if isEditingTitle {
            HStack(spacing: 6) {
                TextField("", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isTitleFocused)
                    .onSubmit { commitTitleEdit() }
                    .onChange(of: isTitleFocused) { _, focused in
                        if !focused { commitTitleEdit() }
                    }

                // Only third-level rows cap their length, and the cap is applied
                // when the edit is committed — so say so rather than truncating
                // silently behind the user's back.
                if let titleLimit, titleDraft.count > titleLimit {
                    Text("\(titleDraft.count)/\(titleLimit)")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize()
                        .help("超出 \(titleLimit) 字，保存时会截断")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(subItem.title)
                .font(.system(size: 12))
                .foregroundStyle(subItem.completed ? .secondary : .primary)
                .strikethrough(subItem.completed, color: .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginTitleEdit() }
                .help("双击可编辑")
                .blocksWindowBackgroundDrag()
        }
    }

    private func beginTitleEdit() {
        guard !isEditingTitle else { return }
        titleDraft = subItem.title
        isEditingTitle = true
        InlineEditState.shared.begin { cancelTitleEdit() }
        DispatchQueue.main.async { isTitleFocused = true }
    }

    private func commitTitleEdit() {
        guard isEditingTitle else { return }
        let draft = titleDraft
        isEditingTitle = false
        titleDraft = ""
        InlineEditState.shared.end()
        // A blank or over-long title is settled by the manager, which keeps the
        // original text rather than leaving an unlabelled row behind.
        onRename(draft)
    }

    private func cancelTitleEdit() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        titleDraft = ""
        InlineEditState.shared.end()
    }

    private var trimmedChildText: String {
        childInputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func childInputField(commit: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 11))

            TextField("三级子项…", text: $childInputText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($isChildInputFocused)
                .onSubmit { commitChild(commit: commit) }
                .onAppear {
                    DispatchQueue.main.async { isChildInputFocused = true }
                }

            // The cap is applied on commit rather than on every keystroke:
            // rewriting the bound text from inside `onChange` interferes with an
            // input method that is still composing, and this app is used in
            // Chinese. Showing the count keeps the truncation from being a
            // surprise instead.
            if childInputText.count > TaskReminderManager.subSubItemTitleLimit {
                Text("\(childInputText.count)/\(TaskReminderManager.subSubItemTitleLimit)")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("超出 \(TaskReminderManager.subSubItemTitleLimit) 字，添加时会截断")
            }

            Button("添加") { commitChild(commit: commit) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(trimmedChildText.isEmpty)
        }
        .padding(.leading, 16)
        .padding(.vertical, 2)
    }

    private func commitChild(commit: (String) -> Void) {
        guard !trimmedChildText.isEmpty else { return }
        // Truncation is left to the manager, so the cap has exactly one owner.
        commit(trimmedChildText)
        childInputText = ""
        isAddingChild = false
    }

    /// Formats a sub-item's timestamp:
    /// - under 24 hours: `HH:mm` (24-hour)
    /// - 24 hours to 7 days: `MM/dd EEE`
    /// - 7 days to a year: `MM/dd`
    /// - a year or more: `yyyy/MM/dd`
    ///
    /// The boundaries are elapsed durations, which is how the ranges were
    /// specified. One consequence worth knowing: something from a previous
    /// calendar year but less than 365 days old shows without its year. If the
    /// year should appear as soon as the calendar year changes, that is the
    /// comparison to change.
    static func createdAtString(for date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if interval < 24 * 60 * 60 {
            f.dateFormat = "HH:mm"
        } else if interval < 7 * 24 * 60 * 60 {
            f.dateFormat = "MM/dd EEE"
        } else if interval < 365 * 24 * 60 * 60 {
            f.dateFormat = "MM/dd"
        } else {
            f.dateFormat = "yyyy/MM/dd"
        }
        return f.string(from: date)
    }
}

// MARK: - Window background drag opt-out

/// Makes the view it backs keep its own mouse gestures instead of handing the
/// mouse-down to the panel's "drag anywhere by the background" behaviour.
///
/// The panel sets `isMovableByWindowBackground`, which makes AppKit claim the
/// mouse-down on any region whose hit-tested `NSView` allows it — including
/// plain SwiftUI views that carry a gesture. Without this, the
/// double-click-to-edit on a task title would be swallowed by a window drag.
/// Controls (text fields, buttons, scroll views) opt out on their own.
private struct WindowBackgroundDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BlockerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class BlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

private extension View {
    /// Keep the wrapped view's own mouse gestures from being turned into a
    /// window drag.
    func blocksWindowBackgroundDrag() -> some View {
        background(WindowBackgroundDragBlocker())
    }
}

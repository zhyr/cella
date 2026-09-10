import SwiftUI
import AppKit

/// Floating task reminder panel shown from the menu bar status item.
struct TaskPanelView: View {
    let onClose: () -> Void
    @ObservedObject private var manager = TaskReminderManager.shared
    @State private var inputText: String = ""
    @State private var hoveredTaskId: UUID?
    @State private var isHeaderHovered: Bool = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            header
            inputField
            taskList
        }
        .frame(width: PanelMetrics.panelSize.width, height: PanelMetrics.panelSize.height)
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .overlay {
                    LinearGradient(
                        colors: [Color.white.opacity(0.07), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 26, x: 0, y: 12)
        .animation(.easeOut(duration: 0.18), value: manager.tasks.count)
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
                .help("Close")
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
                            onToggle: { manager.toggleCompleted(task) },
                            onDelete: { manager.delete(task) },
                            onAddSubItem: { manager.addSubItem(to: task, title: $0) },
                            onToggleSubItem: { manager.toggleSubItemCompleted(task: task, subItem: $0) },
                            onDeleteSubItem: { manager.deleteSubItem(task: task, subItem: $0) }
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
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onAddSubItem: (String) -> Void
    let onToggleSubItem: (TaskSubItem) -> Void
    let onDeleteSubItem: (TaskSubItem) -> Void
    let onHover: (UUID?) -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    @State private var isAddingSubItem: Bool = false
    @State private var subItemInputText: String = ""
    @State private var hoveredSubItemId: UUID?
    @FocusState private var isSubItemInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            mainRow
            if isAddingSubItem { subItemInputField }
            if !task.subitems.isEmpty { subItemsList }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { onHover($0 ? task.id : nil) }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isAddingSubItem)
        .animation(.easeOut(duration: 0.15), value: task.subitems.count)
    }

    private var mainRow: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(task.completed ? Color.green : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(task.completed ? .secondary : .primary)
                    .strikethrough(task.completed, color: .secondary)
                    .lineLimit(2)
                Text(timeString)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if isHovered {
                HStack(spacing: 8) {
                    Button(action: {
                        isAddingSubItem.toggle()
                        if isAddingSubItem { isSubItemInputFocused = true }
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isAddingSubItem ? Color.accentColor : .secondary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(isAddingSubItem ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .help("添加子项")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
                .transition(.opacity)
            }
        }
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

            Button("添加") { commitSubItem() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(subItemInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 26)
        .padding(.vertical, 4)
    }

    private func commitSubItem() {
        let text = subItemInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAddSubItem(text)
        subItemInputText = ""
        isAddingSubItem = false
    }

    private var subItemsList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(task.subitems) { subItem in
                SubItemRow(
                    subItem: subItem,
                    isHovered: hoveredSubItemId == subItem.id,
                    onToggle: { onToggleSubItem(subItem) },
                    onDelete: { onDeleteSubItem(subItem) }
                ) { hoveredSubItemId = $0 }
            }
        }
        .padding(.leading, 26)
    }

    private var timeString: String {
        Self.relativeFormatter.localizedString(for: task.createdAt, relativeTo: Date())
    }
}

// MARK: - Sub-item Row

struct SubItemRow: View {
    let subItem: TaskSubItem
    let isHovered: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onHover: (UUID?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: subItem.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(subItem.completed ? Color.green : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)

            Text(subItem.title)
                .font(.system(size: 12))
                .foregroundStyle(subItem.completed ? .secondary : .primary)
                .strikethrough(subItem.completed, color: .secondary)
                .lineLimit(2)

            Spacer(minLength: 4)

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { onHover($0 ? subItem.id : nil) }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

import SwiftUI
import AppKit
import ServiceManagement

@main
struct CellaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// App delegate that installs the menu bar status item and manages the
/// floating task panel. Cella runs as an `LSUIElement` agent — no Dock icon,
/// no main window; the only UI surface is the menu bar item and its panel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelManager: PanelManager?
    private var panelRequestObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        panelManager = PanelManager(statusItem: statusItem)
        observePanelRequests()

        // 主动实例化任务管理器。它只在 `TaskPanelView` 里被引用，而面板窗口是点开
        // 图标时才创建的，所以不在这里提前触碰的话，用户没打开过面板之前既不会读取
        // 数据，也不会启动对 iCloud 远端变更的监听 —— 同步看起来就像没生效。
        _ = TaskReminderManager.shared
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Cella")
        button.image?.isTemplate = true

        // Do NOT set statusItem.menu — if set, the button action is never
        // called (the menu intercepts all clicks). Instead we handle left-click
        // (toggle panel) and right-click (context menu) in the action.
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 监听来自 Perch 的“唤起面板”请求。
    ///
    /// Perch 标题栏里的 Cella 图标靠一条分布式通知来唤起本面板：Cella 是
    /// `LSUIElement` 应用，`activate` 不会让任何窗口出现，面板只能由 Cella 自己弹出。
    /// 通知名与 Perch 侧 `openCellaApp()` 保持一致。
    private func observePanelRequests() {
        panelRequestObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.cella.app.showPanel"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.panelManager?.showPanel()
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent, let button = statusItem.button else { return }
        switch event.type {
        case .rightMouseUp:
            showContextMenu(for: button, with: event)
        default:
            panelManager?.togglePanel()
        }
    }

    private func showContextMenu(for button: NSStatusBarButton, with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "关于层隅", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let launchItem = menu.addItem(
            withTitle: "开机启动",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出层隅", action: #selector(quit), keyEquivalent: "q")
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        sender.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "层隅"
        alert.informativeText = """
            轻盈的菜单栏任务清单

            数据默认保存在 ~/Documents/cella/task-note/
            若 iCloud 可用则自动同步。
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - Main Menu
    /// Sets up a minimal main menu with an Edit menu so SwiftUI text fields
    /// receive standard editing commands (cut/copy/paste/select-all/delete)
    /// through the responder chain. Without this, menu-bar-only (LSUIElement)
    /// apps have no Edit menu and those shortcuts / menu actions are disabled.
    private func setupMainMenu() {
        let mainMenu = NSMenu(title: "MainMenu")

        // App menu
        let appMenuItem = NSMenuItem(title: "Cella", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "层隅")
        appMenu.addItem(withTitle: "关于层隅", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出层隅", action: #selector(quit), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu. These selectors are implemented by AppKit's responder
        // chain (NSTextView / NSUndoManager) and are not visible to Swift, so
        // they are resolved by name rather than `#selector`.
        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "删除", action: NSSelectorFromString("delete:"), keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

/// 开机启动（登录项）的注册与查询，包装 `SMAppService`。
///
/// 这是 `SMLoginItemSetEnabled` 的现代替代：不需要 helper 进程、不需要
/// entitlement，对 Developer ID 直接签名的非沙盒 `LSUIElement` 应用开箱即用。
/// 注册记录跟随 Cella 所在路径 —— 用户从 DMG 里直接运行时路径不稳定，
/// 所以失败时提醒先安装到「应用程序」。
enum LoginItem {
    /// Cella 当前是否已注册为登录项。菜单每次右键弹出时重建，读到的是最新状态。
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法设置开机启动"
            alert.informativeText = """
                注册登录项失败：\(error.localizedDescription)

                请确认 Cella 已安装到「应用程序」文件夹后再试。
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }

        // 注册后仍待批准：把用户带到 系统设置 › 通用 › 登录项 完成确认。
        if enabled, service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

/// Owns the floating panel window and coordinates its show/hide lifecycle
/// with the menu bar status item. Clicking outside the panel dismisses it.
final class PanelManager: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private var window: NSWindow?
    private var eventMonitor: Any?
    private var keyMonitor: Any?
    private var dragMonitor: Any?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        super.init()
    }

    func togglePanel() {
        if let window, window.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    /// 显示面板。除状态栏图标左键外，Perch 的 Cella 图标也会通过分布式通知走到这里。
    func showPanel() {
        if window == nil {
            createWindow()
        }
        guard let window else { return }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        // Make the panel the key window so SwiftUI text fields can receive
        // keyboard input. Mirrors brew.app's ClipboardPanelManager.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak window] in
            window?.makeKey()
        }
        installEventMonitor()
    }

    private func hidePanel() {
        window?.orderOut(nil)
        removeEventMonitor()
        // The edit that claimed this flag is gone with the window. Leaving it set
        // would stop Escape from dismissing the panel for the rest of the session.
        InlineEditState.shared.end()
    }

    private func createWindow() {
        let hosting = NSHostingController(rootView: TaskPanelView(onClose: { [weak self] in self?.hidePanel() }))
        let window = TaskPanel(contentRect: NSRect(origin: .zero, size: PanelMetrics.panelSize))
        window.contentViewController = hosting
        window.delegate = self
        self.window = window
        placeInitialWindow(window)
        installHeaderDrag()
    }

    // MARK: - Header drag

    /// Height of the header strip, matching `TaskPanelView.header`:
    /// 12pt top inset + 22pt row, plus a few points of the gap above the input.
    private static let headerDragHeight: CGFloat = 38
    /// Trailing inset reserved for the close button (12pt padding + 22pt control).
    private static let headerCloseWidth: CGFloat = 36

    /// The hosting view swallows background drags, so the header is moved by
    /// tracking the mouse ourselves. The close button stays clickable.
    private func installHeaderDrag() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isHeaderDrag(event) else { return event }
            self.dragPanel(from: event)
            return nil
        }
    }

    private func isHeaderDrag(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isVisible,
              let content = window.contentView else { return false }
        let point = event.locationInWindow
        let bounds = content.bounds
        guard point.y >= bounds.maxY - Self.headerDragHeight, point.y <= bounds.maxY else { return false }
        guard point.x >= bounds.minX, point.x <= bounds.maxX - Self.headerCloseWidth else { return false }
        return true
    }

    private func dragPanel(from event: NSEvent) {
        guard let window else { return }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .greatestFiniteMagnitude,
            mode: .eventTracking
        ) { [weak window] next, stop in
            guard let next else {
                stop.pointee = true
                return
            }
            switch next.type {
            case .leftMouseUp:
                stop.pointee = true
            case .leftMouseDragged:
                let mouse = NSEvent.mouseLocation
                window?.setFrameOrigin(NSPoint(
                    x: startOrigin.x + (mouse.x - startMouse.x),
                    y: startOrigin.y + (mouse.y - startMouse.y)
                ))
            default:
                break
            }
        }
    }

    // MARK: - Placement

    /// Where the panel sits, remembered across launches once the user drags it.
    private static let originDefaultsKey = "cella.panel.origin"

    /// Origin the panel was last placed at by code. Compared in `windowDidMove`
    /// so an automatic placement is never mistaken for a user drag.
    private var programmaticOrigin: NSPoint?

    /// First-show placement: at the last position the user dragged the panel to,
    /// when that spot is still on a connected display; otherwise just below the
    /// status item, clamped so a status item near a display edge can't push the
    /// panel off-screen.
    private func placeInitialWindow(_ window: NSWindow) {
        let size = window.frame.size

        if let saved = savedOrigin(), Self.isOnScreen(saved, size: size) {
            setOriginProgrammatically(saved, on: window)
            return
        }

        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? buttonFrame
        let x = min(max(buttonFrame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = max(buttonFrame.minY - size.height - 8, visible.minY + 8)
        setOriginProgrammatically(NSPoint(x: x, y: y), on: window)
    }

    private func savedOrigin() -> NSPoint? {
        guard let string = UserDefaults.standard.string(forKey: Self.originDefaultsKey) else { return nil }
        return NSPointFromString(string)
    }

    /// A saved origin only counts if the panel would still land on a display —
    /// the screen it was recorded on may have been unplugged since.
    private static func isOnScreen(_ origin: NSPoint, size: NSSize) -> Bool {
        let frame = NSRect(origin: origin, size: size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    private func setOriginProgrammatically(_ origin: NSPoint, on window: NSWindow) {
        programmaticOrigin = origin
        window.setFrameOrigin(origin)
    }

    // MARK: - Outside-click dismissal

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, window.isVisible else { return }
            if !NSPointInRect(event.locationInWindow, window.frame) {
                self.hidePanel()
            }
        }
        // Escape dismisses the panel. A local monitor is required because the
        // panel is borderless and never runs a modal session, so no `cancel:`
        // action is dispatched through the responder chain.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Escape
            // An open title edit claims Escape to cancel itself, so the panel —
            // and the draft with it — survives. Otherwise, dismiss.
            if InlineEditState.shared.consumeEscape() { return nil }
            self?.hidePanel()
            return nil
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        removeEventMonitor()
    }

    /// Remember where the user dragged the panel so the next launch reopens it
    /// there. Programmatic placements are filtered out so the initial anchor
    /// doesn't overwrite a position the user chose earlier.
    func windowDidMove(_ notification: Notification) {
        guard let window, window.frame.origin != programmaticOrigin else { return }
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: Self.originDefaultsKey)
    }
}

/// Borderless floating panel that hosts the task UI.
///
/// A plain borderless `NSWindow` returns `false` for `canBecomeKey`, so its
/// SwiftUI `TextField`s can never become first responder — typing, pasting,
/// editing and deleting silently stop working. Subclassing `NSPanel` and
/// overriding `canBecomeKey` / `canBecomeMain` fixes that.
///
/// Mirrors brew.app's `ClipboardPanel` (`DynamicIsland/components/Clipboard/ClipboardPanel.swift`).
final class TaskPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        // The SwiftUI hosting view fills this borderless panel, so AppKit never
        // sees a bare background and `isMovableByWindowBackground` does not move
        // the window. Header dragging is handled by `PanelManager`.
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }

    // Required for text fields to receive keyboard focus.
    override var canBecomeKey: Bool { true }

    // Required for text input / editing commands to be routed here.
    override var canBecomeMain: Bool { true }
}

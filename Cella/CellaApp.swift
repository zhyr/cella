import SwiftUI
import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        panelManager = PanelManager(statusItem: statusItem)

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
        menu.addItem(withTitle: "退出层隅", action: #selector(quit), keyEquivalent: "q")
        NSMenu.popUpContextMenu(menu, with: event, for: button)
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

/// Owns the floating panel window and coordinates its show/hide lifecycle
/// with the menu bar status item. Clicking outside the panel dismisses it.
final class PanelManager: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private var window: NSWindow?
    private var eventMonitor: Any?
    private var keyMonitor: Any?

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

    private func showPanel() {
        if window == nil {
            createWindow()
        }
        guard let window else { return }

        // Position the window just below the menu bar item, clamped to the
        // screen so a status item near a display edge can't push it off-screen.
        if let button = statusItem.button,
           let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.frame)
            let size = PanelMetrics.panelSize
            let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? buttonFrame
            let x = min(max(buttonFrame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
            let y = max(buttonFrame.minY - size.height - 8, visible.minY + 8)
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

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
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }

    // Required for text fields to receive keyboard focus.
    override var canBecomeKey: Bool { true }

    // Required for text input / editing commands to be routed here.
    override var canBecomeMain: Bool { true }
}

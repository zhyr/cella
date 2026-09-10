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
        setupStatusItem()
        panelManager = PanelManager(statusItem: statusItem)
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
        menu.addItem(NSMenuItem(title: "退出 层隅", action: #selector(quit), keyEquivalent: "q"))
        menu.addItem(withTitle: "关于 Cella", action: #selector(showAbout), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Cella 层隅"
        alert.informativeText = "独立任务管理应用\n\n数据存储于 ~/Documents/cella/task-note/"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

/// Owns the floating panel window and coordinates its show/hide lifecycle
/// with the menu bar status item. Clicking outside the panel dismisses it.
final class PanelManager: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private var window: NSWindow?
    private var eventMonitor: Any?

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

        // Position the window just below the menu bar item.
        if let button = statusItem.button,
           let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.frame)
            let panelWidth = PanelMetrics.panelSize.width
            let x = buttonFrame.midX - panelWidth / 2
            let y = buttonFrame.minY - PanelMetrics.panelSize.height - 8
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installEventMonitor()
    }

    private func hidePanel() {
        window?.orderOut(nil)
        removeEventMonitor()
    }

    private func createWindow() {
        let hosting = NSHostingController(rootView: TaskPanelView(onClose: { [weak self] in self?.hidePanel() }))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: PanelMetrics.panelSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
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
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        removeEventMonitor()
    }
}

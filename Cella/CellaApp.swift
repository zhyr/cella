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
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Cella")
            button.image?.isTemplate = true
            button.action = #selector(togglePanel(_:))
            button.target = self
        }

        // Right-click menu with Quit option.
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "退出 Cella", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func togglePanel(_ sender: Any?) {
        panelManager?.togglePanel()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Owns the floating NSPanel and coordinates its show/hide lifecycle with
/// the menu bar status item. Clicking outside the panel dismisses it.
final class PanelManager: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private var panel: NSPanel?
    private var eventMonitor: Any?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        super.init()
    }

    func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        if panel == nil {
            createPanel()
        }
        guard let panel else { return }

        // Position panel just below the menu bar item.
        if let button = statusItem.button,
           let window = button.window {
            let buttonFrame = window.convertToScreen(button.frame)
            let panelWidth = PanelMetrics.panelSize.width
            let x = buttonFrame.midX - panelWidth / 2
            let y = buttonFrame.minY - PanelMetrics.panelSize.height - 8
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installEventMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeEventMonitor()
    }

    private func createPanel() {
        let hosting = NSHostingController(rootView: TaskPanelView(onClose: { [weak self] in self?.hidePanel() }))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: PanelMetrics.panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        self.panel = panel
    }

    // MARK: - Outside-click dismissal

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if !NSPointInRect(event.locationInWindow, panel.frame) {
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

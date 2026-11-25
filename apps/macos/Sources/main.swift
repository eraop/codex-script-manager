import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = ScriptManager()
    private var bridge: ScriptManagerBridge?
    private var bridgeOnly: Bool
    private var didLaunch = false
    private var duplicate = false
    private var handoffScheduled = false
    private var pendingURLs: [URL] = []
    private var window: NSWindow?
    private var folderPicker: NSOpenPanel?
    private var isPickingFolder = false
    private var hostLanguage: ScriptManagerLanguage?

    init(bridgeOnly: Bool) {
        self.bridgeOnly = bridgeOnly
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            bridge = try ScriptManagerBridge { [weak self] request in
                if let self { return self.handleBridgeRequest(request) }
                let language = request.locale.map { ScriptManagerLanguage(locale: $0) } ?? .preferred
                return ["ok": false, "error": language.text("Script Manager has quit.", "脚本管理器已退出。")]
            }
        } catch ScriptManagerBridge.Failure.occupied {
            didLaunch = true
            duplicate = true
            if bridgeOnly && pendingURLs.isEmpty {
                NSApp.terminate(nil)
            } else {
                scheduleNativeHandoff()
            }
            return
        } catch {
            NSLog("Script Manager bridge unavailable: %@", error.localizedDescription)
            if bridgeOnly {
                NSApp.terminate(nil)
                return
            }
        }

        installMenu()
        didLaunch = true
        manager.synchronizeProjects()
        if !pendingURLs.isEmpty {
            for url in pendingURLs { manager.openProject(url) }
            pendingURLs.removeAll()
            showWindow()
        } else if !bridgeOnly {
            showWindow()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !didLaunch || duplicate {
            pendingURLs.append(contentsOf: urls)
            if duplicate { scheduleNativeHandoff() }
            return
        }
        refreshNativeLanguage()
        for url in urls { manager.openProject(url) }
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard didLaunch, !bridgeOnly else { return false }
        if duplicate {
            scheduleNativeHandoff()
        } else {
            refreshNativeLanguage()
            showWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard manager.hasActiveJobs else { return .terminateNow }
        manager.stopAll { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    private func showWindow() {
        manager.synchronizeProjects()
        if bridgeOnly {
            bridgeOnly = false
            NSApp.setActivationPolicy(.regular)
        }
        if window == nil {
            let view = ScriptManagerView(manager: manager) { [weak self] in self?.openFolder() }
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 930, height: 610),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.title = manager.language.appTitle
            panel.contentView = NSHostingView(rootView: view)
            panel.contentMinSize = NSSize(width: 670, height: 390)
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.center()
            panel.setFrameAutosaveName("ScriptManager")
            window = panel
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        activate()
    }

    private func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func openFolder() {
        requestFolderPicker(useSheet: true)
    }

    private func requestFolderPicker(useSheet: Bool) {
        guard !isPickingFolder else { return }
        isPickingFolder = true
        // Reply to the bridge before AppKit connects to the folder picker service.
        DispatchQueue.main.async { [weak self] in
            self?.presentFolderPicker(useSheet: useSheet)
        }
    }

    private func presentFolderPicker(useSheet: Bool) {
        let picker = NSOpenPanel()
        folderPicker = picker
        localize(picker)
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = manager.selectedProject.flatMap { $0.isAvailable ? $0.directory : nil }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let finished: (NSApplication.ModalResponse) -> Void = { [weak self, weak picker] response in
            guard let self else { return }
            let url = response == .OK ? picker?.url : nil
            self.folderPicker = nil
            self.isPickingFolder = false
            if let url { self.manager.openProject(url, persist: true) }
        }
        if useSheet, let window, window.isVisible {
            picker.beginSheetModal(for: window, completionHandler: finished)
        } else {
            activate()
            picker.begin(completionHandler: finished)
        }
    }

    private func handleBridgeRequest(_ request: ScriptManagerBridge.Request) -> [String: Any] {
        if let locale = request.locale {
            let language = ScriptManagerLanguage(locale: locale)
            hostLanguage = language
            updateLanguage(language)
        } else if request.method == "revealNative" {
            refreshNativeLanguage()
        }
        if request.method == "revealNative" {
            if let path = request.projectId {
                guard path.hasPrefix("/") else {
                    return ["ok": false, "error": manager.language.text("Project path must be absolute.", "项目目录必须是绝对路径。")]
                }
                manager.openProject(URL(fileURLWithPath: path, isDirectory: true))
            }
            showWindow()
            return ["ok": true]
        }
        if request.method == "choose" {
            requestFolderPicker(useSheet: false)
        }
        return manager.bridgeResponse(to: request, pickPending: isPickingFolder)
    }

    private func localize(_ picker: NSOpenPanel) {
        picker.title = manager.language.openProjectTitle
        picker.prompt = manager.language.text("Open", "打开")
    }

    private func refreshNativeLanguage() {
        updateLanguage(ScriptManagerLanguage.codexPreference ?? hostLanguage ?? .systemPreference)
    }

    private func updateLanguage(_ language: ScriptManagerLanguage) {
        guard manager.language != language else { return }
        manager.language = language
        window?.title = language.appTitle
        if let folderPicker { localize(folderPicker) }
        installMenu()
    }

    private func scheduleNativeHandoff() {
        guard !handoffScheduled else { return }
        handoffScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let urls = self.pendingURLs
            self.pendingURLs.removeAll()
            ScriptManagerBridge.forwardNativeOpen(urls) { [weak self] in
                guard let self else { return }
                self.handoffScheduled = false
                if self.pendingURLs.isEmpty { NSApp.terminate(nil) } else { self.scheduleNativeHandoff() }
            }
        }
    }

    private func installMenu() {
        let language = manager.language
        let menu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu(title: language.appTitle)
        let open = applicationMenu.addItem(withTitle: language.openProjectTitle + "…", action: #selector(openFolder), keyEquivalent: "o")
        open.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: language.text("Quit Script Manager", "退出脚本管理"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationMenuItem.submenu = applicationMenu
        menu.addItem(applicationMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: language.text("Edit", "编辑"))
        editMenu.addItem(withTitle: language.text("Cut", "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: language.text("Copy", "复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: language.text("Paste", "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: language.text("Select All", "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        menu.addItem(editMenuItem)
        NSApp.mainMenu = menu
    }
}

if CommandLine.arguments.dropFirst() == ["--pinned-projects"] {
    let pinned = CodexProjectCatalog().read().filter(\.pinned)
    let paths = pinned.map {
        URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }
    if let output = try? JSONEncoder().encode(paths) { FileHandle.standardOutput.write(output) }
    exit(0)
}

let application = NSApplication.shared
let bridgeOnly = CommandLine.arguments.contains("--mcp-bridge")
let delegate = AppDelegate(bridgeOnly: bridgeOnly)
application.delegate = delegate
application.setActivationPolicy(bridgeOnly ? .accessory : .regular)
application.run()

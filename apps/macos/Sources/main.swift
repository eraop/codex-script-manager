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
    private var backToCodexButton: NSButton?
    private var returnToCodexTask: Task<Void, Never>?
    private var folderPicker: NSOpenPanel?
    private var isPickingFolder = false
    private var hostLanguage: ScriptManagerLanguage?

    init(bridgeOnly: Bool) {
        self.bridgeOnly = bridgeOnly
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            bridge = try ScriptManagerBridge { [weak self] request, reply in
                if let self {
                    self.handleBridgeRequest(request, reply: reply)
                } else {
                    let language = request.locale.map { ScriptManagerLanguage(locale: $0) } ?? .preferred
                    reply(["ok": false, "error": language.text("Script Manager has quit.", "脚本管理器已退出。")])
                }
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
        returnToCodexTask?.cancel()
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
            installBackToCodexButton(in: panel)
            window = panel
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        activate()
    }

    private func installBackToCodexButton(in panel: NSWindow) {
        let button = NSButton(title: manager.language.backToCodexTitle, target: self, action: #selector(returnToCodex))
        button.bezelStyle = .toolbar
        button.controlSize = .small
        let container = NSStackView(views: [button])
        container.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        container.setFrameSize(container.fittingSize)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        panel.addTitlebarAccessoryViewController(accessory)
        backToCodexButton = button
    }

    @objc private func returnToCodex() {
        returnToCodexTask?.cancel()
        guard let codex = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .first(where: { !$0.isTerminated }) else {
            NSSound.beep()
            return
        }
        if codex.isActive {
            window?.orderOut(nil)
            return
        }

        let requested: Bool
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: codex)
            requested = codex.activate(from: .current)
        } else {
            requested = codex.activate(options: .activateIgnoringOtherApps)
        }
        guard requested else {
            NSSound.beep()
            return
        }

        // An allowed activation request may finish asynchronously or may never switch apps.
        returnToCodexTask = Task { @MainActor [weak self] in
            for _ in 0..<20 {
                guard !Task.isCancelled else { return }
                if codex.isActive {
                    self?.window?.orderOut(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
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

    private func handleBridgeRequest(_ request: ScriptManagerBridge.Request, reply: @escaping ([String: Any]) -> Void) {
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
                    reply(["ok": false, "error": manager.language.text("Project path must be absolute.", "项目目录必须是绝对路径。")])
                    return
                }
                manager.openProject(URL(fileURLWithPath: path, isDirectory: true))
            }
            showWindow()
            reply(["ok": true])
            return
        }
        if request.method == "choose" {
            requestFolderPicker(useSheet: false)
        }
        if request.method == "add_command" {
            manager.synchronizeProjects(force: true)
            guard let projectID = request.projectId, let rootPath = request.rootPath, let candidateID = request.candidateId else {
                reply(["ok": false, "error": manager.language.text("Select a suggested command.", "请选择一条建议的命令。")])
                return
            }
            manager.saveCandidate(.init(projectID: projectID, rootPath: rootPath, candidateID: candidateID)) { error in
                if let error {
                    reply(["ok": false, "error": error])
                } else {
                    reply(self.manager.bridgeResponse(to: request, pickPending: self.isPickingFolder))
                }
            }
            return
        }
        reply(manager.bridgeResponse(to: request, pickPending: isPickingFolder))
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
        if let button = backToCodexButton, let container = button.superview {
            button.title = language.backToCodexTitle
            container.setFrameSize(NSSize(width: container.fittingSize.width, height: container.frame.height))
        }
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
    let paths = pinned.compactMap(\.rootPaths.first).map {
        URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
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

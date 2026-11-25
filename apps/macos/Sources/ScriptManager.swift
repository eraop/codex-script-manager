import AppKit
import SwiftUI

struct ManagedProject: Identifiable {
    enum Source: String {
        case codex, manual, session
    }

    let directory: URL
    let displayName: String?
    let source: Source
    let isAvailable: Bool
    let isPinned: Bool
    var tasks: [ScriptTask] = []
    var isScanning = false
    var commandConfigError: ScriptCatalog.CommandConfigError?

    var id: String { directory.path }
    var name: String { displayName ?? (directory.lastPathComponent.isEmpty ? id : directory.lastPathComponent) }
}

enum TaskStatus: Equatable {
    case idle, running, stopping, stopped, succeeded, failed(Int32?)

    var isActive: Bool { self == .running || self == .stopping }

    var kind: String {
        switch self {
        case .idle: return "idle"
        case .running: return "running"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        }
    }

    func label(in language: ScriptManagerLanguage) -> String {
        switch self {
        case .idle: return language.text("Idle", "未运行")
        case .running: return language.text("Running", "运行中")
        case .stopping: return language.text("Stopping", "正在停止")
        case .stopped: return language.text("Stopped", "已停止")
        case .succeeded: return language.text("Succeeded", "成功")
        case .failed(let code):
            return code.map { language.text("Exit code \($0)", "退出码 \($0)") }
                ?? language.text("Launch failed", "启动失败")
        }
    }

    var color: Color {
        switch self {
        case .idle, .stopped: return .secondary
        case .running, .succeeded: return .green
        case .stopping: return .orange
        case .failed: return .red
        }
    }
}

final class TaskRun: ObservableObject {
    @Published var status: TaskStatus = .idle
    @Published private(set) var log = ""
    var process: ScriptProcess?
    var language: ScriptManagerLanguage = .initial

    private static let logLimit = 120_000
    private static let terminalControl = try! NSRegularExpression(pattern: "\\x1B(?:\\[[0-?]*[ -/]*[@-~]|\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\))")

    func append(_ text: String) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let clean = Self.terminalControl.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        log.append(clean.replacingOccurrences(of: "\r\n", with: "\n"))
        if log.utf8.count > Self.logLimit {
            let retained = log.utf8.suffix(Self.logLimit * 3 / 4)
            log = language.text("[Earlier output truncated]\n", "[较早输出已截断]\n")
                + String(decoding: retained, as: UTF8.self)
        }
    }

    func clear() { log = "" }
}

final class ScriptManager: ObservableObject {
    @Published private(set) var projects: [ManagedProject] = []
    @Published private(set) var selectedProjectID: String?
    @Published private(set) var selectedTaskIDs: [String: String] = [:]
    @Published private(set) var activeCount: [String: Int] = [:]
    @Published var errorMessage: String?
    @Published var searchQuery = ""
    @Published var language: ScriptManagerLanguage = .initial

    private struct TaskKey: Hashable {
        let projectID: String
        let taskID: String
    }

    private static let manualProjectsKey = "manualProjectPaths"
    private let defaults: UserDefaults
    private let projectCatalog: CodexProjectCatalog
    private var codexFolders: [CodexProjectCatalog.Folder] = []
    private var manualFolders: [String]
    private var sessionFolders: [String] = []
    private var lastCatalogCheck: TimeInterval = -.infinity
    private let scanQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var runs: [TaskKey: TaskRun] = [:]
    private var pendingScans: [String: UUID] = [:]
    private var onShutdown: (() -> Void)?

    var selectedProject: ManagedProject? { projects.first { $0.id == selectedProjectID } }
    var hasActiveJobs: Bool { !activeCount.isEmpty }

    init(defaults: UserDefaults = .standard, projectCatalog: CodexProjectCatalog = CodexProjectCatalog()) {
        self.defaults = defaults
        self.projectCatalog = projectCatalog
        manualFolders = defaults.stringArray(forKey: Self.manualProjectsKey) ?? []
    }

    func synchronizeProjects(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastCatalogCheck >= 1 else { return }
        lastCatalogCheck = now
        codexFolders = projectCatalog.read()
        reconcileProjects()
    }

    func openProject(_ url: URL, persist: Bool = false) {
        let directory = url.standardizedFileURL.resolvingSymlinksInPath()
        guard directory.isFileURL, Self.isDirectory(directory) else {
            errorMessage = language.text("Project folder not found: \(url.path)", "找不到项目目录：\(url.path)")
            return
        }

        synchronizeProjects()
        let path = directory.path
        if projects.first(where: { $0.id == path })?.source != .codex {
            if persist {
                if !manualFolders.contains(path) {
                    manualFolders.append(path)
                    defaults.set(manualFolders, forKey: Self.manualProjectsKey)
                }
                sessionFolders.removeAll { $0 == path }
            } else if !manualFolders.contains(path), !sessionFolders.contains(path) {
                sessionFolders.append(path)
            }
        }
        reconcileProjects()
        selectProject(path)
        refresh(path)
    }

    private static func isDirectory(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func reconcileProjects() {
        let previous = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var next: [ManagedProject] = []
        var seen = Set<String>()
        var needsScan: [String] = []

        func add(path: String, name: String? = nil, source: ManagedProject.Source, pinned: Bool = false) {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { return }
            let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let id = directory.path
            guard seen.insert(id).inserted else { return }
            let old = previous[id]
            let available = Self.isDirectory(directory)
            var project = ManagedProject(directory: directory, displayName: name, source: source,
                                         isAvailable: available, isPinned: pinned, tasks: old?.tasks ?? [],
                                         isScanning: old?.isScanning ?? false,
                                         commandConfigError: old?.commandConfigError)
            if available {
                if old?.isAvailable != true { needsScan.append(id) }
            } else {
                pendingScans[id] = nil
                project.isScanning = false
                project.commandConfigError = nil
                project.tasks = project.tasks.filter { isRunning($0, in: id) }
            }
            next.append(project)
        }

        for folder in codexFolders { add(path: folder.path, name: folder.name, source: .codex, pinned: folder.pinned) }
        for path in manualFolders { add(path: path, source: .manual) }
        for path in sessionFolders { add(path: path, source: .session) }
        for project in projects where activeCount[project.id] != nil && seen.insert(project.id).inserted {
            next.append(ManagedProject(directory: project.directory, displayName: project.displayName, source: .session,
                                       isAvailable: project.isAvailable, isPinned: false,
                                       tasks: project.tasks, isScanning: project.isScanning,
                                       commandConfigError: project.commandConfigError))
        }

        let removed = Set(previous.keys).subtracting(seen)
        if !removed.isEmpty {
            for id in removed {
                pendingScans[id] = nil
                selectedTaskIDs[id] = nil
            }
            runs = runs.filter { !removed.contains($0.key.projectID) }
        }
        if next.map(\.id) != projects.map(\.id) || next.contains(where: {
            let old = previous[$0.id]
            return old?.name != $0.name || old?.source != $0.source || old?.isAvailable != $0.isAvailable
                || old?.isPinned != $0.isPinned || old?.tasks.count != $0.tasks.count
        }) {
            projects = next
        }
        if selectedProjectID == nil || !seen.contains(selectedProjectID ?? "") {
            selectProject(next.first(where: { $0.isAvailable })?.id ?? next.first?.id)
        }
        for id in needsScan { refresh(id) }
    }

    func selectProject(_ id: String) {
        selectProject(Optional(id))
    }

    private func selectProject(_ id: String?) {
        if selectedProjectID != id { searchQuery = "" }
        selectedProjectID = id
    }

    func selectTask(_ id: String, in project: ManagedProject) {
        selectedTaskIDs[project.id] = id
    }

    func refresh(_ projectID: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID && $0.isAvailable }),
              pendingScans[projectID] == nil else { return }
        let directory = projects[index].directory
        let scanID = UUID()
        pendingScans[projectID] = scanID
        projects[index].isScanning = true
        scanQueue.addOperation { [weak self] in
            let discovery = ScriptCatalog.discover(in: directory)
            DispatchQueue.main.async { self?.finishScan(discovery, projectID: projectID, scanID: scanID) }
        }
    }

    private func finishScan(_ discovery: ScriptCatalog.Discovery, projectID: String, scanID: UUID) {
        guard pendingScans[projectID] == scanID,
              let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        pendingScans.removeValue(forKey: projectID)
        let tasks = discovery.tasks
        let discoveredIDs = Set(tasks.map(\.id))
        let retained = projects[index].tasks.compactMap { task -> ScriptTask? in
            guard !discoveredIDs.contains(task.id), isRunning(task, in: projectID) else { return nil }
            var retained = task
            retained.isRetiredCommand = task.configuredCommand != nil
            return retained
        }
        let updated = tasks + retained
        var project = projects[index]
        project.tasks = updated
        project.isScanning = false
        project.commandConfigError = discovery.commandConfigError
        projects[index] = project
        if !updated.contains(where: { $0.id == selectedTaskIDs[projectID] }) {
            selectedTaskIDs[projectID] = updated.first?.id
        }
        let updatedIDs = Set(updated.map(\.id))
        runs = runs.filter { $0.key.projectID != projectID || updatedIDs.contains($0.key.taskID) }
    }

    func run(for task: ScriptTask, in project: ManagedProject) -> TaskRun {
        let key = TaskKey(projectID: project.id, taskID: task.id)
        if let run = runs[key] { return run }
        let run = TaskRun()
        runs[key] = run
        return run
    }

    func start(_ task: ScriptTask, in project: ManagedProject) {
        guard onShutdown == nil, project.isAvailable, !task.isRetiredCommand else { return }
        let run = run(for: task, in: project)
        guard !run.status.isActive else { return }
        selectTask(task.id, in: project)
        run.language = language
        run.clear()
        run.append("$ \(task.command)\n")
        do {
            run.process = try ScriptProcess.start(task: task, language: run.language, onOutput: { [weak run] text in
                run?.append(text)
            }, onExit: { [weak self, weak run] code in
                guard let self, let run else { return }
                let wasStopping = run.status == .stopping
                run.process = nil
                run.status = wasStopping ? .stopped : (code == 0 ? .succeeded : .failed(code))
                let outcome = wasStopping
                    ? run.language.text("Stopped with exit code \(code)", "已停止，退出码 \(code)")
                    : run.language.text("Exited with code \(code)", "已退出，退出码 \(code)")
                run.append("\n[\(outcome)]\n")
                self.removeRetiredCommand(task.id, in: project.id)
                self.changeActiveCount(for: project.id, by: -1)
            })
            run.status = .running
            changeActiveCount(for: project.id, by: 1)
        } catch {
            run.status = .failed(nil)
            run.append(run.language.text("[Launch failed] ", "[启动失败] ") + error.localizedDescription + "\n")
        }
    }

    private func removeRetiredCommand(_ taskID: String, in projectID: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }),
              let taskIndex = projects[index].tasks.firstIndex(where: { $0.id == taskID && $0.isRetiredCommand }) else {
            return
        }
        projects[index].tasks.remove(at: taskIndex)
        runs.removeValue(forKey: TaskKey(projectID: projectID, taskID: taskID))
        if selectedTaskIDs[projectID] == taskID { selectedTaskIDs[projectID] = projects[index].tasks.first?.id }
    }

    func stop(_ run: TaskRun) {
        guard run.status == .running, let process = run.process else { return }
        run.status = .stopping
        run.append(run.language.text("\n[Stopping]\n", "\n[正在停止]\n"))
        process.stop()
    }

    func stopAll(then callback: @escaping () -> Void) {
        guard hasActiveJobs, onShutdown == nil else { return }
        onShutdown = callback
        for run in runs.values { stop(run) }
    }

    func bridgeResponse(to request: ScriptManagerBridge.Request, pickPending: Bool) -> [String: Any] {
        synchronizeProjects(force: request.method == "refresh")
        let requestedProject = projects.first { $0.id == request.projectId }
        switch request.method {
        case "snapshot", "choose", "revealNative":
            break
        case "refresh":
            if let requestedProject {
                refresh(requestedProject.id)
            } else if request.projectId == nil {
                for project in projects { refresh(project.id) }
            } else {
                return Self.bridgeError(language.text("This project is not open.", "该项目尚未打开。"))
            }
        case "open":
            guard let project = requestedProject else {
                return Self.bridgeError(language.text("This project is not open.", "该项目尚未打开。"))
            }
            if let error = openDirectory(for: project, destination: request.destination) {
                return Self.bridgeError(error)
            }
        case "start", "stop":
            guard let project = requestedProject else {
                return Self.bridgeError(language.text("This project is not open.", "该项目尚未打开。"))
            }
            guard let task = project.tasks.first(where: { $0.id == request.taskId }) else {
                return Self.bridgeError(language.text("Script not found in this project. Rescan the project.",
                                                      "该项目中找不到脚本。请重新扫描。"))
            }
            if request.method == "start" {
                guard project.isAvailable else {
                    return Self.bridgeError(language.text("The project folder is unavailable.", "项目目录不可用。"))
                }
                start(task, in: project)
            } else {
                stop(run(for: task, in: project))
            }
        default:
            return Self.bridgeError(language.text("Unknown Script Manager operation.", "未知的脚本管理操作。"))
        }

        let project = requestedProject ?? selectedProject
        let taskID = request.taskId ?? project.flatMap { selectedTaskIDs[$0.id] }
        let task = project?.tasks.first { $0.id == taskID }
        let selectedLog = project.flatMap { project in
            task.flatMap { runs[TaskKey(projectID: project.id, taskID: $0.id)]?.log }
        } ?? ""
        let tasks = project.map(taskRows(in:)) ?? []
        let projectRows: [[String: Any]] = projects.map { item in
            var row: [String: Any] = [
                "id": item.id, "name": item.name, "path": item.directory.path,
                "activeCount": activeCount[item.id] ?? 0, "scanning": item.isScanning,
                "available": item.isAvailable, "source": item.source.rawValue, "pinned": item.isPinned,
                "tasks": item.id == project?.id ? tasks : taskRows(in: item),
            ]
            if let error = item.commandConfigError { row["commandConfigError"] = error.message(in: language) }
            return row
        }
        return ["ok": true, "data": [
            "schemaVersion": 2,
            "supportsCustomCommands": true,
            "projects": projectRows,
            "selectedProjectId": selectedProjectID as Any? ?? NSNull(),
            "projectId": project?.id as Any? ?? NSNull(),
            "tasks": tasks,
            "selectedTaskId": task?.id as Any? ?? NSNull(),
            "log": selectedLog,
            "pickPending": pickPending,
        ]]
    }

    private func taskRows(in project: ManagedProject) -> [[String: Any]] {
        project.tasks.map { task in
            let status = runs[TaskKey(projectID: project.id, taskID: task.id)]?.status ?? .idle
            var row: [String: Any] = [
                "id": task.id, "name": task.name, "detail": task.detail, "command": task.command,
                "packagePath": task.packagePath,
                "status": status.label(in: language), "statusKind": status.kind,
                "active": status.isActive, "stopping": status == .stopping,
            ]
            if let packageName = task.packageName { row["packageName"] = packageName }
            if case .failed(let code) = status { row["exitCode"] = code as Any? ?? NSNull() }
            return row
        }
    }

    private func isRunning(_ task: ScriptTask, in projectID: String) -> Bool {
        runs[TaskKey(projectID: projectID, taskID: task.id)]?.status.isActive == true
    }

    private func openDirectory(for project: ManagedProject, destination: String?) -> String? {
        guard project.isAvailable, Self.isDirectory(project.directory) else {
            return language.text("The project folder is unavailable.", "项目目录不可用。")
        }
        let workspace = NSWorkspace.shared
        switch destination {
        case "finder":
            if !workspace.open(project.directory) {
                return language.text("Could not open the project in Finder.", "无法在访达中打开项目。")
            }
        case "vscode":
            guard let application = workspace.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
                return language.text("Visual Studio Code is not installed.", "未安装 Visual Studio Code。")
            }
            workspace.open([project.directory], withApplicationAt: application,
                           configuration: NSWorkspace.OpenConfiguration())
        default:
            return language.text("Unsupported application.", "不支持该应用。")
        }
        return nil
    }

    private static func bridgeError(_ message: String) -> [String: Any] {
        ["ok": false, "error": message]
    }

    private func changeActiveCount(for projectID: String, by delta: Int) {
        let count = (activeCount[projectID] ?? 0) + delta
        activeCount[projectID] = count > 0 ? count : nil
        if count == 0 { reconcileProjects() }
        if !hasActiveJobs, let onShutdown {
            self.onShutdown = nil
            onShutdown()
        }
    }
}

import AppKit
import SwiftUI

struct ProjectRoot: Identifiable, Equatable {
    let directory: URL
    let isAvailable: Bool

    var id: String { directory.path }
    var name: String { directory.lastPathComponent.isEmpty ? id : directory.lastPathComponent }
}

struct ManagedProject: Identifiable {
    enum Source: String {
        case codex, manual, session
    }

    let directory: URL
    let roots: [ProjectRoot]
    let displayName: String?
    let source: Source
    let isPinned: Bool
    var tasks: [ScriptTask] = []
    var isScanning = false
    var discoveries: [String: ScriptCatalog.Discovery] = [:]

    var id: String { directory.path }
    var name: String { displayName ?? (directory.lastPathComponent.isEmpty ? id : directory.lastPathComponent) }
    var isAvailable: Bool { roots.contains(where: \.isAvailable) }

    var displayedRoots: [ProjectRoot] {
        var seen = Set(roots.map(\.id))
        return roots + tasks.compactMap { task in
            guard seen.insert(task.rootPath).inserted else { return nil }
            return ProjectRoot(directory: URL(fileURLWithPath: task.rootPath, isDirectory: true), isAvailable: false)
        }
    }
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
    @Published private(set) var savingCandidates: Set<CandidateKey> = []
    @Published private var collapsedRoots: [String: Set<String>] = [:]
    @Published var errorMessage: String?
    @Published var searchQuery = ""
    @Published var activeOnly = false
    @Published var language: ScriptManagerLanguage = .initial

    private struct TaskKey: Hashable {
        let projectID: String
        let taskID: String
    }

    struct CandidateKey: Hashable {
        let projectID: String
        let rootPath: String
        let candidateID: String
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
    private let saveQueue = DispatchQueue(label: "codex-script-manager.save", qos: .userInitiated)
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

        func add(_ paths: [String], name: String? = nil, source: ManagedProject.Source, pinned: Bool = false) {
            var rootPaths = Set<String>()
            let roots = paths.compactMap { path -> ProjectRoot? in
                guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
                let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
                guard rootPaths.insert(url.path).inserted else { return nil }
                return ProjectRoot(directory: url, isAvailable: Self.isDirectory(url))
            }
            guard let directory = roots.first?.directory else { return }
            let id = directory.path
            guard seen.insert(id).inserted else { return }
            let old = previous[id]
            let availableRoots = Set(roots.filter(\.isAvailable).map(\.id))
            let changed = old?.roots != roots
            var project = ManagedProject(directory: directory, roots: roots, displayName: name, source: source,
                                         isPinned: pinned, tasks: old?.tasks ?? [], isScanning: old?.isScanning ?? false,
                                         discoveries: old?.discoveries ?? [:])
            if changed {
                pendingScans[id] = nil
                project.isScanning = false
                project.discoveries = project.discoveries.filter { availableRoots.contains($0.key) }
                project.tasks = project.tasks.compactMap { task in
                    if availableRoots.contains(task.rootPath) { return task }
                    guard isRunning(task, in: id) else { return nil }
                    var task = task
                    task.isRetiredCommand = true
                    return task
                }
                if project.isAvailable { needsScan.append(id) }
            }
            next.append(project)
        }

        for folder in codexFolders { add(folder.rootPaths, name: folder.name, source: .codex, pinned: folder.pinned) }
        for path in manualFolders { add([path], source: .manual) }
        for path in sessionFolders {
            let attached = WorktreeProject.attachedPaths(for: path, in: codexFolders)
            add([path] + attached, source: .session)
        }
        for project in projects where activeCount[project.id] != nil && seen.insert(project.id).inserted {
            next.append(ManagedProject(directory: project.directory, roots: project.roots, displayName: project.displayName,
                                       source: .session, isPinned: false, tasks: project.tasks,
                                       isScanning: project.isScanning, discoveries: project.discoveries))
        }

        let removed = Set(previous.keys).subtracting(seen)
        if !removed.isEmpty {
            for id in removed {
                pendingScans[id] = nil
                selectedTaskIDs[id] = nil
                collapsedRoots[id] = nil
            }
            runs = runs.filter { !removed.contains($0.key.projectID) }
        }
        if next.map(\.id) != projects.map(\.id) || next.contains(where: {
            let old = previous[$0.id]
            return old?.name != $0.name || old?.source != $0.source || old?.roots != $0.roots
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
        if selectedProjectID != id {
            searchQuery = ""
            activeOnly = false
        }
        selectedProjectID = id
    }

    func isRootExpanded(_ rootPath: String, in projectID: String) -> Bool {
        !(collapsedRoots[projectID]?.contains(rootPath) ?? false)
    }

    func setRootExpanded(_ expanded: Bool, rootPath: String, in projectID: String) {
        if expanded {
            collapsedRoots[projectID]?.remove(rootPath)
        } else {
            collapsedRoots[projectID, default: []].insert(rootPath)
        }
    }

    func selectTask(_ id: String, in project: ManagedProject) {
        selectedTaskIDs[project.id] = id
    }

    func refresh(_ projectID: String, replacing: Bool = false) {
        guard let index = projects.firstIndex(where: { $0.id == projectID && $0.isAvailable }),
              replacing || pendingScans[projectID] == nil else { return }
        let roots = projects[index].roots.filter(\.isAvailable)
        let scanID = UUID()
        pendingScans[projectID] = scanID
        projects[index].isScanning = true
        scanQueue.addOperation { [weak self] in
            let discoveries = roots.map { ($0.id, ScriptCatalog.discover(in: $0.directory)) }
            DispatchQueue.main.async { self?.finishScan(discoveries, projectID: projectID, scanID: scanID) }
        }
    }

    private func finishScan(_ discoveries: [(String, ScriptCatalog.Discovery)], projectID: String, scanID: UUID) {
        guard pendingScans[projectID] == scanID,
              let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        pendingScans.removeValue(forKey: projectID)
        let tasks = discoveries.flatMap { $0.1.tasks }
        let discoveredIDs = Set(tasks.map(\.id))
        let retained = projects[index].tasks.compactMap { task -> ScriptTask? in
            guard !discoveredIDs.contains(task.id), isRunning(task, in: projectID) else { return nil }
            var retained = task
            retained.isRetiredCommand = true
            return retained
        }
        let updated = tasks + retained
        var project = projects[index]
        project.tasks = updated
        project.isScanning = false
        project.discoveries = Dictionary(uniqueKeysWithValues: discoveries)
        projects[index] = project
        if !updated.contains(where: { $0.id == selectedTaskIDs[projectID] }) {
            selectedTaskIDs[projectID] = updated.first?.id
        }
        let updatedIDs = Set(updated.map(\.id))
        runs = runs.filter { $0.key.projectID != projectID || updatedIDs.contains($0.key.taskID) }
    }

    func saveCandidate(_ key: CandidateKey, completion: @escaping (String?) -> Void) {
        guard let project = projects.first(where: { $0.id == key.projectID }),
              let root = project.roots.first(where: { $0.id == key.rootPath && $0.isAvailable }),
              project.discoveries[key.rootPath]?.candidates.contains(where: { $0.id == key.candidateID }) == true else {
            completion(language.text("The suggested command is no longer available. Rescan the project.",
                                     "建议的命令已不可用。请重新扫描项目。"))
            return
        }
        guard savingCandidates.insert(key).inserted else {
            completion(language.text("This command is already being saved.", "正在保存此命令。"))
            return
        }
        saveQueue.async { [weak self] in
            let result = ProjectCommandTools.save(key.candidateID, in: root.directory)
            DispatchQueue.main.async {
                guard let self else { return }
                self.savingCandidates.remove(key)
                switch result {
                case .success:
                    if let index = self.projects.firstIndex(where: { $0.id == key.projectID }) {
                        self.projects[index].discoveries[key.rootPath]?.candidates.removeAll { $0.id == key.candidateID }
                    }
                    self.refresh(key.projectID, replacing: true)
                    completion(nil)
                case .failure(let error):
                    completion(error.localized(in: self.language))
                }
            }
        }
    }

    func run(for task: ScriptTask, in project: ManagedProject) -> TaskRun {
        let key = TaskKey(projectID: project.id, taskID: task.id)
        if let run = runs[key] { return run }
        let run = TaskRun()
        runs[key] = run
        return run
    }

    func start(_ task: ScriptTask, in project: ManagedProject) {
        guard onShutdown == nil, !task.isRetiredCommand,
              project.roots.contains(where: { $0.id == task.rootPath && $0.isAvailable }) else { return }
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
        case "snapshot", "choose", "revealNative", "add_command":
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
                guard !task.isRetiredCommand,
                      project.roots.contains(where: { $0.id == task.rootPath && $0.isAvailable }) else {
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
            row["roots"] = item.displayedRoots.map { root -> [String: Any] in
                var fields: [String: Any] = ["path": root.id, "name": root.name, "available": root.isAvailable]
                if let error = item.discoveries[root.id]?.commandConfigError {
                    fields["commandConfigError"] = error.message(in: language)
                }
                if let error = item.discoveries[root.id]?.actionError { fields["actionError"] = error.localized(in: language) }
                return fields
            }
            row["candidates"] = item.roots.flatMap { root in
                (item.discoveries[root.id]?.candidates ?? []).map { $0.row(rootPath: root.id) }
            }
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
                "packagePath": task.packagePath, "rootPath": task.rootPath,
                "status": status.label(in: language), "statusKind": status.kind,
                "active": status.isActive, "stopping": status == .stopping,
            ]
            if let packageName = task.packageName { row["packageName"] = packageName }
            if case .failed(let code) = status { row["exitCode"] = code as Any? ?? NSNull() }
            return row
        }
    }

    func isRunning(_ task: ScriptTask, in projectID: String) -> Bool {
        runs[TaskKey(projectID: projectID, taskID: task.id)]?.status.isActive == true
    }

    private func openDirectory(for project: ManagedProject, destination: String?) -> String? {
        guard Self.isDirectory(project.directory) else {
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

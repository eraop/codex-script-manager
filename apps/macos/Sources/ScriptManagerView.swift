import AppKit
import SwiftUI

struct ScriptManagerView: View {
    @ObservedObject var manager: ScriptManager
    let chooseFolder: () -> Void

    private var language: ScriptManagerLanguage { manager.language }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 175, idealWidth: 212, maxWidth: 240)
            if let project = manager.selectedProject {
                ProjectView(manager: manager, project: project)
                    .id(project.id)
                    .frame(minWidth: 485, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(language.openProjectTitle)
                        .font(.title2.weight(.semibold))
                    Text(language.text("Choose a local project folder to see its scripts.", "选择本地项目目录，查看可运行的脚本。"))
                        .foregroundStyle(.secondary)
                    Button(language.text("Choose Folder…", "选择目录…"), action: chooseFolder)
                }
                .frame(minWidth: 485, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(language.text("Could Not Open Project", "无法打开项目"), isPresented: Binding(
            get: { manager.errorMessage != nil },
            set: { if !$0 { manager.errorMessage = nil } }
        )) {
            Button(language.text("OK", "好"), role: .cancel) { manager.errorMessage = nil }
        } message: {
            Text(manager.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(language.text("Projects", "项目")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: chooseFolder) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(language.openProjectTitle)
                    .accessibilityLabel(language.openProjectTitle)
            }
            .padding(.horizontal, 15)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(manager.projects) { project in
                        Button { manager.selectProject(project.id) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(project.name).lineLimit(1)
                                Spacer(minLength: 3)
                                if let count = manager.activeCount[project.id] {
                                    ActiveBadge(count: count, language: language)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .background {
                                if manager.selectedProjectID == project.id {
                                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.14))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(project.directory.path)
                        .accessibilityAddTraits(manager.selectedProjectID == project.id ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 7)
            }
        }
        .padding(.top, 15)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ActiveBadge: View {
    let count: Int
    let language: ScriptManagerLanguage

    private var runningTasks: String {
        let english = count == 1 ? "1 running task" : "\(count) running tasks"
        return language.text(english, "\(count) 个任务正在运行")
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.green).frame(width: 5, height: 5)
            Text(language.text("Active", "运行中")).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.green.opacity(0.14), in: Capsule())
        .help(runningTasks)
        .accessibilityLabel(runningTasks)
    }
}

private struct ProjectView: View {
    @ObservedObject var manager: ScriptManager
    let project: ManagedProject
    @State private var showExternalProcesses = false

    private var language: ScriptManagerLanguage { manager.language }

    private var selectedTask: ScriptTask? {
        project.tasks.first { $0.id == manager.selectedTaskIDs[project.id] }
    }

    private var query: String { manager.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func matches(_ values: String...) -> Bool {
        query.isEmpty || values.contains { $0.localizedStandardContains(query) }
    }

    private func visibleTasks(in root: ProjectRoot) -> [ScriptTask] {
        project.tasks.filter { task in
            task.rootPath == root.id && (!manager.activeOnly || manager.isRunning(task, in: project.id))
                && matches(root.id, root.name, task.name, task.command, task.detail)
        }
    }

    private func visibleCandidates(in root: ProjectRoot) -> [ProjectCommandTools.Candidate] {
        guard !manager.activeOnly else { return [] }
        return (project.discoveries[root.id]?.candidates ?? []).filter {
            matches(root.id, root.name, $0.name, $0.command, $0.cwd, $0.detail)
        }
    }

    private var visibleRoots: [ProjectRoot] {
        project.displayedRoots.filter {
            (!manager.activeOnly && query.isEmpty) || !visibleTasks(in: $0).isEmpty || !visibleCandidates(in: $0).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VSplitView {
                tasks.frame(minHeight: 155, idealHeight: 300, maxHeight: .infinity)
                if let task = selectedTask {
                    let run = manager.run(for: task, in: project)
                    TaskLogView(task: task, language: language, run: run) { manager.stop(run) }
                        .frame(minHeight: 150, idealHeight: 215, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $showExternalProcesses) {
            ExternalProcessView(manager: manager, projectID: project.id)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.title3.weight(.semibold)).lineLimit(1)
                Text(project.directory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(project.directory.path)
            }
            Spacer(minLength: 8)
            if project.isScanning {
                ProgressView().controlSize(.small).accessibilityLabel(language.text("Scanning scripts", "正在扫描脚本"))
            }
            Button {
                showExternalProcesses = true
            } label: {
                Label(language.text("External Processes", "外部运行"), systemImage: "list.bullet.rectangle")
            }
            .disabled(!project.isAvailable)
            Button {
                manager.synchronizeProjects(force: true)
                manager.refresh(project.id)
            } label: {
                Label(language.text("Rescan", "重新扫描"), systemImage: "arrow.clockwise")
            }
            .disabled(project.isScanning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var tasks: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(language.text("Scripts", "脚本")).font(.subheadline.weight(.semibold))
                Text(project.tasks.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(language.text("Active", "运行中"), isOn: $manager.activeOnly)
                    .toggleStyle(.button)
                    .controlSize(.small)
                TextField(language.text("Filter scripts", "筛选脚本"), text: $manager.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)

            if visibleRoots.isEmpty {
                emptyTasks
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(visibleRoots) { root in
                            if project.displayedRoots.count > 1 {
                                DisclosureGroup(isExpanded: expandedBinding(for: root)) {
                                    rootContents(root)
                                } label: {
                                    HStack(spacing: 7) {
                                        Text(root.name).font(.callout.weight(.semibold))
                                        Text(root.id).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    .help(root.id)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            } else {
                                rootContents(root)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                .accessibilityLabel(language.text("Project scripts", "项目脚本"))
            }
        }
    }

    private func expandedBinding(for root: ProjectRoot) -> Binding<Bool> {
        Binding(
            get: { manager.isRootExpanded(root.id, in: project.id) },
            set: { manager.setRootExpanded($0, rootPath: root.id, in: project.id) }
        )
    }

    private func rootContents(_ root: ProjectRoot) -> some View {
        let discovery = project.discoveries[root.id]
        let rows = visibleTasks(in: root)
        let candidates = visibleCandidates(in: root)
        return VStack(alignment: .leading, spacing: 3) {
            if !root.isAvailable {
                notice(language.text("Project folder unavailable", "项目目录不可用"), icon: "exclamationmark.triangle")
            }
            if let error = discovery?.commandConfigError {
                notice(error.message(in: language), icon: "exclamationmark.triangle")
            }
            if let error = discovery?.actionError {
                notice(error.localized(in: language), icon: "exclamationmark.triangle")
            }
            ForEach(rows) { task in
                let run = manager.run(for: task, in: project)
                TaskRow(task: task, language: language, run: run, selected: task.id == selectedTask?.id) {
                    manager.selectTask(task.id, in: project)
                } start: {
                    manager.start(task, in: project)
                } stop: {
                    manager.selectTask(task.id, in: project)
                    manager.stop(run)
                }
            }
            if !candidates.isEmpty {
                Text(language.text("Suggested commands", "建议命令"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 5)
            }
            ForEach(candidates) { candidate in
                candidateRow(candidate, in: root)
            }
            if root.isAvailable, rows.isEmpty, candidates.isEmpty {
                notice(project.isScanning ? language.text("Scanning scripts…", "正在扫描脚本…")
                    : language.text("No runnable scripts found", "未发现可运行脚本"))
            }
        }
    }

    private func notice(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func candidateRow(_ candidate: ProjectCommandTools.Candidate, in root: ProjectRoot) -> some View {
        let key = ScriptManager.CandidateKey(projectID: project.id, rootPath: root.id, candidateID: candidate.id)
        let workingDirectory = candidate.cwd.isEmpty ? root.id : root.directory.appendingPathComponent(candidate.cwd).path
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name).font(.callout.weight(.semibold))
                Text(candidate.command).font(.system(.caption, design: .monospaced)).lineLimit(1)
                Text(workingDirectory).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .help("\(candidate.command)\n\(workingDirectory)")
            Spacer(minLength: 5)
            Button {
                manager.saveCandidate(key) { error in
                    if let error { manager.errorMessage = error }
                }
            } label: {
                Label(language.text("Add", "添加"), systemImage: "plus")
            }
            .controlSize(.small)
            .disabled(manager.savingCandidates.contains(key))
            .accessibilityLabel(language.text("Add \(candidate.name)", "添加 \(candidate.name)"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var emptyTasks: some View {
        Text(language.text("No matching scripts", "没有匹配的脚本"))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TaskRow: View {
    let task: ScriptTask
    let language: ScriptManagerLanguage
    @ObservedObject var run: TaskRun
    let selected: Bool
    let select: () -> Void
    let start: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 9) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(task.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(task.command)
            .accessibilityAddTraits(selected ? .isSelected : [])

            Text(run.status.label(in: language))
                .font(.caption.monospacedDigit())
                .foregroundStyle(run.status.color)
                .fixedSize()

            if run.status.isActive {
                Button(action: stop) { Label(language.text("Stop", "停止"), systemImage: "stop.fill") }
                    .disabled(run.status == .stopping)
                    .accessibilityLabel(language.text("Stop \(task.name)", "停止 \(task.name)"))
            } else {
                Button(action: start) { Label(language.text("Start", "启动"), systemImage: "play.fill") }
                    .accessibilityLabel(language.text("Start \(task.name)", "启动 \(task.name)"))
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .background {
            if selected { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)) }
        }
    }
}

private struct TaskLogView: View {
    let task: ScriptTask
    let language: ScriptManagerLanguage
    @ObservedObject var run: TaskRun
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text(language.text("Logs", "日志")).font(.subheadline.weight(.semibold))
                Text(task.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(task.command)
                Spacer(minLength: 5)
                if run.status.isActive {
                    Button(action: stop) { Label(language.text("Stop", "停止"), systemImage: "stop.fill") }
                        .controlSize(.small)
                        .disabled(run.status == .stopping)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.log, forType: .string)
                } label: {
                    Label(language.text("Copy Logs", "复制日志"), systemImage: "document.on.document")
                }
                .controlSize(.small)
                .disabled(run.log.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            Divider()
            if run.log.isEmpty {
                Text(language.text("Output appears here once you start the script.", "启动脚本后，输出会显示在这里。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                LogTextView(log: run.log, language: language).id(task.id)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct LogTextView: NSViewRepresentable {
    let log: String
    let language: ScriptManagerLanguage
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.font = Self.font
            text.textContainerInset = NSSize(width: 13, height: 10)
        }
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
        text.setAccessibilityLabel(language.text("Script output", "脚本输出"))
        guard text.string != log else { return }
        let oldLog = text.string
        let wasAtEnd = oldLog.isEmpty || scroll.documentVisibleRect.maxY >= text.bounds.maxY - 10
        let selection = text.selectedRange()
        let updatedLog = log as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.textColor]
        if updatedLog.hasPrefix(oldLog) {
            let appended = NSAttributedString(string: updatedLog.substring(from: storage.length), attributes: attributes)
            storage.replaceCharacters(in: NSRange(location: storage.length, length: 0),
                                      with: appended)
            text.setSelectedRange(selection)
        } else {
            storage.setAttributedString(NSAttributedString(string: log, attributes: attributes))
        }
        if wasAtEnd, selection.length == 0 {
            text.scrollRangeToVisible(NSRange(location: updatedLog.length, length: 0))
            if oldLog.isEmpty {
                DispatchQueue.main.async { [weak text] in text?.scrollToEndOfDocument(nil) }
            }
        }
    }
}

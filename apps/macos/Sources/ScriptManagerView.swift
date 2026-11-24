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
    private var language: ScriptManagerLanguage { manager.language }
    private var query: String { manager.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var selectedTask: ScriptTask? {
        project.tasks.first { $0.id == manager.selectedTaskIDs[project.id] }
    }

    private var matchingTasks: [ScriptTask] {
        let query = self.query
        if query.isEmpty { return project.tasks }
        return project.tasks.filter {
            $0.name.localizedStandardContains(query) || $0.command.localizedStandardContains(query)
                || $0.detail.localizedStandardContains(query) || usageEvidence(for: $0).localizedStandardContains(query)
        }
    }

    private func usageEvidence(for task: ScriptTask) -> String {
        task.usage.evidence.map { evidence in
            let source = evidence.source ?? ""
            switch evidence.kind {
            case .documentation:
                return language.text("Documented in \(source)", "\(source) 中有运行说明")
            case .workflow:
                return language.text("Used in \(source)", "\(source) 中的自动化流程引用")
            case .script:
                return language.text("Called by \(source)", "\(source) 脚本调用")
            case .specialized:
                return language.text("Name suggests a specialized task", "名称表明可能用于特定任务")
            case .noEvidence:
                return language.text("No references found", "未找到引用")
            }
        }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = project.commandConfigError {
                Label(error.message(in: language), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                Divider()
            }
            VSplitView {
                tasks.frame(minHeight: 155, idealHeight: 300, maxHeight: .infinity)
                if let task = selectedTask {
                    TaskLogView(task: task, language: language, run: manager.run(for: task, in: project))
                        .frame(minHeight: 150, idealHeight: 215, maxHeight: .infinity)
                }
            }
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
        let matching = matchingTasks
        let pinned = matching.filter { manager.isScriptPinned($0, in: project.id) }
        let groups = Dictionary(grouping: matching.filter { !manager.isScriptPinned($0, in: project.id) }) {
            $0.usage.category
        }

        return VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(language.text("Scripts", "脚本")).font(.subheadline.weight(.semibold))
                Text(project.tasks.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(language.text("Filter scripts", "筛选脚本"), text: $manager.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)

            if matching.isEmpty {
                emptyTasks
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        taskSection(pinned, title: language.text("Pinned scripts", "置顶脚本"))
                        taskSection(groups[.common] ?? [], title: language.text("Common scripts", "常用脚本"))
                        taskSection(groups[.automation] ?? [],
                                    title: language.text("Automation & specialized", "自动化与专用"))
                        unclassifiedSection(groups[.unclassified] ?? [])
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                .accessibilityLabel(language.text("Project scripts", "项目脚本"))
            }
        }
    }

    @ViewBuilder
    private func taskSection(_ tasks: [ScriptTask], title: String) -> some View {
        if !tasks.isEmpty {
            sectionHeading(title, count: tasks.count)
                .padding(.horizontal, 8)
                .padding(.top, 5)
            taskRows(tasks)
        }
    }

    @ViewBuilder
    private func unclassifiedSection(_ tasks: [ScriptTask]) -> some View {
        if !tasks.isEmpty {
            let title = language.text("Needs review", "待确认")
            if query.isEmpty {
                let running = tasks.filter { manager.isRunning($0, in: project.id) }
                let inactive = tasks.filter { !manager.isRunning($0, in: project.id) }
                if inactive.isEmpty {
                    taskSection(running, title: title)
                } else {
                    DisclosureGroup {
                        taskRows(inactive)
                    } label: {
                        sectionHeading(title, count: tasks.count)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 5)
                    taskRows(running)
                }
            } else {
                taskSection(tasks, title: title)
            }
        }
    }

    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(count.formatted())
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func taskRows(_ tasks: [ScriptTask]) -> some View {
        ForEach(tasks) { task in
            let run = manager.run(for: task, in: project)
            let pinned = manager.isScriptPinned(task, in: project.id)
            TaskRow(task: task, language: language, run: run, selected: task.id == selectedTask?.id,
                    pinned: pinned, evidence: usageEvidence(for: task)) {
                manager.selectTask(task.id, in: project)
            } start: {
                manager.start(task, in: project)
            } stop: {
                manager.selectTask(task.id, in: project)
                manager.stop(run)
            } togglePin: {
                manager.setScriptPinned(!pinned, for: task, in: project.id)
            }
        }
    }

    private var emptyTasks: some View {
        VStack(spacing: 7) {
            if !project.isAvailable {
                Text(language.text("Project folder unavailable", "项目目录不可用"))
            } else if project.isScanning && project.tasks.isEmpty {
                Text(language.text("Scanning scripts…", "正在扫描脚本…"))
            } else if project.tasks.isEmpty {
                Text(language.text("No runnable scripts found", "未发现可运行脚本"))
                Text(language.text(
                    "Add a command in .codex/script-manager.json or check the project’s Node.js or Spring Boot files.",
                    "在 .codex/script-manager.json 中添加命令，或检查项目的 Node.js 或 Spring Boot 文件。"
                ))
                    .font(.caption)
            } else {
                Text(language.text("No matching scripts", "没有匹配的脚本"))
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TaskRow: View {
    let task: ScriptTask
    let language: ScriptManagerLanguage
    @ObservedObject var run: TaskRun
    let selected: Bool
    let pinned: Bool
    let evidence: String
    let select: () -> Void
    let start: () -> Void
    let stop: () -> Void
    let togglePin: () -> Void

    private var pinLabel: String {
        pinned ? language.text("Unpin \(task.name)", "取消置顶 \(task.name)")
               : language.text("Pin \(task.name)", "置顶 \(task.name)")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 9) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(task.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(evidence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(task.command + "\n" + evidence)
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button(action: togglePin) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(pinLabel)
            .accessibilityLabel(pinLabel)

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

private struct LogTextView: NSViewRepresentable {
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

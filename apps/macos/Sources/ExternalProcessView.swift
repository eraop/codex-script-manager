import SwiftUI

@MainActor
struct ExternalProcessView: View {
    @ObservedObject var manager: ScriptManager
    let projectID: String

    @Environment(\.dismiss) private var dismiss
    @State private var items: [ExternalProcessService.Item] = []
    @State private var selectedID: String?
    @State private var selectedStreamID: String?
    @State private var log: LogOutput?
    @State private var loading = true
    @State private var listError: String?
    @State private var stopError: String?
    @State private var confirmingStop = false
    @State private var stopTarget: ExternalProcessService.Item?
    @State private var stopPending = false
    @State private var stopRequestedID: String?

    private struct LogSelection: Equatable {
        let processID: String
        let stream: String
    }

    private struct LogOutput {
        let selection: LogSelection
        let text: String
        var error = false
    }

    private var language: ScriptManagerLanguage { manager.language }
    private var selected: ExternalProcessService.Item? { items.first { $0.id == selectedID } }
    private var stream: ExternalProcessLogs.Source? {
        selected?.streams.first { $0.id == selectedStreamID } ?? selected?.streams.first
    }

    private var logSelection: LogSelection? {
        guard let selected, let stream else { return nil }
        return LogSelection(processID: selected.id, stream: stream.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.text("External Processes", "外部运行")).font(.headline)
                Spacer()
                Button(language.text("Done", "完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            if items.isEmpty {
                if loading {
                    ProgressView().controlSize(.small).padding(14)
                } else {
                    Text(listError ?? language.text("No external processes found in this project.", "此项目未发现外部运行的进程。"))
                        .foregroundStyle(listError == nil ? Color.secondary : Color.red)
                        .padding(14)
                }
                Spacer(minLength: 0)
            } else {
                processList
                Divider()
                if let selected {
                    processDetails(selected)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 430)
        .task {
            while !Task.isCancelled {
                await refreshProcesses()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: logSelection) {
            if let logSelection { await followLog(logSelection) }
        }
        .alert(language.text("Stop External Process?", "停止外部进程？"),
               isPresented: $confirmingStop, presenting: stopTarget) { item in
            Button(language.text("Stop", "停止"), role: .destructive) {
                Task { await stop(item) }
            }
            Button(language.text("Cancel", "取消"), role: .cancel) {}
        } message: { item in
            Text("\(item.process.name) · PID \(item.process.pid)\n\(item.process.directory)")
        }
        .onChange(of: selectedID) { _ in
            selectedStreamID = nil
            stopError = nil
        }
    }

    private var processList: some View {
        List(items, selection: $selectedID) { item in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.process.name).fontWeight(.medium)
                    Text("PID \(item.process.pid)").foregroundStyle(.secondary)
                }
                Text(item.process.directory).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .tag(item.id)
            .help(item.process.directory)
        }
        .frame(height: 145)
    }

    private func processDetails(_ item: ExternalProcessService.Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.text("Logs", "日志")).fontWeight(.semibold)
                if let stream {
                    Picker(language.text("Log File", "日志文件"), selection: Binding(
                        get: { stream.id }, set: { selectedStreamID = $0 }
                    )) {
                        ForEach(item.streams, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden()
                }
                Spacer()
                Button(role: .destructive) {
                    stopTarget = item
                    confirmingStop = true
                } label: {
                    Label(language.text("Stop", "停止"), systemImage: "stop.fill")
                }
                .disabled(!item.process.canStop || stopPending)
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if let stopError {
                Text(stopError).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8)
            } else if stopRequestedID == item.id {
                Text(language.text("Stop requested.", "已发送停止请求。"))
                    .foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8)
            }
            Divider()
            if let log, log.selection == logSelection, !log.error && !log.text.isEmpty {
                LogTextView(log: log.text, language: language).id(log.selection.stream)
            } else {
                Text(logStatus)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var logStatus: String {
        guard let logSelection else {
            return language.text("No readable log file. Terminal output is available in the original terminal.",
                                 "未找到可读取的日志文件。终端输出可在原终端查看。")
        }
        guard let log, log.selection == logSelection else { return language.text("Reading log…", "正在读取日志…") }
        return log.error ? log.text : language.text("The log is empty.", "日志为空。")
    }

    private func inspect<Value>(_ operation: @escaping (ExternalProcesses.Scope) throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            manager.inspectExternalProcesses(in: projectID, operation: operation) { continuation.resume(with: $0) }
        }
    }

    private func refreshProcesses() async {
        do {
            let next = try await inspect(ExternalProcessService.list)
            guard !Task.isCancelled else { return }
            items = next
            if selected == nil { selectedID = next.first?.id }
            listError = nil
        } catch {
            guard !Task.isCancelled else { return }
            items = []
            selectedID = nil
            listError = ExternalProcessService.message(error, in: language)
        }
        loading = false
    }

    private func followLog(_ selection: LogSelection) async {
        while !Task.isCancelled {
            do {
                let output = try await inspect { try ExternalProcessService.log(selection.processID, stream: selection.stream, in: $0) }
                guard !Task.isCancelled else { return }
                log = LogOutput(selection: selection, text: output)
            } catch {
                guard !Task.isCancelled else { return }
                log = LogOutput(selection: selection, text: ExternalProcessService.message(error, in: language), error: true)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func stop(_ item: ExternalProcessService.Item) async {
        guard !stopPending else { return }
        stopPending = true
        stopError = nil
        defer { stopPending = false }
        do {
            try await inspect { try ExternalProcesses.stop(item.id, in: $0) }
            stopRequestedID = item.id
        } catch {
            if selectedID == item.id { stopError = ExternalProcessService.message(error, in: language) }
        }
    }
}

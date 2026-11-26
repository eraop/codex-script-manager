import Foundation

enum ExternalProcessService {
    struct Item: Identifiable {
        let process: ExternalProcesses.Record
        let streams: [ExternalProcessLogs.Source]

        var id: String { process.id }

        var row: [String: Any] {
            ["id": id, "pid": process.pid, "name": process.name, "directory": process.directory,
             "canStop": process.canStop, "streams": streams.map { ["id": $0.id, "label": $0.label] }]
        }
    }

    enum Failure: Error {
        case projectUnavailable
        case processUnavailable

        func message(in language: ScriptManagerLanguage) -> String {
            switch self {
            case .projectUnavailable:
                return language.text("This project folder is unavailable.", "该项目目录不可用。")
            case .processUnavailable:
                return language.text("This process is no longer running in this project.", "该进程已不在此项目中运行。")
            }
        }
    }

    enum Operation {
        case list
        case log(processID: String, stream: String)
        case stop(processID: String)

        init?(request: ScriptManagerBridge.Request) {
            switch request.method {
            case "external_processes": self = .list
            case "external_log": self = .log(processID: request.processId ?? "", stream: request.stream ?? "")
            case "stop_external": self = .stop(processID: request.processId ?? "")
            default: return nil
            }
        }

        func perform(in scope: ExternalProcesses.Scope) throws -> [String: Any] {
            switch self {
            case .list: return ["schemaVersion": 2, "processes": ExternalProcessService.list(in: scope).map(\.row)]
            case .log(let processID, let stream):
                return ["schemaVersion": 2, "log": try ExternalProcessService.log(processID, stream: stream, in: scope)]
            case .stop(let processID):
                try ExternalProcesses.stop(processID, in: scope)
                return ["schemaVersion": 2, "stopping": true]
            }
        }
    }

    static func list(in scope: ExternalProcesses.Scope) -> [Item] {
        ExternalProcesses.scan(in: scope).map { process in
            Item(process: process, streams: ExternalProcessLogs.sources(for: process.pid))
        }
    }

    static func log(_ processID: String, stream: String, in scope: ExternalProcesses.Scope) throws -> String {
        guard let process = ExternalProcesses.resolve(processID, in: scope) else { throw Failure.processUnavailable }
        let output = try ExternalProcessLogs.read(for: process.pid, sourceID: stream)
        guard ExternalProcesses.resolve(processID, in: scope) != nil else { throw Failure.processUnavailable }
        return output
    }

    static func message(_ error: Error, in language: ScriptManagerLanguage) -> String {
        switch error {
        case let error as Failure: return error.message(in: language)
        case let error as ExternalProcesses.StopError: return error.message(in: language)
        case let error as ExternalProcessLogs.Failure: return error.description(in: language)
        default: return error.localizedDescription
        }
    }

    static func errorResponse(_ error: Error, in language: ScriptManagerLanguage) -> [String: Any] {
        ["ok": false, "error": message(error, in: language)]
    }
}

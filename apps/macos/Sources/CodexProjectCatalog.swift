import Foundation
import SQLite3

final class CodexProjectCatalog {
    struct Folder {
        let path: String
        let name: String
        let pinned: Bool
    }

    private struct Project: Decodable {
        let name: String
        var rootPaths: [String]
    }

    private typealias Entry = (id: String, project: Project)

    private struct GlobalState: Decodable {
        let projects: [String: Project]?
        let order: [String]
        let pinned: [String]
        let migratedIDs: [String: [String: String]]

        enum CodingKeys: String, CodingKey {
            case projects = "local-projects"
            case order = "project-order"
            case pinned = "pinned-project-ids"
            case migratedIDs = "app-server-project-id-by-legacy-project-id-by-host"
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            projects = try? fields.decode([String: Project].self, forKey: .projects)
            order = (try? fields.decode([String].self, forKey: .order)) ?? []
            pinned = (try? fields.decode([String].self, forKey: .pinned)) ?? []
            migratedIDs = (try? fields.decode([String: [String: String]].self, forKey: .migratedIDs)) ?? [:]
        }
    }

    private struct FileRevision: Equatable {
        let modified: Date?
        let inode: UInt64?
        let size: UInt64?

        init(_ attributes: [FileAttributeKey: Any]) {
            modified = attributes[.modificationDate] as? Date
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            size = (attributes[.size] as? NSNumber)?.uint64Value
        }
    }

    private enum DatabaseRead {
        case projects([Entry])
        case unsupported
        case retry
    }

    static var codexHome: URL {
        let customHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
        return customHome ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private let home: URL
    private var entries: [Entry] = []
    private var globalState: GlobalState?
    private var globalStateRevision: FileRevision?

    init(home: URL = CodexProjectCatalog.codexHome) {
        self.home = home
    }

    func read() -> [Folder] {
        updateGlobalState()
        switch readDatabase() {
        case .projects(let rows):
            entries = rows
        case .unsupported:
            if let legacy = legacyEntries() { entries = legacy }
        case .retry:
            break
        }
        let local = entries.compactMap { entry -> (id: String, path: String, name: String)? in
            let project = entry.project
            guard let path = project.rootPaths.first, path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
            if project.rootPaths.count == 1,
                URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent == ".chatgpt-projects" {
                return nil
            }
            return (entry.id, path, project.name)
        }
        let byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let migrated = globalState?.migratedIDs["local:\(home.path)"] ?? [:]
        var used = Set<String>()
        let pinned = (globalState?.pinned ?? []).compactMap { id -> Folder? in
            guard let project = byID[id] ?? migrated[id].flatMap({ byID[$0] }),
                  used.insert(project.id).inserted else { return nil }
            return Folder(path: project.path, name: project.name, pinned: true)
        }
        return pinned + local.compactMap { project in
            used.contains(project.id) ? nil : Folder(path: project.path, name: project.name, pinned: false)
        }
    }

    private func readDatabase() -> DatabaseRead {
        let url = home.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { return .unsupported }
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { if let database { sqlite3_close(database) } }
        guard openStatus == SQLITE_OK, let database else { return .retry }
        sqlite3_busy_timeout(database, 50)
        var statement: OpaquePointer?
        let query = """
            SELECT p.id, p.name, r.path
            FROM projects AS p JOIN project_roots AS r ON r.project_id = p.id
            ORDER BY p.position, p.id, r.position
            """
        let prepareStatus = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        defer { if let statement { sqlite3_finalize(statement) } }
        if prepareStatus == SQLITE_ERROR { return .unsupported }
        guard prepareStatus == SQLITE_OK, let statement else { return .retry }

        var projects: [Entry] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let id = text(in: statement, at: 0), let name = text(in: statement, at: 1),
               let path = text(in: statement, at: 2) {
                if id == projects.last?.id {
                    projects[projects.count - 1].project.rootPaths.append(path)
                } else {
                    projects.append((id, Project(name: name, rootPaths: [path])))
                }
            }
            status = sqlite3_step(statement)
        }
        return status == SQLITE_DONE ? .projects(projects) : .retry
    }

    private func text(in statement: OpaquePointer, at index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
    }

    private func updateGlobalState() {
        let url = home.appendingPathComponent(".codex-global-state.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            if !FileManager.default.fileExists(atPath: url.path) {
                globalState = nil
                globalStateRevision = nil
            }
            return
        }
        let revision = FileRevision(attributes)
        guard revision != globalStateRevision,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(GlobalState.self, from: data) else { return }
        globalState = state
        globalStateRevision = revision
    }

    private func legacyEntries() -> [Entry]? {
        guard let state = globalState, let projects = state.projects else { return nil }
        var seen = Set<String>()
        let ids = state.order + projects.keys.sorted()
        return ids.compactMap { id in
            guard seen.insert(id).inserted, let project = projects[id] else { return nil }
            return (id, project)
        }
    }
}

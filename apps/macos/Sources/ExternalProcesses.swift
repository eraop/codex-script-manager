import Darwin
import Foundation

enum ExternalProcesses {
    struct Scope {
        let roots: [String]
        let excludedRoots: [String]
        let managedGroups: Set<pid_t>
    }

    struct Record: Identifiable {
        let id: String
        let pid: pid_t
        let name: String
        let directory: String
        let canStop: Bool
    }

    enum StopError: Error {
        case unavailable
        case unsafe
        case signalFailed(Int32)

        func message(in language: ScriptManagerLanguage) -> String {
            switch self {
            case .unavailable:
                return language.text("The external process is no longer running in this project.",
                                     "此外部进程已不在此项目中运行。")
            case .unsafe:
                return language.text("Script Manager could not verify that this process can be stopped.",
                                     "脚本管理无法确认能否停止此进程。")
            case .signalFailed(let code):
                let reason = strerror(code).map { String(cString: $0) } ?? "errno \(code)"
                return language.text("Could not stop the external process: \(reason)",
                                     "无法停止外部进程（\(reason)）。")
            }
        }
    }

    private struct ResolvedScope {
        let roots: [String]
        let excludedRoots: [String]
        let managedGroups: Set<pid_t>

        init(_ scope: Scope) {
            roots = scope.roots.compactMap(ExternalProcesses.canonicalPath)
            excludedRoots = scope.excludedRoots.compactMap(ExternalProcesses.canonicalPath)
            managedGroups = scope.managedGroups
        }

        func contains(_ directory: String) -> Bool {
            guard let root = roots.filter({ Self.contains(directory, in: $0) })
                .max(by: { $0.utf8.count < $1.utf8.count }) else {
                return false
            }
            return !excludedRoots.contains { $0.utf8.count >= root.utf8.count && Self.contains(directory, in: $0) }
        }

        private static func contains(_ directory: String, in root: String) -> Bool {
            directory.utf8.elementsEqual(root.utf8) || directory.utf8.starts(with: (root == "/" ? root : root + "/").utf8)
        }
    }

    private static let shellsAndWrappers: Set<String> = [
        "bash", "csh", "dash", "doas", "env", "fish", "ksh", "login", "nu", "screen", "sh", "ssh", "sudo", "tcsh",
        "tmux", "zsh",
    ]
    private static let appExecutables: Set<String> = [
        "chatgpt", "chrome_crashpad_handler", "code", "code-insiders", "codex", "codex-app-server",
        "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin", "codexscriptmanager", "cursor", "electron", "idea",
        "pycharm", "rider", "webstorm", "windsurf", "zed",
    ]

    static func scan(in scope: Scope) -> [Record] {
        let scope = ResolvedScope(scope)
        guard !scope.roots.isEmpty else { return [] }
        let uid = geteuid()
        let size = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        let capacity = Int(size) / MemoryLayout<pid_t>.stride
        guard capacity > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: capacity)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_UID_ONLY), uid, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride)
            .compactMap { record(for: $0, uid: uid, in: scope) }
            .sorted { $0.pid < $1.pid }
    }

    static func resolve(_ id: String, in scope: Scope) -> Record? {
        let fields = id.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3, let pid = pid_t(fields[0]),
              let record = record(for: pid, uid: geteuid(), in: ResolvedScope(scope)), record.id == id else { return nil }
        return record
    }

    static func stop(_ id: String, in scope: Scope) throws {
        guard let record = resolve(id, in: scope) else { throw StopError.unavailable }
        guard record.canStop else { throw StopError.unsafe }
        if kill(record.pid, SIGTERM) != 0 {
            let code = errno
            if code == ESRCH { throw StopError.unavailable }
            throw StopError.signalFailed(code)
        }
    }

    private static func record(for pid: pid_t, uid: uid_t, in scope: ResolvedScope) -> Record? {
        guard pid > 1, pid != getpid(), !scope.roots.isEmpty,
              var info = processInfo(for: pid, uid: uid), !scope.managedGroups.contains(pid_t(bitPattern: info.pbi_pgid)),
              let directory = currentDirectory(for: pid), scope.contains(directory) else { return nil }

        let executable = executablePath(for: pid)
        let executableName = executable.map { URL(fileURLWithPath: $0).lastPathComponent }
        let processName = string(from: &info.pbi_comm)
        let name = executableName ?? processName ?? ""
        guard !name.isEmpty, !shellsAndWrappers.contains(name.lowercased()),
              !isAppExecutable(named: name, at: executable) else { return nil }

        let parent = pid_t(bitPattern: info.pbi_ppid)
        let parentApp = parent > 1 && processInfo(for: parent, uid: uid) != nil &&
            executablePath(for: parent).map { isAppExecutable(named: URL(fileURLWithPath: $0).lastPathComponent, at: $0) } == true

        let id = identity(of: info)
        // Each lookup can race with exit and PID reuse, so check the identity again after reading its paths.
        guard var current = processInfo(for: pid, uid: uid), identity(of: current) == id,
              current.pbi_pgid == info.pbi_pgid, current.pbi_ppid == info.pbi_ppid,
              string(from: &current.pbi_comm) == processName else { return nil }
        let canStop = executable != nil && current.pbi_ruid == uid && !parentApp
        return Record(id: id, pid: pid, name: name, directory: directory, canStop: canStop)
    }

    private static func identity(of info: proc_bsdinfo) -> String {
        "\(info.pbi_pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    private static func processInfo(for pid: pid_t, uid: uid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == uid, info.pbi_status != UInt32(SZOMB),
              info.pbi_flags & UInt32(PROC_FLAG_SYSTEM | PROC_FLAG_INEXIT) == 0 else { return nil }
        return info
    }

    private static func currentDirectory(for pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size,
              let path = string(from: &info.pvi_cdir.vip_path) else { return nil }
        return canonicalPath(path)
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return buffer.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, proc_pidpath(pid, base, UInt32(buffer.count)) > 0,
                  buffer.contains(0), let path = String(validatingUTF8: base), path.hasPrefix("/") else { return nil }
            return path
        }
    }

    private static func isAppExecutable(named name: String, at path: String?) -> Bool {
        if appExecutables.contains(name.lowercased()) { return true }
        guard let path else { return false }
        let components = path.lowercased().split(separator: "/")
        return components.indices.dropLast(2).contains { index in
            let bundle = components[index]
            // The standard macOS Python runtime can use Python.app for ordinary command-line scripts.
            return bundle.hasSuffix(".app") && bundle != "python.app" &&
                components[index + 1] == "contents" && components[index + 2] == "macos"
        }
    }

    private static func string<T>(from field: inout T) -> String? {
        withUnsafeBytes(of: &field) { bytes in
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            return String(bytes: bytes.prefix(end), encoding: .utf8)
        }
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(validatingUTF8: resolved)
    }
}

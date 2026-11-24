import Darwin
import Foundation

struct ScriptTask: Identifiable {
    let id: String
    let name: String
    let directory: URL
    let executable: String
    let arguments: [String]
    let detail: String
    let packagePath: String
    let packageName: String?
    var gradleDebug = false

    var command: String {
        ([executable] + arguments).map(Self.shellQuoted).joined(separator: " ")
            + (gradleDebug ? " --init-script <JDWP>" : "")
    }

    private static func shellQuoted(_ value: String) -> String {
        if !value.isEmpty && value.range(of: #"[^a-zA-Z0-9_./:=,@+-]"#, options: .regularExpression) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum ScriptCatalog {
    private static let fileManager = FileManager.default
    private static let skippedDirectories: Set<String> = [
        "node_modules", "build", "dist", "target", "out", "coverage", "vendor", "Pods",
        "fixtures", "__fixtures__", "testdata",
    ]
    fileprivate static let debugOption =
        "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005"

    static func discover(in project: URL) -> [ScriptTask] {
        let root = project.standardizedFileURL.resolvingSymlinksInPath()
        return projectDirectories(in: root).flatMap { directory, packagePath in
            npmTasks(in: directory, root: root, packagePath: packagePath)
                + mavenTasks(in: directory, root: root, packagePath: packagePath)
                + gradleTasks(in: directory, root: root, packagePath: packagePath)
        }
    }

    private static func projectDirectories(in root: URL) -> [(URL, String)] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var directories = [(root, "")]
        var index = 0
        while index < directories.count {
            let (directory, relativePath) = directories[index]
            index += 1
            let children = (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            )) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard !skippedDirectories.contains(child.lastPathComponent),
                      let values = try? child.resourceValues(forKeys: keys),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let name = child.lastPathComponent
                let path = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                directories.append((child, path))
            }
        }
        return directories
    }

    private static func packageManifest(in directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func npmTasks(in directory: URL, root: URL, packagePath: String) -> [ScriptTask] {
        guard let manifest = packageManifest(in: directory),
              let scripts = manifest["scripts"] as? [String: Any] else { return [] }
        let manager = packageManager(in: directory, root: root, manifest: manifest)
        let packageName = manifestName(manifest)
        return scripts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name in
            guard !name.isEmpty, !name.utf8.contains(0),
                  let script = scripts[name] as? String, !script.isEmpty else { return nil }
            let arguments = name.hasPrefix("-") ? ["run", "--", name] : ["run", name]
            return ScriptTask(
                id: "\(directory.absoluteString)#node:\(name)", name: name, directory: directory,
                executable: manager, arguments: arguments, detail: detail(manager, packagePath: packagePath),
                packagePath: packagePath, packageName: packageName
            )
        }
    }

    private static func manifestName(_ manifest: [String: Any]) -> String? {
        guard let name = (manifest["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return name
    }

    private static func packageManager(in directory: URL, root: URL, manifest: [String: Any]) -> String {
        let lockfiles = [
            ("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lock", "bun"),
            ("bun.lockb", "bun"), ("package-lock.json", "npm"), ("npm-shrinkwrap.json", "npm"),
        ]
        for ancestor in lineage(from: directory, to: root) {
            let package = ancestor == directory ? manifest : packageManifest(in: ancestor)
            if let declared = package?["packageManager"] as? String,
               let name = declared.split(separator: "@").first.map(String.init),
               ["npm", "pnpm", "yarn", "bun"].contains(name) {
                return name
            }
            if let match = lockfiles.first(where: { fileExists($0.0, in: ancestor) }) {
                return match.1
            }
            if fileExists("pnpm-workspace.yaml", in: ancestor) {
                return "pnpm"
            }
        }
        return "npm"
    }

    private static func mavenTasks(in directory: URL, root: URL, packagePath: String) -> [ScriptTask] {
        guard let pom = mavenManifest(in: directory),
              pom.range(of: #"<packaging>\s*pom\s*</packaging>"#, options: .regularExpression) == nil,
              isMavenBootProject(pom, in: directory, root: root) else { return [] }

        let executable = wrapper("mvnw", from: directory, to: root) ?? "mvn"
        let arguments = ["spring-boot:run"]
        return [
            ScriptTask(
                id: "\(directory.absoluteString)#maven:run", name: "Spring Boot Run", directory: directory,
                executable: executable, arguments: arguments, detail: detail("Maven", packagePath: packagePath),
                packagePath: packagePath, packageName: nil
            ),
            ScriptTask(
                id: "\(directory.absoluteString)#maven:debug", name: "Spring Boot Debug", directory: directory,
                executable: executable, arguments: arguments + ["-Dspring-boot.run.jvmArguments=\(debugOption)"],
                detail: detail("Maven · JDWP 127.0.0.1:5005", packagePath: packagePath),
                packagePath: packagePath, packageName: nil
            ),
        ]
    }

    private static func mavenManifest(in directory: URL) -> String? {
        readText("pom.xml", in: directory)?
            .replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
    }

    private static func isMavenBootProject(_ pom: String, in directory: URL, root: URL) -> Bool {
        let plugin = #"<artifactId>\s*spring-boot-maven-plugin\s*</artifactId>"#
        let starter = #"<artifactId>\s*spring-boot-starter(?:-[^<]+)?\s*</artifactId>"#
        if pom.range(of: plugin, options: .regularExpression) != nil
            || pom.range(of: #"<artifactId>\s*spring-boot-starter-parent\s*</artifactId>"#,
                         options: .regularExpression) != nil {
            return true
        }
        return pom.range(of: starter, options: .regularExpression) != nil
            && lineage(from: directory, to: root).dropFirst().contains {
                mavenManifest(in: $0)?.range(of: plugin, options: .regularExpression) != nil
            }
    }

    private static func gradleTasks(in directory: URL, root: URL, packagePath: String) -> [ScriptTask] {
        guard let manifest = readText("build.gradle.kts", in: directory) ?? readText("build.gradle", in: directory) else {
            return []
        }
        let build = manifest.replacingOccurrences(of: #"(?s)/\*.*?\*/|(?m)^[ \t]*//[^\n]*"#,
                                                  with: "", options: .regularExpression)
        let bootPlugin = #"(?m)["']org\.springframework\.boot["'](?:(?!apply\s+false)[^\n])*$"#
        let bootTask = #"\bbootRun\b|\balias\s*\(\s*libs\.plugins\.spring[._-]?boot\b"#
        guard build.range(of: bootPlugin, options: .regularExpression) != nil
                || build.range(of: bootTask, options: .regularExpression) != nil else { return [] }

        let gradleRoot = lineage(from: directory, to: root).first {
            fileExists("settings.gradle", in: $0) || fileExists("settings.gradle.kts", in: $0)
        } ?? directory
        let executable = wrapper("gradlew", from: directory, to: gradleRoot) ?? "gradle"
        let module = relativePath(directory, inside: gradleRoot)
        let taskName = ([":"] + (module.isEmpty ? [] : [module.replacingOccurrences(of: "/", with: ":"), ":"])
            + ["bootRun"]).joined()
        let arguments = ["--no-daemon", "--console=plain", taskName]
        return [
            ScriptTask(
                id: "\(directory.absoluteString)#gradle:run", name: "Spring Boot Run", directory: directory,
                executable: executable, arguments: arguments, detail: detail("Gradle", packagePath: packagePath),
                packagePath: packagePath, packageName: nil
            ),
            ScriptTask(
                id: "\(directory.absoluteString)#gradle:debug", name: "Spring Boot Debug", directory: directory,
                executable: executable, arguments: arguments,
                detail: detail("Gradle · JDWP 127.0.0.1:5005", packagePath: packagePath),
                packagePath: packagePath, packageName: nil,
                gradleDebug: true
            ),
        ]
    }

    private static func detail(_ type: String, packagePath: String) -> String {
        packagePath.isEmpty ? type : "\(type) · \(packagePath)"
    }

    private static func relativePath(_ directory: URL, inside root: URL) -> String {
        directory.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
    }

    private static func lineage(from directory: URL, to root: URL) -> [URL] {
        var ancestor = directory
        var directories = [ancestor]
        while ancestor.pathComponents.count > root.pathComponents.count {
            ancestor.deleteLastPathComponent()
            directories.append(ancestor)
        }
        return directories
    }

    private static func wrapper(_ name: String, from directory: URL, to root: URL) -> String? {
        for ancestor in lineage(from: directory, to: root) {
            let path = ancestor.appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: path) {
                return ancestor == directory ? "./\(name)" : path
            }
        }
        return nil
    }

    private static func fileExists(_ name: String, in directory: URL) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    private static func readText(_ name: String, in directory: URL) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }
}

final class ScriptProcess {
    private let pid: pid_t
    private let output: Int32
    private let startupMarker: Data
    private let gradleDebugDirectory: URL?
    private let language: ScriptManagerLanguage
    private let queue = DispatchQueue(label: "codex-script-manager.process")
    private let source: DispatchSourceRead
    private let onOutput: (String) -> Void
    private let onExit: (Int32) -> Void
    private var pendingBytes = [UInt8]()
    private var reachedTask = false
    private var exitCode: Int32?
    private var stopping = false
    private var forced = false
    private var finished = false

    private init(pid: pid_t, output: Int32, launchToken: String, gradleDebugDirectory: URL?,
                 language: ScriptManagerLanguage,
                 onOutput: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        self.pid = pid
        self.output = output
        startupMarker = Data("\u{001E}\(launchToken)\u{001F}".utf8)
        self.gradleDebugDirectory = gradleDebugDirectory
        self.language = language
        self.onOutput = onOutput
        self.onExit = onExit
        source = DispatchSource.makeReadSource(fileDescriptor: output, queue: queue)
        source.setEventHandler { [weak self] in self?.readOutput() }
        source.setCancelHandler { close(output) }
        source.activate()
        DispatchQueue.global(qos: .utility).async { self.waitForExit() }
    }

    static func start(task: ScriptTask, language: ScriptManagerLanguage, onOutput: @escaping (String) -> Void,
                      onExit: @escaping (Int32) -> Void) throws -> ScriptProcess {
        let gradleDebugDirectory = task.gradleDebug ? try makeGradleDebugConfiguration() : nil
        var arguments = task.arguments
        if let configuration = gradleDebugDirectory?.appendingPathComponent("debug.gradle") {
            arguments += ["--init-script", configuration.path]
        }
        do {
            let launchToken = UUID().uuidString
            let launch = try spawn(task: task, arguments: arguments, launchToken: launchToken, language: language)
            return ScriptProcess(pid: launch.pid, output: launch.output, launchToken: launchToken,
                                 gradleDebugDirectory: gradleDebugDirectory, language: language,
                                 onOutput: onOutput, onExit: onExit)
        } catch {
            if let gradleDebugDirectory { try? FileManager.default.removeItem(at: gradleDebugDirectory) }
            throw error
        }
    }

    func stop() {
        queue.async { self.requestStop() }
    }

    private static func makeGradleDebugConfiguration() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-script-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let program = """
            allprojects {
                tasks.withType(org.gradle.api.tasks.JavaExec).matching { it.name == 'bootRun' }.all {
                    jvmArgs '\(ScriptCatalog.debugOption)'
                }
            }
            """
            try program.write(to: directory.appendingPathComponent("debug.gradle"), atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return directory
    }

    private static func spawn(task: ScriptTask, arguments: [String], launchToken: String,
                              language: ScriptManagerLanguage) throws -> (pid: pid_t, output: Int32) {
        func systemError(_ code: Int32, _ english: String, _ chinese: String) -> NSError {
            let message = strerror(code).map { String(cString: $0) } ?? "errno \(code)"
            return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: language.text("Could not \(english): \(message)", "\(chinese)失败（\(message)）"),
            ])
        }

        func check(_ result: Int32, _ english: String, _ chinese: String) throws {
            if result != 0 { throw systemError(result, english, chinese) }
        }

        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw systemError(errno, "create the log pipe", "创建日志管道") }
        defer { descriptors.forEach { close($0) } }
        let readDescriptor = fcntl(descriptors[0], F_DUPFD_CLOEXEC, 3)
        guard readDescriptor != -1 else { throw systemError(errno, "open the log pipe for reading", "创建日志读端") }
        var started = false
        defer { if !started { close(readDescriptor) } }
        let writeDescriptor = fcntl(descriptors[1], F_DUPFD_CLOEXEC, 3)
        guard writeDescriptor != -1 else { throw systemError(errno, "open the log pipe for writing", "创建日志写端") }
        defer { close(writeDescriptor) }

        guard fcntl(readDescriptor, F_SETFL, O_NONBLOCK) != -1 else {
            throw systemError(errno, "configure the log pipe", "设置日志管道")
        }

        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), "configure the process", "配置进程")
        defer { posix_spawn_file_actions_destroy(&actions) }

        // Keep each task in its own process group so npm wrappers and spawned workers can stop together.
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), "configure the process group", "配置进程组")
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), "configure the process group", "配置进程组")
        try check(posix_spawnattr_setpgroup(&attributes, 0), "set the process group", "设置进程组")
        var signals = sigset_t()
        sigemptyset(&signals)
        try check(posix_spawnattr_setsigmask(&attributes, &signals), "configure process signals", "设置进程信号")
        for signal in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM] { sigaddset(&signals, signal) }
        try check(posix_spawnattr_setsigdefault(&attributes, &signals), "configure process signals", "设置进程信号")

        if #available(macOS 26, *) {
            try check(posix_spawn_file_actions_addchdir(&actions, task.directory.path), "open the working directory", "打开工作目录")
        } else {
            try check(posix_spawn_file_actions_addchdir_np(&actions, task.directory.path), "open the working directory", "打开工作目录")
        }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                  "configure task input", "配置任务输入")
        try check(posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO), "connect standard output", "连接标准输出")
        try check(posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDERR_FILENO), "connect standard error", "连接错误输出")
        try check(posix_spawn_file_actions_addclose(&actions, readDescriptor), "close the child process read end", "关闭子进程读端")
        try check(posix_spawn_file_actions_addclose(&actions, writeDescriptor), "close the child process write end", "关闭子进程写端")

        let shell = loginShell()
        let strings = shell.arguments + [launchToken, task.directory.path, task.executable] + arguments
        var argv = ([shell.path] + strings).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }) else { throw systemError(ENOMEM, "prepare launch arguments", "准备启动参数") }
        argv.append(nil)

        var pid: pid_t = 0
        try check(posix_spawn(&pid, shell.path, &actions, &attributes, &argv, environ), "start the task", "启动任务")
        started = true
        return (pid, readDescriptor)
    }

    private static func loginShell() -> (path: String, arguments: [String]) {
        let preferred = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let preferredName = URL(fileURLWithPath: preferred).lastPathComponent
        let isSupported = ["bash", "zsh", "sh", "ksh", "fish"].contains(preferredName)
            && FileManager.default.isExecutableFile(atPath: preferred)
        let path = isSupported ? preferred : "/bin/zsh"
        let name = isSupported ? preferredName : "zsh"
        // Interactive shells may close inherited descriptors, so mark the handoff in the output stream.
        let announce = #"/usr/bin/printf '\036%s\037'"#
        // Shell startup files can change the directory set by posix_spawn.
        if name == "fish" {
            let command = "builtin cd $argv[2]; or exit; \(announce) $argv[1]; set -e argv[1..2]; exec $argv"
            return (path, ["-ilc", command, "--"])
        }
        let changeDirectory = name == "zsh" ? "builtin cd" : "command cd"
        let command = "\(changeDirectory) -- \"$2\" || exit; \(announce) \"$1\"; shift 2; exec \"$@\""
        return (path, ["-ilc", command, "codex-script-manager"])
    }

    private func waitForExit() {
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
        let signal = status & 0x7F
        let code = result == -1 ? 1 : signal == 0 ? (status >> 8) & 0xFF : 128 + signal
        queue.async { self.leaderExited(with: code) }
    }

    private func leaderExited(with code: Int32) {
        exitCode = code
        if forced || kill(-pid, 0) != 0 {
            finish(with: code)
        } else {
            requestStop()
        }
    }

    private func requestStop() {
        guard !finished, !stopping else { return }
        stopping = true
        kill(-pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.finished else { return }
            kill(-self.pid, SIGKILL)
            self.forced = true
            if let code = self.exitCode { self.finish(with: code) }
        }
    }

    private func readOutput() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var readBytes = 0
        while readBytes < 65_536 {
            let count = read(output, &buffer, buffer.count)
            if count > 0 {
                pendingBytes.append(contentsOf: buffer.prefix(count))
                readBytes += count
            } else if count == 0 {
                source.cancel()
                break
            } else if errno != EINTR {
                break
            }
        }
        emitOutput(flush: false)
    }

    private func emitOutput(flush: Bool) {
        if !reachedTask {
            if let marker = Data(pendingBytes).range(of: startupMarker) {
                pendingBytes.removeFirst(marker.upperBound)
                reachedTask = true
            } else if flush {
                let diagnostics = String(decoding: pendingBytes.suffix(4096), as: UTF8.self)
                pendingBytes.removeAll()
                let message = language.text("The shell exited before starting the task.\n", "Shell 在启动任务前退出。\n") + diagnostics
                DispatchQueue.main.async { [onOutput] in onOutput(message) }
                return
            } else {
                pendingBytes.removeFirst(max(0, pendingBytes.count - 4096))
                return
            }
        }
        var end = pendingBytes.count
        if !flush {
            var last = end - 1
            while last >= 0 && pendingBytes[last] & 0xC0 == 0x80 && end - last <= 4 {
                last -= 1
            }
            if last >= 0 {
                let start = pendingBytes[last]
                let expected = start >= 0xF0 && start <= 0xF4 ? 4 :
                    start >= 0xE0 && start <= 0xEF ? 3 : start >= 0xC2 && start <= 0xDF ? 2 : 1
                if end - last < expected { end = last }
            }
        }
        guard end > 0 else { return }
        let text = String(decoding: pendingBytes[..<end], as: UTF8.self)
        pendingBytes.removeFirst(end)
        DispatchQueue.main.async { [onOutput] in onOutput(text) }
    }

    private func finish(with code: Int32) {
        guard !finished else { return }
        finished = true
        if !source.isCancelled { readOutput() }
        source.cancel()
        emitOutput(flush: true)
        if let gradleDebugDirectory { try? FileManager.default.removeItem(at: gradleDebugDirectory) }
        DispatchQueue.main.async { [onExit] in onExit(code) }
    }
}

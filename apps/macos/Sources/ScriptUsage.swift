import Darwin
import Foundation

struct ScriptUsage {
    enum Category: String {
        case common, automation, unclassified
    }

    struct Evidence: Equatable {
        enum Kind: String {
            case documentation, workflow, script, specialized, noEvidence
        }

        let kind: Kind
        let source: String?
    }

    let category: Category
    let evidence: [Evidence]

    static let unclassified = ScriptUsage(category: .unclassified, evidence: [.init(kind: .noEvidence, source: nil)])

    var bridgeValue: [String: Any] {
        [
            "category": category.rawValue,
            "evidence": evidence.map { item in
                var value = ["kind": item.kind.rawValue]
                if let source = item.source { value["source"] = source }
                return value
            },
        ]
    }

    struct Classifier {
        private struct Command: Hashable {
            let package: String
            let tokens: [String]
        }

        private static let fileManager = FileManager.default
        private static let readLimit = 128 * 1024
        private static let docs = [
            "README.md", "README", "README.rst", "README.en.md", "README.zh-CN.md",
            "CONTRIBUTING.md", "DEVELOPMENT.md", "docs/README.md", "docs/development.md",
            "docs/local-development.md", "docs/getting-started.md", "docs/setup.md",
        ]
        private static let packageManagers: Set<String> = ["npm", "pnpm", "yarn", "bun"]
        private static let specialized = try! NSRegularExpression(pattern:
            #"(?i)(?:^|[\s:._/-])(?:ci|deploy(?:ment)?|releases?|publish|migrat(?:e|ion|ions)|seed|rollback)(?:$|[\s:._/-])"#)
        private static let lifecycle: Set<String> = [
            "preinstall", "install", "postinstall", "prepare", "prepublish", "prepublishonly",
            "prepack", "postpack", "postpublish", "preprepare", "postprepare",
        ]
        private static let shellTokens = try! NSRegularExpression(pattern:
            #"(?:\\.|'[^']*'|"(?:\\.|[^"\\])*"|[^\s;&|'"\\])+|&&|\|\||[;|&\n]"#)
        private static let inlineCode = try! NSRegularExpression(pattern: #"\x60+([^\x60]+)\x60+"#)
        private static let comments = try! NSRegularExpression(pattern: #"(?s)<!--.*?-->"#)

        private let tasks: [ScriptTask]
        private let byPackage: [String: [Int]]
        private let packageNames: [String: Set<String>]
        private let exactCommands: [Command: [Int]]
        private var evidence: [[Evidence]]

        init(tasks: [ScriptTask]) {
            self.tasks = tasks
            byPackage = Dictionary(grouping: tasks.indices, by: { tasks[$0].packagePath })
            var names: [String: Set<String>] = [:]
            var commands: [Command: [Int]] = [:]
            for (index, task) in tasks.enumerated() {
                if let name = task.packageName { names[name, default: []].insert(task.packagePath) }
                if task.configuredCommand != nil {
                    let command = Command(package: task.packagePath, tokens: Self.tokenize(task.command))
                    if !command.tokens.isEmpty { commands[command, default: []].append(index) }
                }
            }
            packageNames = names
            exactCommands = commands
            evidence = Array(repeating: [], count: tasks.count)
        }

        mutating func classify(in project: URL) -> [ScriptTask] {
            guard !tasks.isEmpty else { return [] }
            if let root = Self.realPath(project.path) {
                scanDocumentation(root: root)
                scanWorkflows(root: root)
            }
            for (index, task) in tasks.enumerated() {
                if let definition = task.configuredCommand?.text ?? task.scriptDefinition {
                    let source = [task.packagePath, task.name].filter { !$0.isEmpty }.joined(separator: " / ")
                    scan(definition, in: task.packagePath, evidence: .init(kind: .script, source: source), excluding: index)
                }
                if isSpecialized(task) {
                    add(.init(kind: .specialized, source: task.name), to: index)
                }
            }
            return tasks.enumerated().map { index, item in
                let matches = evidence[index]
                guard !matches.isEmpty else { return item }
                var task = item
                let category: Category = matches.contains(where: { $0.kind == .documentation }) ? .common : .automation
                task.usage = ScriptUsage(category: category, evidence: matches)
                return task
            }
        }

        private mutating func scanDocumentation(root: String) {
            var readCount = 0
            let scopes = [""] + byPackage.keys.filter { !$0.isEmpty }.sorted()
            for scope in scopes.prefix(96) {
                for name in Self.docs {
                    let path = scope.isEmpty ? name : scope + "/" + name
                    guard let text = Self.read(path, in: root) else { continue }
                    let cue = Evidence(kind: .documentation, source: path)
                    for command in Self.documentCommands(text) { scan(command, in: scope, evidence: cue) }
                    readCount += 1
                    if readCount == 96 { return }
                }
            }
        }

        private mutating func scanWorkflows(root: String) {
            var paths = [".gitlab-ci.yml", ".circleci/config.yml", "azure-pipelines.yml", "bitbucket-pipelines.yml"]
            let folder = root + "/.github/workflows"
            if let path = Self.realPath(folder), Self.isInside(path, root: root),
               let names = try? Self.fileManager.contentsOfDirectory(atPath: path) {
                paths += names.sorted().filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
                    .prefix(48).map { ".github/workflows/" + $0 }
            }
            for path in paths {
                guard let text = Self.read(path, in: root) else { continue }
                let cue = Evidence(kind: .workflow, source: path)
                let lines = text.components(separatedBy: .newlines)
                let hasDefaults = lines.contains { Self.yamlKey($0)?.key == "defaults" }
                for (index, line) in lines.enumerated() {
                    guard let field = Self.yamlKey(line), field.key == "run" || field.key == "script" else { continue }
                    let directory = Self.stepDirectory(lines, at: index, indentation: field.indentation)
                    let scope = directory.flatMap { Self.packagePath($0, from: "") }
                        ?? (directory == nil && !hasDefaults ? "" : nil)
                    guard let scope else { continue }
                    if !field.value.isEmpty && !field.value.hasPrefix("|") && !field.value.hasPrefix(">") {
                        scan(Self.scalar(field.value), in: scope, evidence: cue)
                        continue
                    }
                    var body: [String] = []
                    for row in lines.dropFirst(index + 1) {
                        let trimmed = row.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { continue }
                        if row.prefix(while: \.isWhitespace).count <= field.indentation { break }
                        body.append(Self.scalar(trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed))
                    }
                    let joiner = field.value.hasPrefix(">") ? " " : "\n"
                    scan(body.joined(separator: joiner), in: scope, evidence: cue)
                }
            }
        }

        private mutating func scan(_ source: String, in scope: String, evidence cue: Evidence, excluding caller: Int? = nil) {
            let tokens = Self.tokenize(source)
            var current: String? = scope
            if let exact = exactCommands[Command(package: scope, tokens: tokens)] {
                for task in exact where task != caller { add(cue, to: task) }
            }
            for raw in tokens.split(whereSeparator: { [";", "&&", "||", "|", "&", "\n"].contains($0) }) {
                let words = Array(raw)
                guard let program = words.first else { continue }
                if program == "cd" {
                    current = current.flatMap { package in
                        words.count == 2 ? Self.packagePath(words[1], from: package) : nil
                    }
                    continue
                }
                guard let current else { continue }
                let exact = exactCommands[Command(package: current, tokens: words)] ?? []
                let invoked = invocations(words, in: current)
                for task in Set(exact + invoked).sorted() where task != caller { add(cue, to: task) }
            }
        }

        private func invocations(_ words: [String], in scope: String) -> [Int] {
            let executable = words[0].split(separator: "/").last.map(String.init) ?? ""
            let arguments = Array(words.dropFirst())
            if Self.packageManagers.contains(executable) {
                guard let (package, script) = nodeInvocation(executable, arguments, scope: scope) else { return [] }
                return (byPackage[package] ?? []).filter { tasks[$0].scriptDefinition != nil && tasks[$0].name == script }
            }
            if ["mvn", "mvnw"].contains(executable), arguments.contains("spring-boot:run") {
                let usesDifferentProject = arguments.contains { argument in
                    argument.hasPrefix("-pl") || argument == "--projects" || argument.hasPrefix("--projects=")
                        || argument == "--file" || argument.hasPrefix("--file=")
                        || (argument.hasPrefix("-f") && !["-fae", "-ff", "-fn"].contains(argument))
                }
                guard !usesDifferentProject else { return [] }
                let debug = arguments.contains { $0.contains("-agentlib:jdwp") }
                return (byPackage[scope] ?? []).filter {
                    tasks[$0].arguments.contains("spring-boot:run") && tasks[$0].id.hasSuffix(debug ? "#maven:debug" : "#maven:run")
                }
            }
            if ["gradle", "gradlew"].contains(executable),
               let goal = arguments.first(where: { $0 == "bootRun" || $0.hasSuffix(":bootRun") }),
               !arguments.contains("--debug-jvm") {
                let local = (byPackage[scope] ?? []).filter { tasks[$0].id.hasSuffix("#gradle:run") }
                if goal == "bootRun" || goal == ":bootRun" { return local }
                let descendants = tasks.indices.filter {
                    tasks[$0].id.hasSuffix("#gradle:run") && tasks[$0].arguments.contains(goal)
                        && (scope.isEmpty || tasks[$0].packagePath.hasPrefix(scope + "/"))
                }
                return descendants.count == 1 ? descendants : []
            }
            return []
        }

        private func nodeInvocation(_ manager: String, _ arguments: [String], scope: String) -> (String, String)? {
            var package = scope
            var words: [String] = []
            var index = 0
            if manager == "yarn", arguments.first == "workspace" {
                guard arguments.count >= 3, let selected = packageSelection(arguments[1], from: scope) else { return nil }
                package = selected
                index = 2
            }
            let selectors = ["--workspace", "--filter", "-F"] + (manager == "npm" ? ["-w"] : [])
            let directories = ["--prefix", "--cwd", "--dir", "-C"]
            while index < arguments.count {
                let token = arguments[index]
                index += 1
                let requiresRunArgument = words.first == "run" || words.first == "run-script"
                let hasScript = words.count >= (requiresRunArgument ? 2 : 1)
                if hasScript && (token == "--" || manager != "npm") { break }
                if token == "--workspaces" || token == "--recursive" || token == "-r" { return nil }
                if token == "-w", manager == "pnpm" {
                    package = ""
                    continue
                }
                let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
                if let flag = pair.first, selectors.contains(flag) || directories.contains(flag) {
                    guard pair.count == 2 || index < arguments.count else { return nil }
                    let value = pair.count == 2 ? pair[1] : arguments[index]
                    if pair.count == 1 { index += 1 }
                    let target = selectors.contains(flag) ? packageSelection(value, from: scope) : Self.packagePath(value, from: scope)
                    guard let target else { return nil }
                    package = target
                } else if token != "--" {
                    words.append(token)
                }
            }
            if words.first == "run" || words.first == "run-script" {
                return words.count > 1 ? (package, words[1]) : nil
            }
            guard let script = words.first, !script.hasPrefix("-") else { return nil }
            if manager == "npm" && !["start", "stop", "restart", "test"].contains(script) { return nil }
            if ["install", "add", "remove", "exec", "dlx", "workspace", "create", "init", "update"].contains(script) { return nil }
            return (package, script)
        }

        private func packageSelection(_ value: String, from scope: String) -> String? {
            if let names = packageNames[value] { return names.count == 1 ? names.first : nil }
            if let path = Self.packagePath(value, from: scope), byPackage[path] != nil { return path }
            if let path = Self.packagePath(value, from: ""), byPackage[path] != nil { return path }
            return nil
        }

        private func isSpecialized(_ task: ScriptTask) -> Bool {
            if Self.specialized.firstMatch(in: task.name, range: NSRange(task.name.startIndex..., in: task.name)) != nil {
                return true
            }
            guard task.scriptDefinition != nil else { return false }
            let name = task.name.lowercased()
            if Self.lifecycle.contains(name) { return true }
            let prefix = name.hasPrefix("post") ? "post" : name.hasPrefix("pre") ? "pre" : nil
            guard let prefix, name.count > prefix.count else { return false }
            return (byPackage[task.packagePath] ?? []).contains {
                tasks[$0].scriptDefinition != nil && tasks[$0].name.lowercased() == name.dropFirst(prefix.count)
            }
        }

        private mutating func add(_ cue: Evidence, to task: Int) {
            if evidence[task].contains(cue) { return }
            let sameKind = evidence[task].filter { $0.kind == cue.kind }
            if sameKind.count < 3 { evidence[task].append(cue) }
        }

        private static func tokenize(_ command: String) -> [String] {
            let text = command.replacingOccurrences(of: "\\\n", with: " ")
            guard !text.contains("$(") else { return [] }
            var result: [String] = []
            var skippingComment = false
            for match in shellTokens.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let raw = String(text[range])
                if raw == "\n" {
                    skippingComment = false
                } else if raw.hasPrefix("#") {
                    skippingComment = true
                }
                if skippingComment { continue }
                if raw == "$" && (result.last == nil || ["\n", ";", "&&", "||"].contains(result.last ?? "")) { continue }
                if (raw.first == "\"" && raw.last == "\"") || (raw.first == "'" && raw.last == "'") {
                    result.append(String(raw.dropFirst().dropLast()))
                } else {
                    result.append(raw.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression))
                }
            }
            return result
        }

        private static func documentCommands(_ source: String) -> [String] {
            let text = comments.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "")
            var commands: [String] = []
            var block: [String] = []
            var fence: String?
            var shell = false
            let tick = String(repeating: "\u{0060}", count: 3)
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let marker = fence {
                    if trimmed.hasPrefix(marker) {
                        if shell { commands.append(block.joined(separator: "\n")) }
                        block.removeAll()
                        shell = false
                        fence = nil
                    } else if shell {
                        block.append(trimmed)
                    }
                } else if trimmed.hasPrefix(tick) || trimmed.hasPrefix("~~~") {
                    fence = String(trimmed.prefix(3))
                    shell = ["", "sh", "shell", "bash", "zsh", "console", "terminal", "shellsession"].contains(
                        trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased())
                } else {
                    for match in inlineCode.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                        if let range = Range(match.range(at: 1), in: trimmed) { commands.append(String(trimmed[range])) }
                    }
                    commands.append(trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed)
                }
            }
            return commands
        }

        private static func yamlKey(_ line: String) -> (key: String, value: String, indentation: Int)? {
            let prefix = line.prefix(while: \.isWhitespace)
            var trimmed = line.dropFirst(prefix.count)
            let item = trimmed.hasPrefix("- ")
            if item { trimmed = trimmed.dropFirst(2) }
            guard let colon = trimmed.firstIndex(of: ":"), !trimmed.hasPrefix("#") else { return nil }
            return (String(trimmed[..<colon]), trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces),
                    prefix.count + (item ? 2 : 0))
        }

        private static func stepDirectory(_ lines: [String], at index: Int, indentation: Int) -> String? {
            if !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                for offset in stride(from: index - 1, through: 0, by: -1) {
                    let line = lines[offset]
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }
                    if let field = yamlKey(line), field.indentation == indentation, field.key == "working-directory" {
                        return scalar(field.value)
                    }
                    if line.prefix(while: \.isWhitespace).count < indentation { break }
                }
            }
            for line in lines.dropFirst(index + 1) {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                if line.prefix(while: \.isWhitespace).count < indentation { break }
                if let field = yamlKey(line), field.indentation == indentation, field.key == "working-directory" {
                    return scalar(field.value)
                }
            }
            return nil
        }

        private static func scalar(_ value: String) -> String {
            if value.count >= 2 && ((value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'")) {
                return String(value.dropFirst().dropLast())
            }
            return value
        }

        private static func packagePath(_ path: String, from base: String) -> String? {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
                  path.rangeOfCharacter(from: CharacterSet(charactersIn: "$*{}?[]")) == nil else { return nil }
            var components = base.split(separator: "/")
            for part in path.split(separator: "/") where part != "." {
                if part == ".." {
                    guard !components.isEmpty else { return nil }
                    components.removeLast()
                } else {
                    components.append(part)
                }
            }
            return components.joined(separator: "/")
        }

        private static func realPath(_ path: String) -> String? {
            guard let value = realpath(path, nil) else { return nil }
            defer { free(value) }
            return String(validatingUTF8: value)
        }

        private static func isInside(_ path: String, root: String) -> Bool {
            path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }

        private static func read(_ path: String, in root: String) -> String? {
            guard let resolved = realPath(root + "/" + path), isInside(resolved, root: root),
                  let attributes = try? fileManager.attributesOfItem(atPath: resolved),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.uint64Value <= readLimit,
                  let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: resolved)) else { return nil }
            defer { try? file.close() }
            guard let data = try? file.read(upToCount: readLimit + 1), data.count <= readLimit else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}

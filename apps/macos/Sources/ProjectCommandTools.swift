import Foundation

enum ProjectCommandTools {
    struct Message: Error, Decodable {
        let english: String
        let chinese: String

        func localized(in language: ScriptManagerLanguage) -> String { language.text(english, chinese) }
    }

    struct Candidate: Decodable, Identifiable {
        let id: String
        let name: String
        let command: String
        let cwd: String
        let detail: String

        func row(rootPath: String) -> [String: String] {
            ["id": id, "name": name, "command": command, "cwd": cwd, "detail": detail, "rootPath": rootPath]
        }
    }

    struct Action: Decodable {
        let id: String
        let name: String
        let command: String
        let cwd: String
        let detail: String
        let shell: String
    }

    struct Scan: Decodable {
        let candidates: [Candidate]
        let actions: [Action]
        let actionError: Message?
    }

    private struct Save: Decodable {
        let ok: Bool?
        let error: Message?
    }

    private static let unavailable = Message(
        english: "Could not load project command suggestions. Check that Python 3 is installed.",
        chinese: "无法加载项目命令建议。请检查是否已安装 Python 3。"
    )

    static func scan(in root: URL) -> Scan {
        do {
            return try invoke(Scan.self, arguments: ["scan", root.path])
        } catch {
            return Scan(candidates: [], actions: [], actionError: unavailable)
        }
    }

    static func save(_ candidateID: String, in root: URL) -> Result<Void, Message> {
        do {
            let response = try invoke(Save.self, arguments: ["add", root.path, candidateID])
            if response.ok == true { return .success(()) }
            if let error = response.error { return .failure(error) }
        } catch {}
        return .failure(Message(english: "Could not save the suggested command.", chinese: "无法保存建议的命令。"))
    }

    private static func invoke<Response: Decodable>(_ type: Response.Type, arguments: [String]) throws -> Response {
        let installed = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("project_commands.py")
        let script = Bundle.main.url(forResource: "project_commands", withExtension: "py") ?? installed
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try JSONDecoder().decode(type, from: data)
    }
}

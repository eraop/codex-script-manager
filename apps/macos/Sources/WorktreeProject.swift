import Foundation

enum WorktreeProject {
    static func attachedPaths(for path: String, in folders: [CodexProjectCatalog.Folder]) -> [String] {
        let checkout = URL(fileURLWithPath: path, isDirectory: true)
        let marker = checkout.appendingPathComponent(".git")
        guard let contents = readMarker(marker), contents.hasPrefix("gitdir: ") else { return [] }
        let metadata = URL(fileURLWithPath: String(contents.dropFirst("gitdir: ".count)),
                           isDirectory: true, relativeTo: checkout)
        guard let linkedMarker = readMarker(metadata.appendingPathComponent("gitdir")),
              URL(fileURLWithPath: linkedMarker, relativeTo: metadata).standardizedFileURL.resolvingSymlinksInPath().path
                == marker.resolvingSymlinksInPath().path,
              let common = readMarker(metadata.appendingPathComponent("commondir")) else { return [] }
        let commonDir = URL(fileURLWithPath: common, isDirectory: true, relativeTo: metadata)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let matches = folders.filter { folder in
            guard let primary = folder.rootPaths.first else { return false }
            return URL(fileURLWithPath: primary, isDirectory: true).appendingPathComponent(".git")
                .resolvingSymlinksInPath().path == commonDir
        }
        guard matches.count == 1, let project = matches.first else { return [] }
        return Array(project.rootPaths.dropFirst())
    }

    private static func readMarker(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 8192,
              let data = try? Data(contentsOf: url), data.count <= 8192,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
              !value.isEmpty, !value.utf8.contains(0) else { return nil }
        return value
    }
}

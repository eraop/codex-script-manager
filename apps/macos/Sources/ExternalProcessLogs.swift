import Darwin
import Foundation

enum ExternalProcessLogs {
    struct Source {
        let id: String
        let label: String
    }

    enum Failure: LocalizedError {
        case unavailable
        case unreadable

        var errorDescription: String? { description(in: .preferred) }

        func description(in language: ScriptManagerLanguage) -> String {
            switch self {
            case .unavailable:
                return language.text("This log file is no longer open. Refresh the process list.",
                                     "该日志文件已关闭，请刷新进程列表。")
            case .unreadable:
                return language.text("Could not read the external log file.", "无法读取外部日志文件。")
            }
        }
    }

    private struct FileIdentity: Hashable {
        let device: UInt32
        let inode: UInt64
        let generation: UInt32
    }

    private struct Output {
        let descriptor: Int32
        let path: String
        let identity: FileIdentity

        var source: Source {
            Source(id: "\(descriptor):\(identity.device):\(identity.inode):\(identity.generation)",
                   label: URL(fileURLWithPath: path).lastPathComponent)
        }
    }

    private static let standardStreams = [STDOUT_FILENO, STDERR_FILENO]
    private static let maxTailBytes = 65_536

    static func sources(for pid: pid_t) -> [Source] {
        guard pid > 0 else { return [] }
        var seen = Set<FileIdentity>()
        return candidateDescriptors(for: pid).compactMap { descriptor in
            guard let output = output(for: pid, descriptor: descriptor), !seen.contains(output.identity),
                  let (file, _) = openVerified(output) else { return nil }
            close(file)
            seen.insert(output.identity)
            return output.source
        }
    }

    static func read(for pid: pid_t, sourceID: String) throws -> String {
        guard pid > 0, let prefix = sourceID.split(separator: ":", maxSplits: 1).first,
              let descriptor = Int32(prefix), descriptor >= STDOUT_FILENO,
              let output = output(for: pid, descriptor: descriptor), output.source.id == sourceID,
              let (file, size) = openVerified(output) else { throw Failure.unavailable }
        defer { close(file) }

        let length = Int(min(size, off_t(maxTailBytes)))
        let offset = size - off_t(length)
        var bytes = [UInt8](repeating: 0, count: length)
        var received = 0
        while received < length {
            let count = bytes.withUnsafeMutableBufferPointer { buffer in
                pread(file, buffer.baseAddress?.advanced(by: received), length - received, offset + off_t(received))
            }
            if count > 0 { received += count }
            else if count == 0 { break }
            else if errno != EINTR { throw Failure.unreadable }
        }
        return String(decoding: bytes.prefix(received), as: UTF8.self)
    }

    private static func candidateDescriptors(for pid: pid_t) -> [Int32] {
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
        let count = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return standardStreams }
        let outputs = descriptors.prefix(Int(count) / MemoryLayout<proc_fdinfo>.stride)
            .filter { $0.proc_fd > STDERR_FILENO && $0.proc_fdtype == PROX_FDTYPE_VNODE }
            .prefix(96)
            .map(\.proc_fd)
        return standardStreams + outputs
    }

    private static func output(for pid: pid_t, descriptor: Int32) -> Output? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDVNODEPATHINFO, &info, size) == size,
              info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { return nil }
        let metadata = info.pvip.vip_vi.vi_stat
        guard metadata.vst_mode & S_IFMT == S_IFREG else { return nil }
        let path = withUnsafeBytes(of: info.pvip.vip_path) { bytes -> String? in
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            return String(bytes: bytes[..<end], encoding: .utf8)
        }
        guard let path, path.hasPrefix("/"),
              standardStreams.contains(descriptor) || path.lowercased().hasSuffix(".log") else { return nil }
        let identity = FileIdentity(device: metadata.vst_dev, inode: metadata.vst_ino, generation: metadata.vst_gen)
        return Output(descriptor: descriptor, path: path, identity: identity)
    }

    private static func openVerified(_ output: Output) -> (Int32, off_t)? {
        let file = open(output.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return nil }
        var metadata = stat()
        // Reopening the pathname must still reach the process's open file after rotation.
        guard fstat(file, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0,
              UInt32(bitPattern: metadata.st_dev) == output.identity.device,
              metadata.st_ino == output.identity.inode,
              metadata.st_gen == output.identity.generation else {
            close(file)
            return nil
        }
        return (file, metadata.st_size)
    }
}

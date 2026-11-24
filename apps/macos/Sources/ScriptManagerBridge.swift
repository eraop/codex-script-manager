import Darwin
import Foundation

final class ScriptManagerBridge {
    struct Request: Codable {
        let method: String
        let projectId: String?
        let taskId: String?
        let locale: String?
        let destination: String?
        let pinned: String?
    }

    enum Failure: LocalizedError {
        case occupied
        case invalid(String, String)
        case system(String, String, Int32)

        var errorDescription: String? { description(in: .preferred) }

        func description(in language: ScriptManagerLanguage) -> String {
            switch self {
            case .occupied:
                return language.text("Another Script Manager is already running.", "另一个脚本管理器已经在运行。")
            case .invalid(let english, let chinese):
                return language.text(english, chinese)
            case .system(let english, let chinese, let code):
                let details = String(cString: strerror(code))
                return language.text("\(english): \(details)", "\(chinese)：\(details)")
            }
        }
    }

    private static let socketName = "manager.sock"
    private static let maxRequestSize = 16_384
    private static let ioBudget: UInt64 = 3_000_000_000
    private let listener: Int32
    private let source: DispatchSourceRead
    private let slots = DispatchSemaphore(value: 8)
    private let handle: (Request) -> [String: Any]

    init(handle: @escaping (Request) -> [String: Any]) throws {
        self.handle = handle
        let directoryPath = try Self.directoryPath()
        let path = directoryPath + "/" + Self.socketName
        let directory = try Self.openDirectory(directoryPath)
        var didStart = false
        defer { if !didStart { close(directory) } }

        // Hold the lock for the life of the listener, including when the app has no window.
        let lock = try Self.lockDirectory(directory)
        defer { if !didStart { close(lock) } }
        try Self.removeStaleSocket(path, in: directory)

        let descriptor = try Self.makeSocket()
        defer { if !didStart { close(descriptor) } }
        let result = try Self.withAddress(path) { bind(descriptor, $0, $1) }
        guard result == 0 else { throw Failure.system("Could not bind the Script Manager connection", "无法绑定脚本管理连接", errno) }
        defer { if !didStart { unlinkat(directory, Self.socketName, 0) } }

        guard fchmodat(directory, Self.socketName, 0o600, 0) == 0 else {
            throw Failure.system("Could not set Script Manager connection permissions", "无法设置脚本管理连接权限", errno)
        }
        guard listen(descriptor, 16) == 0 else {
            throw Failure.system("Could not listen for Script Manager connections", "无法监听脚本管理连接", errno)
        }
        var identity = stat()
        guard fstatat(directory, Self.socketName, &identity, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Failure.system("Could not inspect the Script Manager connection", "无法检查脚本管理连接", errno)
        }

        listener = descriptor
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor,
                                               queue: DispatchQueue(label: "codex-script-manager.bridge"))
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler {
            close(descriptor)
            var current = stat()
            if fstatat(directory, Self.socketName, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_dev == identity.st_dev && current.st_ino == identity.st_ino {
                unlinkat(directory, Self.socketName, 0)
            }
            close(lock)
            close(directory)
        }
        didStart = true
        source.activate()
    }

    deinit { source.cancel() }

    static func forwardNativeOpen(_ urls: [URL], finished: @escaping () -> Void) {
        let requests = urls.isEmpty
            ? [Request(method: "revealNative", projectId: nil, taskId: nil, locale: nil, destination: nil, pinned: nil)]
            : urls.map { Request(method: "revealNative", projectId: $0.path, taskId: nil, locale: nil, destination: nil, pinned: nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let path = try directoryPath() + "/" + socketName
                for request in requests { try forward(request, to: path) }
            } catch {
                NSLog("Script Manager handoff failed: %@", error.localizedDescription)
            }
            DispatchQueue.main.async(execute: finished)
        }
    }

    private static func directoryPath() throws -> String {
        let directory = ProcessInfo.processInfo.environment["CODEX_SCRIPT_MANAGER_SOCKET_DIR"]
            ?? "/tmp/codex-script-manager-\(getuid())"
        guard directory.hasPrefix("/"), !directory.utf8.contains(0) else {
            throw Failure.invalid("The Script Manager socket directory must be an absolute path.", "脚本管理连接目录必须是绝对路径。")
        }
        return URL(fileURLWithPath: directory).standardizedFileURL.path
    }

    private static func openDirectory(_ path: String) throws -> Int32 {
        if mkdir(path, 0o700) == -1 && errno != EEXIST {
            throw Failure.system("Could not create the Script Manager socket directory", "无法创建脚本管理连接目录", errno)
        }
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.system("Could not open the Script Manager socket directory", "无法打开脚本管理连接目录", errno) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o700 else {
            close(directory)
            throw Failure.invalid("The Script Manager socket directory must belong to the current user and have mode 0700.", "脚本管理连接目录必须由当前用户拥有，权限为 0700。")
        }
        return directory
    }

    private static func lockDirectory(_ directory: Int32) throws -> Int32 {
        let lock = openat(directory, "manager.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw Failure.system("Could not open the Script Manager lock", "无法打开脚本管理锁", errno) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600, info.st_nlink == 1 else {
            close(lock)
            throw Failure.invalid("The Script Manager lock must be a regular file owned by the current user with mode 0600.", "脚本管理锁必须是当前用户拥有的普通文件，权限为 0600。")
        }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(lock)
            if code == EWOULDBLOCK || code == EAGAIN { throw Failure.occupied }
            throw Failure.system("Could not acquire the Script Manager lock", "无法获取脚本管理锁", code)
        }
        return lock
    }

    private static func removeStaleSocket(_ path: String, in directory: Int32) throws {
        var info = stat()
        if fstatat(directory, socketName, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw Failure.system("Could not inspect the existing Script Manager connection", "无法检查现有脚本管理连接", errno)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
            throw Failure.invalid("The existing Script Manager connection is not a Unix socket owned by the current user.", "现有脚本管理连接不是当前用户拥有的 Unix 套接字。")
        }
        let probe = try makeSocket()
        defer { close(probe) }
        let result = try withAddress(path) { connect(probe, $0, $1) }
        let code = errno
        if result == 0 || code == EINPROGRESS || code == EWOULDBLOCK || code == EALREADY {
            throw Failure.occupied
        }
        if code == ENOENT { return }
        guard code == ECONNREFUSED else { throw Failure.system("Could not determine the existing Script Manager connection status", "无法确认现有脚本管理连接状态", code) }
        var current = stat()
        if fstatat(directory, socketName, &current, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw Failure.system("Could not check the existing Script Manager connection again", "无法复查现有脚本管理连接", errno)
        }
        guard current.st_dev == info.st_dev && current.st_ino == info.st_ino else {
            throw Failure.invalid("The Script Manager connection changed during startup.", "脚本管理连接在启动期间发生变化。")
        }
        if unlinkat(directory, socketName, 0) != 0 && errno != ENOENT {
            throw Failure.system("Could not remove the stale Script Manager socket", "无法清理已失效的脚本管理连接", errno)
        }
    }

    private static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.system("Could not create the Unix socket", "无法创建 Unix 套接字", errno) }
        do {
            try configure(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func configure(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw Failure.system("Could not configure the Script Manager connection", "无法配置脚本管理连接", errno)
        }
    }

    private static func withAddress(_ path: String, _ action: (UnsafePointer<sockaddr>, socklen_t) -> Int32)
        throws -> Int32 {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure.invalid("The Script Manager socket path is too long.", "脚本管理连接路径过长。")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                action($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private func acceptConnections() {
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                return
            }
            var user = uid_t()
            var group = gid_t()
            guard getpeereid(connection, &user, &group) == 0, user == getuid(),
                  (try? Self.configure(connection)) != nil, slots.wait(timeout: .now()) == .success else {
                close(connection)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { self.read(connection) }
        }
    }

    private func read(_ connection: Int32) {
        do {
            let data = try Self.readLine(connection)
            let request = try JSONDecoder().decode(Request.self, from: data)
            DispatchQueue.main.async {
                let response = self.handle(request)
                DispatchQueue.global(qos: .userInitiated).async { self.reply(response, to: connection) }
            }
        } catch {
            let language = ScriptManagerLanguage.preferred
            let message = (error as? Failure)?.description(in: language)
                ?? language.text("The Script Manager request is not valid JSON.", "脚本管理请求不是有效的 JSON。")
            reply(["ok": false, "error": message], to: connection)
        }
    }

    private func reply(_ response: [String: Any], to connection: Int32) {
        defer {
            close(connection)
            slots.signal()
        }
        guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
        data.append(10)
        try? Self.writeAll(data, to: connection)
    }

    private static func readLine(_ descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = DispatchTime.now().uptimeNanoseconds + ioBudget
        while true {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { throw Failure.invalid("The Script Manager request is missing a newline.", "脚本管理请求缺少行结束符。") }
            if count < 0 {
                if errno == EINTR || errno == EWOULDBLOCK { continue }
                throw Failure.system("Could not read the Script Manager request", "无法读取脚本管理请求", errno)
            }
            let bytes = buffer[..<count]
            let end = bytes.firstIndex(of: 10) ?? count
            guard data.count + end <= maxRequestSize else {
                throw Failure.invalid("The Script Manager request is too long.", "脚本管理请求过长。")
            }
            data.append(contentsOf: bytes[..<end])
            if end < count { return data }
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + ioBudget
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                let written = send(descriptor, base.advanced(by: offset), bytes.count - offset, 0)
                if written <= 0 {
                    if written < 0 && (errno == EINTR || errno == EWOULDBLOCK) { continue }
                    throw Failure.system("Could not send the Script Manager message", "无法发送脚本管理消息", written < 0 ? errno : EPIPE)
                }
                offset += written
            }
        }
    }

    private static func wait(_ descriptor: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw Failure.invalid("The Script Manager connection timed out.", "脚本管理连接超时。") }
            var event = pollfd(fd: descriptor, events: events, revents: 0)
            let remaining = Int32((deadline - now + 999_999) / 1_000_000)
            let result = poll(&event, 1, remaining)
            if result > 0 { return }
            if result == 0 { throw Failure.invalid("The Script Manager connection timed out.", "脚本管理连接超时。") }
            if errno != EINTR { throw Failure.system("Error while waiting for the Script Manager connection", "无法等待脚本管理连接", errno) }
        }
    }

    private static func forward(_ request: Request, to path: String) throws {
        let descriptor = try makeSocket()
        defer { close(descriptor) }
        let deadline = DispatchTime.now().uptimeNanoseconds + ioBudget
        while true {
            let result = try withAddress(path) { connect(descriptor, $0, $1) }
            let code = errno
            if result == 0 { break }
            if code == EINPROGRESS || code == EALREADY {
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else {
                    throw Failure.system("Could not inspect the Script Manager connection", "无法检查脚本管理连接", errno)
                }
                guard error == 0 else { throw Failure.system("Could not connect to Script Manager", "无法连接脚本管理器", error) }
                break
            }
            if (code == ENOENT || code == ECONNREFUSED || code == EWOULDBLOCK)
                && DispatchTime.now().uptimeNanoseconds < deadline {
                usleep(50_000)
                continue
            }
            throw Failure.system("Could not connect to Script Manager", "无法连接脚本管理器", code)
        }
        var data = try JSONEncoder().encode(request)
        data.append(10)
        try writeAll(data, to: descriptor)
        _ = try readLine(descriptor)
    }
}

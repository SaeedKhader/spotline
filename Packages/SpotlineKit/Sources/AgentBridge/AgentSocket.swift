import Darwin
import Foundation

/// Where the running app listens for agents: a Unix domain socket in the user's
/// Application Support folder, readable and writable only by the user. Nothing
/// listens on the network. `SPOTLINE_AGENT_SOCKET` overrides it (tests).
public enum AgentSocketPath {
    public static let environmentKey = "SPOTLINE_AGENT_SOCKET"

    public static var `default`: String {
        if let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty { return path }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Spotline/agent.sock").path
    }
}

public enum AgentSocketError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Another Spotline is already serving agents on the socket.
    case inUse(String)
    /// A POSIX call failed.
    case system(String, Int32)
    /// Unix socket paths are limited to 103 bytes.
    case pathTooLong(String)
    /// The app closed the connection or never answered.
    case noAnswer

    public var description: String {
        switch self {
        case .inUse: "Another Spotline window is already connected to agents."
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        case .pathTooLong(let path): "The socket path is too long: \(path)"
        case .noAnswer: "Spotline didn't answer."
        }
    }
}

/// Listens on the agent socket and answers each newline-delimited message with
/// `handle`, one at a time per connection, in order.
public final class AgentSocketServer: @unchecked Sendable {
    public let path: String
    private let handle: @Sendable (Data) async -> Data?
    private let queue = DispatchQueue(label: "io.github.saeedkhader.spotline.agent-socket")
    private let lock = NSLock()
    private var listener: DispatchSourceRead?
    private var connections: [Int32: DispatchSourceRead] = [:]

    public init(path: String = AgentSocketPath.default, handle: @escaping @Sendable (Data) async -> Data?) {
        self.path = path
        self.handle = handle
    }

    deinit { stop() }

    public var isRunning: Bool { lock.withLock { listener != nil } }

    /// Starts listening. A socket file left by a Spotline that quit is replaced.
    public func start() throws {
        guard !isRunning else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: path) {
            if let fd = try? AgentSocket.connect(to: path) {
                close(fd)
                throw AgentSocketError.inUse(path)
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocketError.system("socket", errno) }
        do {
            try AgentSocket.withAddress(path) { address, length in
                guard bind(fd, address, length) == 0 else { throw AgentSocketError.system("bind", errno) }
            }
            guard chmod(path, 0o600) == 0 else { throw AgentSocketError.system("chmod", errno) }
            guard listen(fd, 8) == 0 else { throw AgentSocketError.system("listen", errno) }
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw AgentSocketError.system("fcntl", errno) }
        } catch {
            close(fd)
            unlink(path)
            throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections(on: fd) }
        source.setCancelHandler { close(fd) }
        lock.withLock { listener = source }
        source.resume()
    }

    /// Stops listening, closes every connection and removes the socket file.
    public func stop() {
        let (listener, connections) = lock.withLock {
            defer {
                self.listener = nil
                self.connections = [:]
            }
            return (self.listener, self.connections)
        }
        guard let listener else { return }
        // Removed now rather than when the socket closes, which could remove a new server's file.
        unlink(path)
        listener.cancel()
        for source in connections.values { source.cancel() }
    }

    private func acceptConnections(on listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Accepted sockets inherit O_NONBLOCK; replies are written blocking.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            serve(fd)
        }
    }

    private func serve(_ fd: Int32) {
        let (lines, continuation) = AsyncStream.makeStream(of: Data.self)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var buffer = Data()
        source.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                self?.drop(fd)
                return
            }
            buffer.append(contentsOf: chunk[..<count])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) { continuation.yield(Data(line)) }
            }
        }
        source.setCancelHandler {
            continuation.finish()
            close(fd)
        }
        lock.withLock { connections[fd] = source }
        source.resume()
        let handle = handle
        Task {
            for await line in lines {
                guard let reply = await handle(line) else { continue }
                // Fails only when the agent has gone; its connection is then dropped by the read side.
                try? AgentSocket.write(reply + Data("\n".utf8), to: fd)
            }
        }
    }

    private func drop(_ fd: Int32) {
        lock.withLock { connections.removeValue(forKey: fd) }?.cancel()
    }
}

/// The helper's side of the socket: one request, one reply, reconnecting as needed.
public final class AgentSocketClient {
    public let path: String
    public var timeout: TimeInterval
    private var fd: Int32 = -1
    private var buffer = Data()

    public init(path: String = AgentSocketPath.default, timeout: TimeInterval = 60) {
        self.path = path
        self.timeout = timeout
    }

    deinit { disconnect() }

    /// Sends one message and returns the reply line. Retries once on a fresh
    /// connection, since the app may have restarted since the last call.
    public func send(_ line: Data) throws -> Data {
        do {
            return try exchange(line)
        } catch AgentSocketError.noAnswer where fd >= 0 {
            disconnect()
            return try exchange(line)
        } catch AgentSocketError.system(_, let code) where code == EPIPE || code == ECONNRESET {
            disconnect()
            return try exchange(line)
        }
    }

    private func exchange(_ line: Data) throws -> Data {
        if fd < 0 {
            fd = try AgentSocket.connect(to: path)
            var seconds = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
            buffer = Data()
        }
        do {
            try AgentSocket.write(line + Data("\n".utf8), to: fd)
            while true {
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let reply = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return reply
                }
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { throw AgentSocketError.noAnswer }
                buffer.append(contentsOf: chunk[..<count])
            }
        } catch {
            if case AgentSocketError.noAnswer = error {} else { disconnect() }
            throw error
        }
    }

    public func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
    }
}

enum AgentSocket {
    static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocketError.system("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        do {
            try withAddress(path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else { throw AgentSocketError.system("connect", errno) }
            }
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    static func withAddress<Result>(
        _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw AgentSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AgentSocketError.system("write", errno)
                }
                offset += written
            }
        }
    }
}

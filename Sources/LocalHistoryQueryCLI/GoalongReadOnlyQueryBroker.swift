#if os(macOS)
    import Darwin
    import Dispatch
    import Foundation

    private struct GoalongBrokerRequest: Codable {
        let schemaVersion: Int
        let command: String
        let day: String
        let macOnly: Bool
    }

    private struct GoalongBrokerError: Codable {
        let brokerError: String
    }

    public enum GoalongReadOnlyQueryBroker {
        static let maximumRequestBytes = 4 * 1_024
        static let maximumResponseBytes = 64 * 1_024 * 1_024

        public static func requestScreenTime(
            rootDirectory: URL,
            day: String,
            macOnly: Bool
        ) throws -> Data {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw BrokerFailure.system("socket", errno) }
            defer { Darwin.close(descriptor) }
            setNoSigPipe(descriptor)

            var address = try unixAddress(for: socketURL(rootDirectory: rootDirectory).path)
            let result = withUnsafePointer(to: &address.value) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, address.length)
                }
            }
            guard result == 0 else { throw BrokerFailure.system("connect", errno) }

            var request = try JSONEncoder().encode(
                GoalongBrokerRequest(
                    schemaVersion: 1,
                    command: "screen-time",
                    day: day,
                    macOnly: macOnly
                )
            )
            request.append(0x0A)
            try writeAll(request, to: descriptor)
            Darwin.shutdown(descriptor, SHUT_WR)

            let response = try readAll(
                from: descriptor,
                maximumBytes: maximumResponseBytes
            )
            guard !response.isEmpty else { throw BrokerFailure.emptyResponse }
            if let failure = try? JSONDecoder().decode(GoalongBrokerError.self, from: response) {
                throw BrokerFailure.remote(failure.brokerError)
            }
            _ = try JSONSerialization.jsonObject(with: response)
            return response
        }

        public static func socketURL(rootDirectory: URL) -> URL {
            rootDirectory
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("goalong-readonly.sock", isDirectory: false)
        }

        fileprivate static func unixAddress(for path: String) throws -> (
            value: sockaddr_un, length: socklen_t
        ) {
            var address = sockaddr_un()
            let bytes = Array(path.utf8CString)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard bytes.count <= capacity else { throw BrokerFailure.socketPathTooLong }
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    for index in bytes.indices {
                        destination[index] = bytes[index]
                    }
                }
            }
            let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
            address.sun_len = UInt8(min(Int(UInt8.max), Int(length)))
            return (address, length)
        }

        fileprivate static func setNoSigPipe(_ descriptor: Int32) {
            var enabled: Int32 = 1
            _ = withUnsafePointer(to: &enabled) {
                Darwin.setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    $0,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
        }

        fileprivate static func writeAll(_ data: Data, to descriptor: Int32) throws {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw BrokerFailure.system("write", errno) }
                    offset += count
                }
            }
        }

        fileprivate static func readAll(from descriptor: Int32, maximumBytes: Int) throws -> Data {
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw BrokerFailure.system("read", errno) }
                if count == 0 { return result }
                guard result.count + count <= maximumBytes else {
                    throw BrokerFailure.responseTooLarge
                }
                result.append(contentsOf: buffer.prefix(count))
            }
        }
    }

    public final class GoalongReadOnlyQueryServer {
        typealias ScreenTimeHandler = (String, Bool) throws -> Data

        private let rootDirectory: URL
        private let screenTimeHandler: ScreenTimeHandler
        private let queue = DispatchQueue(
            label: "ai.goalong.localhistory.readonly-query-broker",
            qos: .utility
        )
        private var source: DispatchSourceRead?
        private var listeningDescriptor: Int32 = -1

        public convenience init(rootDirectory: URL) {
            self.init(
                rootDirectory: rootDirectory,
                screenTimeHandler: { day, macOnly in
                    try GoalongQueryCLI.screenTimePayload(day: day, macOnly: macOnly)
                }
            )
        }

        init(rootDirectory: URL, screenTimeHandler: @escaping ScreenTimeHandler) {
            self.rootDirectory = rootDirectory
            self.screenTimeHandler = screenTimeHandler
        }

        deinit {
            stop()
        }

        public func start() throws {
            guard source == nil else { return }
            let socketURL = GoalongReadOnlyQueryBroker.socketURL(rootDirectory: rootDirectory)
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Self.removeOwnedStaleSocket(at: socketURL.path)

            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw BrokerFailure.system("socket", errno) }
            GoalongReadOnlyQueryBroker.setNoSigPipe(descriptor)

            do {
                var address = try GoalongReadOnlyQueryBroker.unixAddress(for: socketURL.path)
                let bindResult = withUnsafePointer(to: &address.value) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, address.length)
                    }
                }
                guard bindResult == 0 else { throw BrokerFailure.system("bind", errno) }
                guard Darwin.chmod(socketURL.path, 0o600) == 0 else {
                    throw BrokerFailure.system("chmod", errno)
                }
                guard Darwin.listen(descriptor, 4) == 0 else {
                    throw BrokerFailure.system("listen", errno)
                }
            } catch {
                Darwin.close(descriptor)
                try? Self.removeOwnedStaleSocket(at: socketURL.path)
                throw error
            }

            listeningDescriptor = descriptor
            let readSource = DispatchSource.makeReadSource(
                fileDescriptor: descriptor,
                queue: queue
            )
            readSource.setEventHandler { [weak self] in self?.acceptOneConnection() }
            source = readSource
            readSource.resume()
        }

        public func stop() {
            let socketPath = GoalongReadOnlyQueryBroker.socketURL(
                rootDirectory: rootDirectory
            ).path
            source?.cancel()
            source = nil
            if listeningDescriptor >= 0 {
                Darwin.close(listeningDescriptor)
                listeningDescriptor = -1
            }
            try? Self.removeOwnedStaleSocket(at: socketPath)
        }

        /// Removes only a socket owned by the current user. This lets the app fail closed
        /// when Screen Time consent is off without deleting an unexpected filesystem entry.
        public static func removeOwnedStaleSocket(rootDirectory: URL) throws {
            try removeOwnedStaleSocket(
                at: GoalongReadOnlyQueryBroker.socketURL(rootDirectory: rootDirectory).path
            )
        }

        private func acceptOneConnection() {
            guard listeningDescriptor >= 0 else { return }
            let client = Darwin.accept(listeningDescriptor, nil, nil)
            guard client >= 0 else { return }
            GoalongReadOnlyQueryBroker.setNoSigPipe(client)
            defer { Darwin.close(client) }

            do {
                let requestData = try readRequest(from: client)
                let request = try JSONDecoder().decode(GoalongBrokerRequest.self, from: requestData)
                guard request.schemaVersion == 1, request.command == "screen-time" else {
                    throw BrokerFailure.unsupportedRequest
                }
                let payload = try screenTimeHandler(request.day, request.macOnly)
                try GoalongReadOnlyQueryBroker.writeAll(payload, to: client)
            } catch {
                let payload = (try? JSONEncoder().encode(
                    GoalongBrokerError(brokerError: String(describing: error))
                )) ?? Data("{\"brokerError\":\"query failed\"}".utf8)
                try? GoalongReadOnlyQueryBroker.writeAll(payload, to: client)
            }
        }

        private func readRequest(from descriptor: Int32) throws -> Data {
            var result = Data()
            var byte: UInt8 = 0
            while result.count < GoalongReadOnlyQueryBroker.maximumRequestBytes {
                let count = Darwin.read(descriptor, &byte, 1)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw BrokerFailure.system("read", errno) }
                if count == 0 || byte == 0x0A { return result }
                result.append(byte)
            }
            throw BrokerFailure.requestTooLarge
        }

        private static func removeOwnedStaleSocket(at path: String) throws {
            var status = stat()
            guard Darwin.lstat(path, &status) == 0 else {
                if errno == ENOENT { return }
                throw BrokerFailure.system("lstat", errno)
            }
            let fileType = status.st_mode & S_IFMT
            guard fileType == S_IFSOCK, status.st_uid == Darwin.getuid() else {
                throw BrokerFailure.unsafeExistingSocket
            }
            guard Darwin.unlink(path) == 0 else {
                throw BrokerFailure.system("unlink", errno)
            }
        }
    }

    private enum BrokerFailure: Error, CustomStringConvertible {
        case emptyResponse
        case remote(String)
        case requestTooLarge
        case responseTooLarge
        case socketPathTooLong
        case system(String, Int32)
        case unsafeExistingSocket
        case unsupportedRequest

        var description: String {
            switch self {
            case .emptyResponse: return "The Goalong query broker returned no data."
            case .remote(let message): return message
            case .requestTooLarge: return "The Goalong query broker request exceeded its limit."
            case .responseTooLarge: return "The Goalong query broker response exceeded its limit."
            case .socketPathTooLong: return "The Goalong query broker socket path is too long."
            case .system(let operation, let code):
                return "Goalong query broker \(operation) failed with errno \(code)."
            case .unsafeExistingSocket:
                return "The Goalong query broker refused an unexpected existing socket path."
            case .unsupportedRequest: return "The Goalong query broker request is unsupported."
            }
        }
    }
#endif
